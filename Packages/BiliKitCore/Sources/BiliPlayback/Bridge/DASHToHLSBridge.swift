import BiliModels
import BiliNetworking
import Foundation

public enum DASHToHLSBridgeError: Error, Sendable, Equatable {
    case missingVideoRepresentation
    case unsupportedAudioTrackCount(Int)
    case unsupportedAudioTrackRole(String)
    case invalidAudioTrackSelection(trackID: String, representationID: Int)
    case invalidMediaKind(expected: MediaKind, actual: MediaKind)
    case duplicateVideoRepresentationID(Int)
    case missingCompleteMediaLength(representationID: Int)
    case subtitleCatalogTimedOut
    case inconsistentSubtitleTimeline
}

/// 一次已启动的 loopback HLS 会话；其生命周期就是底层 server 的生命周期。
///
/// owner 必须在替换播放项或失败时调用 `stop`；`deinit` 只是最后一道幂等清理保障。
public final class PreparedPlaybackAsset: @unchecked Sendable {
    public let url: URL
    private let server: LoopbackPlaybackServer

    fileprivate init(
        url: URL,
        server: LoopbackPlaybackServer
    ) {
        self.url = url
        self.server = server
    }

    deinit {
        server.stop()
    }

    public func stop() {
        server.stop()
    }
}

/// 把 DASH representation 的 SIDX/Range 语义转换为 AVPlayer 可消费的本机 HLS 会话。
///
/// Bridge 只构造内存 playlist 与按需代理，不下载完整媒体；任一步失败都会停止已启动 server。
public struct DASHToHLSBridge: Sendable {
    private let rangeClient: HTTPRangeClient
    private let indexLoader: RepresentationIndexLoader
    private let audioFormatLoader: AudioFormatMetadataLoader
    private let mediaPlaylistBuilder: HLSMediaPlaylistBuilder
    private let iFramePlaylistBuilder: HLSIFramePlaylistBuilder
    private let subtitlePlaylistBuilder: HLSSubtitlePlaylistBuilder
    private let masterPlaylistBuilder: HLSMasterPlaylistBuilder
    private let webVTTEncoder: WebVTTEncoder
    private let subtitleCatalogGrace: Duration
    private let serverFactory: @Sendable (HTTPRangeClient) -> LoopbackPlaybackServer

    public init(
        rangeClient: HTTPRangeClient = HTTPRangeClient(),
        subtitleCatalogGrace: Duration = .seconds(2)
    ) {
        self.init(
            rangeClient: rangeClient,
            subtitleCatalogGrace: subtitleCatalogGrace,
            serverFactory: { LoopbackPlaybackServer(rangeClient: $0) }
        )
    }

    init(
        rangeClient: HTTPRangeClient,
        subtitleCatalogGrace: Duration = .seconds(2),
        serverFactory: @escaping @Sendable (HTTPRangeClient) -> LoopbackPlaybackServer
    ) {
        precondition(
            subtitleCatalogGrace > .zero,
            "Subtitle catalog grace must be positive"
        )
        self.rangeClient = rangeClient
        indexLoader = RepresentationIndexLoader(rangeClient: rangeClient)
        audioFormatLoader = AudioFormatMetadataLoader(rangeClient: rangeClient)
        mediaPlaylistBuilder = HLSMediaPlaylistBuilder()
        iFramePlaylistBuilder = HLSIFramePlaylistBuilder()
        subtitlePlaylistBuilder = HLSSubtitlePlaylistBuilder()
        masterPlaylistBuilder = HLSMasterPlaylistBuilder()
        webVTTEncoder = WebVTTEncoder()
        self.subtitleCatalogGrace = subtitleCatalogGrace
        self.serverFactory = serverFactory
    }

    public func prepare(
        video: MediaRepresentation,
        audioTracks: [SelectedPlaybackAudioTrack],
        headers: [String: String] = [:]
    ) async throws -> PreparedPlaybackAsset {
        try await prepare(
            videos: [video],
            audioTracks: audioTracks,
            headers: headers,
            subtitleSource: nil
        )
    }

    /// 并行解析各 representation，注册随机 loopback route，并返回会话 owner。
    public func prepare(
        videos: [MediaRepresentation],
        audioTracks: [SelectedPlaybackAudioTrack],
        headers: [String: String] = [:]
    ) async throws -> PreparedPlaybackAsset {
        try await prepare(
            videos: videos,
            audioTracks: audioTracks,
            headers: headers,
            subtitleSource: nil
        )
    }

