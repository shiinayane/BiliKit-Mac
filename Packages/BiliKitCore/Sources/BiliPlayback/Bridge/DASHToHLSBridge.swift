import BiliModels
import BiliNetworking
import Foundation

public enum DASHToHLSBridgeError: Error, Sendable, Equatable {
    case missingVideoRepresentation
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
    private let mediaPlaylistBuilder: HLSMediaPlaylistBuilder
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
        mediaPlaylistBuilder = HLSMediaPlaylistBuilder()
        subtitlePlaylistBuilder = HLSSubtitlePlaylistBuilder()
        masterPlaylistBuilder = HLSMasterPlaylistBuilder()
        webVTTEncoder = WebVTTEncoder()
        self.subtitleCatalogGrace = subtitleCatalogGrace
        self.serverFactory = serverFactory
    }

    public func prepare(
        video: MediaRepresentation,
        audio: MediaRepresentation,
        headers: [String: String] = [:]
    ) async throws -> PreparedPlaybackAsset {
        try await prepare(
            videos: [video],
            audio: audio,
            headers: headers,
            subtitleSource: nil
        )
    }

    /// 并行解析各 representation，注册随机 loopback route，并返回会话 owner。
    public func prepare(
        videos: [MediaRepresentation],
        audio: MediaRepresentation,
        headers: [String: String] = [:]
    ) async throws -> PreparedPlaybackAsset {
        try await prepare(
            videos: videos,
            audio: audio,
            headers: headers,
            subtitleSource: nil
        )
    }

    func prepare(
        videos: [MediaRepresentation],
        audio: MediaRepresentation,
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
        guard audio.kind == .audio else {
            throw DASHToHLSBridgeError.invalidMediaKind(
                expected: .audio,
                actual: audio.kind
            )
        }

        let catalogTask = subtitleSource.map { source in
            Task { try await source.catalog() }
        }
        defer { catalogTask?.cancel() }

        async let loadedAudio = indexLoader.load(
            for: audio,
            headers: headers
        )
        let videoIndices = try await loadVideoIndices(
            videos,
            headers: headers
        )
        let audioIndex = try await loadedAudio
        guard let audioLength = audioIndex.completeMediaLength else {
            throw DASHToHLSBridgeError.missingCompleteMediaLength(
                representationID: audio.id
            )
        }
        let subtitleCatalog = try await freezeCatalog(catalogTask)

        let server = serverFactory(rangeClient)
        do {
            try await server.start()
            let masterURL = try server.url(for: "master.m3u8")
            let audioPlaylistURL = try server.url(for: "audio/\(audio.id).m3u8")
            let audioMediaPath = "media/audio/\(audio.id).mp4"
            let audioMediaURL = try server.url(for: audioMediaPath)
            var registrations = [
                LoopbackRouteRegistration(
                    relativePath: audioMediaPath,
                    resource: .remote(
                        try LoopbackRemoteResource(
                            sourceURL: audioIndex.sourceURL,
                            contentLength: audioLength,
                            contentType: audio.mimeType,
                            headers: headers
                        )
                    )
                )
            ]

            let audioPlaylist = try mediaPlaylistBuilder.build(
                representation: audio,
                index: audioIndex.index,
                mediaURI: audioMediaURL
            )
            registrations.append(
                LoopbackRouteRegistration(
                    relativePath: "audio/\(audio.id).m3u8",
                    resource: playlistResource(audioPlaylist)
                )
            )

            var variants: [HLSVideoVariant] = []
            variants.reserveCapacity(videos.count)
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
                    audio: audio,
                    audioIndex: audioIndex.index,
                    audioPlaylistURI: audioPlaylistURL,
                    subtitleRenditions: subtitleRenditions
                )
            } catch {
                registrations.removeSubrange(mediaRegistrationCount...)
                masterPlaylist = try masterPlaylistBuilder.build(
                    videoVariants: variants,
                    audio: audio,
                    audioIndex: audioIndex.index,
                    audioPlaylistURI: audioPlaylistURL
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