    func prepare(
        videos: [MediaRepresentation],
        audioTracks: [SelectedPlaybackAudioTrack],
        headers: [String: String],
        subtitleSource: NativeSubtitleSource?
    ) async throws -> PreparedPlaybackAsset {
        guard !videos.isEmpty else {
            throw DASHToHLSBridgeError.missingVideoRepresentation
        }
        var videoIDs = Set<Int>()
        for video in videos {
            guard video.kind == .video else {
                throw DASHToHLSBridgeError.invalidMediaKind(
                    expected: .video,
                    actual: video.kind
                )
            }
            guard videoIDs.insert(video.id).inserted else {
                throw DASHToHLSBridgeError.duplicateVideoRepresentationID(
                    video.id
                )
            }
        }
        guard !audioTracks.isEmpty else {
            throw DASHToHLSBridgeError.unsupportedAudioTrackCount(
                audioTracks.count
            )
        }
        let defaultAudioTracks = audioTracks.filter(\.track.isDefault)
        guard defaultAudioTracks.count == 1,
            defaultAudioTracks[0].track.role == .original,
            defaultAudioTracks[0].track.isAutoselect
        else {
            throw DASHToHLSBridgeError.unsupportedAudioTrackCount(
                defaultAudioTracks.count
            )
        }
        var audioTrackIDs = Set<String>()
        for selectedAudio in audioTracks {
            guard audioTrackIDs.insert(selectedAudio.track.id).inserted,
                selectedAudio.track.representations.contains(
                    selectedAudio.representation
                )
            else {
                throw DASHToHLSBridgeError.invalidAudioTrackSelection(
                    trackID: selectedAudio.track.id,
                    representationID: selectedAudio.representation.id
                )
            }
            switch selectedAudio.track.role {
            case .original:
                guard selectedAudio.track.isDefault else {
                    throw DASHToHLSBridgeError.unsupportedAudioTrackRole(
                        selectedAudio.track.id
                    )
                }
            case .machineGenerated:
                guard !selectedAudio.track.isDefault,
                    selectedAudio.track.languageTag != nil
                else {
                    throw DASHToHLSBridgeError.unsupportedAudioTrackRole(
                        selectedAudio.track.id
                    )
                }
            }
            guard selectedAudio.representation.kind == .audio else {
                throw DASHToHLSBridgeError.invalidMediaKind(
                    expected: .audio,
                    actual: selectedAudio.representation.kind
                )
            }
        }

        let catalogTask = subtitleSource.map { source in
            Task { try await source.catalog() }
        }
        defer { catalogTask?.cancel() }

        async let loadedAudioRenditions = loadAudioRenditions(
            audioTracks,
            headers: headers
        )
        async let loadedVideoIndices = loadVideoIndices(
            videos,
            headers: headers
        )
        let audioRenditions = try await loadedAudioRenditions
        let videoIndices = try await loadedVideoIndices
        let subtitleCatalog = try await freezeCatalog(catalogTask)

        let server = serverFactory(rangeClient)
        do {
            try await server.start()
            let masterURL = try server.url(for: "master.m3u8")
            let localizedRenditionNamesURL = try server.url(
                for: "metadata/localized-rendition-names.json"
            )
            var registrations: [LoopbackRouteRegistration] = []
            var hlsAudioRenditions: [HLSAudioRendition] = []
            hlsAudioRenditions.reserveCapacity(audioRenditions.count)
            for (offset, loadedAudio) in audioRenditions.enumerated() {
                let audio = loadedAudio.selectedTrack.representation
                guard let audioLength = loadedAudio.index.completeMediaLength else {
                    throw DASHToHLSBridgeError.missingCompleteMediaLength(
                        representationID: audio.id
                    )
                }
                let audioPlaylistPath = "audio/\(offset)/\(audio.id).m3u8"
                let audioPlaylistURL = try server.url(for: audioPlaylistPath)
                let audioMediaPath = "media/audio/\(offset)/\(audio.id).mp4"
                let audioMediaURL = try server.url(for: audioMediaPath)
                registrations.append(
                    LoopbackRouteRegistration(
                        relativePath: audioMediaPath,
                        resource: .remote(
                            try LoopbackRemoteResource(
                                sourceURL: loadedAudio.index.sourceURL,
                                contentLength: audioLength,
                                contentType: audio.mimeType,
                                headers: headers
                            )
                        )
                    )
                )
                let audioPlaylist = try mediaPlaylistBuilder.build(
                    representation: audio,
                    index: loadedAudio.index.index,
                    mediaURI: audioMediaURL
                )
                registrations.append(
                    LoopbackRouteRegistration(
                        relativePath: audioPlaylistPath,
                        resource: playlistResource(audioPlaylist)
                    )
                )
                hlsAudioRenditions.append(
                    HLSAudioRendition(
                        selectedTrack: loadedAudio.selectedTrack,
                        channelCount: loadedAudio.format?.channelCount,
                        bitDepth: loadedAudio.format?.bitDepth,
                        sampleRate: loadedAudio.format?.sampleRate,
                        index: loadedAudio.index.index,
                        playlistURI: audioPlaylistURL
                    )
                )
            }
            registrations.append(
                LoopbackRouteRegistration(
                    relativePath: "metadata/localized-rendition-names.json",
                    resource: try localizedRenditionNamesResource(
                        for: audioTracks.map(\.track)
                    )
                )
            )

            var variants: [HLSVideoVariant] = []
            variants.reserveCapacity(videos.count)
            var iFrameVariants: [HLSIFrameVariant] = []
            iFrameVariants.reserveCapacity(videos.count)
            for (video, videoIndex) in zip(videos, videoIndices) {
                guard let videoLength = videoIndex.completeMediaLength else {
                    throw DASHToHLSBridgeError.missingCompleteMediaLength(
                        representationID: video.id
                    )
                }
                let videoPlaylistURL = try server.url(
                    for: "video/\(video.id).m3u8"
                )
                let videoMediaPath = "media/video/\(video.id).mp4"
                let videoMediaURL = try server.url(for: videoMediaPath)
                registrations.append(
                    LoopbackRouteRegistration(
                        relativePath: videoMediaPath,
                        resource: .remote(
                            try LoopbackRemoteResource(
                                sourceURL: videoIndex.sourceURL,
                                contentLength: videoLength,
                                contentType: video.mimeType,
                                headers: headers
                            )
                        )
                    )
                )
                let videoPlaylist = try mediaPlaylistBuilder.build(
                    representation: video,
                    index: videoIndex.index,
                    mediaURI: videoMediaURL
                )
                registrations.append(
                    LoopbackRouteRegistration(
                        relativePath: "video/\(video.id).m3u8",
                        resource: playlistResource(videoPlaylist)
                    )
                )
                variants.append(
                    HLSVideoVariant(
                        representation: video,
                        index: videoIndex.index,
                        playlistURI: videoPlaylistURL
                    )
                )
                if isEligibleForIFramePlaylist(videoIndex.index) {
                    let iFramePlaylistPath = "video/\(video.id)-iframe.m3u8"
                    let iFramePlaylistURL = try server.url(
                        for: iFramePlaylistPath
                    )
                    let iFramePlaylist = try iFramePlaylistBuilder.build(
                        representation: video,
                        index: videoIndex.index,
                        mediaURI: videoMediaURL
                    )
                    registrations.append(
                        LoopbackRouteRegistration(
                            relativePath: iFramePlaylistPath,
                            resource: playlistResource(iFramePlaylist)
                        )
                    )
                    iFrameVariants.append(
                        HLSIFrameVariant(
                            representation: video,
                            index: videoIndex.index,
                            playlistURI: iFramePlaylistURL
                        )
                    )
                }
            }

            let mediaRegistrationCount = registrations.count
            let masterPlaylist: String
            do {
                let subtitleRenditions = try makeSubtitleRoutes(
                    catalog: subtitleCatalog,
                    source: subtitleSource,
                    videoIndices: videoIndices.map(\.index),
                    registrations: &registrations,
                    server: server
                )
                masterPlaylist = try masterPlaylistBuilder.build(
                    videoVariants: variants,
                    audioRenditions: hlsAudioRenditions,
                    subtitleRenditions: subtitleRenditions,
                    iFrameVariants: iFrameVariants,
                    localizedRenditionNamesURI: localizedRenditionNamesURL
                )
            } catch {
                registrations.removeSubrange(mediaRegistrationCount...)
                masterPlaylist = try masterPlaylistBuilder.build(
                    videoVariants: variants,
                    audioRenditions: hlsAudioRenditions,
                    iFrameVariants: iFrameVariants,
                    localizedRenditionNamesURI: localizedRenditionNamesURL
                )
            }
            registrations.append(
                LoopbackRouteRegistration(
                    relativePath: "master.m3u8",
                    resource: playlistResource(masterPlaylist)
                )
            )
            _ = try server.register(registrations)

            return PreparedPlaybackAsset(
                url: masterURL,
                server: server
            )
        } catch {
            server.stop()
            throw error
        }
    }

    private func optionalAudioFormat(
        for audio: MediaRepresentation,
        sourceURL: URL,
        headers: [String: String]
    ) async throws -> AudioFormatMetadata? {
        do {
            return try await audioFormatLoader.load(
                for: audio,
                sourceURL: sourceURL,
                headers: headers
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func isEligibleForIFramePlaylist(_ index: SegmentIndex) -> Bool {
        !index.references.isEmpty
            && index.references.allSatisfy { reference in
                reference.startsWithSAP
                    && reference.sapType == 1
                    && reference.sapDeltaTime == 0
            }
    }

    private func loadAudioRenditions(
        _ audioTracks: [SelectedPlaybackAudioTrack],
        headers: [String: String]
    ) async throws -> [LoadedAudioRendition] {
        try await withThrowingTaskGroup(
            of: (Int, LoadedAudioRendition?).self
        ) { group in
            for (offset, selectedTrack) in audioTracks.enumerated() {
                group.addTask {
                    do {
                        let audio = selectedTrack.representation
                        let index = try await indexLoader.load(
                            for: audio,
                            headers: headers
                        )
                        guard index.completeMediaLength != nil else {
                            if selectedTrack.track.role == .machineGenerated {
                                return (offset, nil)
                            }
                            throw
                                DASHToHLSBridgeError
                                .missingCompleteMediaLength(
                                    representationID: audio.id
                                )
                        }
                        let format = try await optionalAudioFormat(
                            for: audio,
                            sourceURL: index.sourceURL,
                            headers: headers
                        )
                        return (
                            offset,
                            LoadedAudioRendition(
                                selectedTrack: selectedTrack,
                                index: index,
                                format: format
                            )
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch  where selectedTrack.track.role == .machineGenerated {
                        return (offset, nil)
                    } catch {
                        throw error
                    }
                }
            }
            var loaded: [(Int, LoadedAudioRendition?)] = []
            loaded.reserveCapacity(audioTracks.count)
            for try await result in group {
                loaded.append(result)
            }
            return loaded.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
    }

    private func localizedRenditionNamesResource(
        for tracks: [PlaybackAudioTrack]
    ) throws -> LoopbackPlaybackResource {
        var localizedNames: [String: [String: String]] = [:]
        for track in tracks {
            let translations: [String: String]
            switch track.role {
            case .original:
                translations = [
                    "en": "Original",
                    "ja": "オリジナル",
                    "zh": "原声",
                ]
            case .machineGenerated:
                continue
            }
            localizedNames[track.displayName] = translations
        }
        let body = try JSONSerialization.data(
            withJSONObject: localizedNames,
            options: [.sortedKeys]
        )
        return .inMemory(
            data: body,
            contentType: "application/json; charset=utf-8"
        )
    }

    private func freezeCatalog(
        _ catalogTask: Task<[NativeSubtitleCatalogEntry], any Error>?
    ) async throws -> [NativeSubtitleCatalogEntry] {
        guard let catalogTask else { return [] }
        let relay = CatalogResultRelay<[NativeSubtitleCatalogEntry]>()
        let observer = Task {
            do {
                relay.resolve(.success(try await catalogTask.value))
            } catch {
                relay.resolve(.failure(error))
            }
        }
        let timeout = Task {
            do {
                try await Task.sleep(for: subtitleCatalogGrace)
                catalogTask.cancel()
                relay.resolve(
                    .failure(DASHToHLSBridgeError.subtitleCatalogTimedOut)
                )
            } catch is CancellationError {
                return
            } catch {
                relay.resolve(.failure(error))
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await relay.value()
            } onCancel: {
                catalogTask.cancel()
                relay.resolve(.failure(CancellationError()))
            }
            timeout.cancel()
            observer.cancel()
            return result
        } catch is CancellationError where Task.isCancelled {
            timeout.cancel()
            observer.cancel()
            catalogTask.cancel()
            throw CancellationError()
        } catch {
            timeout.cancel()
            observer.cancel()
            catalogTask.cancel()
            return []
        }
    }

    private func makeSubtitleRoutes(
        catalog: [NativeSubtitleCatalogEntry],
        source: NativeSubtitleSource?,
        videoIndices: [SegmentIndex],
        registrations: inout [LoopbackRouteRegistration],
        server: LoopbackPlaybackServer
    ) throws -> [HLSSubtitleRendition] {
        guard let source, !catalog.isEmpty else { return [] }
        guard let videoIndex = videoIndices.first,
            videoIndices.dropFirst().allSatisfy({
                hasMatchingSubtitleTimeline($0, canonical: videoIndex)
            })
        else {
            throw DASHToHLSBridgeError.inconsistentSubtitleTimeline
        }
        let duration =
            videoIndices.map { index in
                index.references.reduce(0.0) {
                    $0 + Double($1.duration) / Double(index.timescale)
                }
            }.max() ?? 0

        return try catalog.enumerated().map { offset, entry in
            let playlistPath = "subtitle/\(offset).m3u8"
            let bodyPath = "subtitle/generated/\(offset).vtt"
            let playlistURL = try server.url(for: playlistPath)
            let bodyURL = try server.url(for: bodyPath)
            let generated = try LoopbackGeneratedResource(
                contentType: "text/vtt; charset=utf-8",
                maximumContentLength: 2 * 1_024 * 1_024
            ) {
                let cues = try await source.cues(for: entry.trackID)
                return try webVTTEncoder.encode(
                    cues: cues,
                    earliestPresentationTime: videoIndex.earliestPresentationTime,
                    timescale: videoIndex.timescale
                )
            }
            let playlist = try subtitlePlaylistBuilder.build(
                segmentURI: bodyURL,
                duration: duration
            )
            registrations.append(
                LoopbackRouteRegistration(
                    relativePath: playlistPath,
                    resource: playlistResource(playlist)
                )
            )
            registrations.append(
                LoopbackRouteRegistration(
                    relativePath: bodyPath,
                    resource: .generated(generated)
                )
            )
            return HLSSubtitleRendition(
                name: entry.label,
                languageTag: entry.languageTag,
                characteristics: entry.characteristics,
                playlistURI: playlistURL
            )
        }
    }

    func hasMatchingSubtitleTimeline(
        _ candidate: SegmentIndex,
        canonical: SegmentIndex
    ) -> Bool {
        guard candidate.timescale > 0, canonical.timescale > 0 else {
            return false
        }
        let canonicalStart =
            Double(canonical.earliestPresentationTime)
            / Double(canonical.timescale)
        let candidateStart =
            Double(candidate.earliestPresentationTime)
            / Double(candidate.timescale)
        return abs(candidateStart - canonicalStart) <= 1.0 / 90_000.0
    }

    private func loadVideoIndices(
        _ videos: [MediaRepresentation],
        headers: [String: String]
    ) async throws -> [LoadedSegmentIndex] {
        try await withThrowingTaskGroup(
            of: (Int, LoadedSegmentIndex).self
        ) { group in
            for (offset, video) in videos.enumerated() {
                group.addTask {
                    (
                        offset,
                        try await indexLoader.load(
                            for: video,
                            headers: headers
                        )
                    )
                }
            }

            var ordered = [LoadedSegmentIndex?](
                repeating: nil,
                count: videos.count
            )
            for try await (offset, index) in group {
                ordered[offset] = index
            }
            return ordered.compactMap { $0 }
        }
    }

    private func playlistResource(_ playlist: String) -> LoopbackPlaybackResource {
        .inMemory(
            data: Data(playlist.utf8),
            contentType: "application/vnd.apple.mpegurl"
        )
    }
}

private struct LoadedAudioRendition: Sendable {
    let selectedTrack: SelectedPlaybackAudioTrack
    let index: LoadedSegmentIndex
    let format: AudioFormatMetadata?
}

private final class CatalogResultRelay<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Value, any Error>, Never>?
    private var result: Result<Value, any Error>?

    func value() async throws -> Value {
        let result: Result<Value, any Error> = await withCheckedContinuation {
            continuation in
            let pending = lock.withLock { () -> Result<Value, any Error>? in
                if let storedResult = self.result { return storedResult }
                self.continuation = continuation
                return nil
            }
            if let pending {
                continuation.resume(returning: pending)
            }
        }
        return try result.get()
    }

    func resolve(_ result: Result<Value, any Error>) {
        let continuation = lock.withLock {
            () -> CheckedContinuation<Result<Value, any Error>, Never>? in
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}
