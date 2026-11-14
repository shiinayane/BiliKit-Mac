import BiliModels
import BiliNetworking
import Foundation

/// bridge 准备播放会话的失败：媒体表示缺失或不一致、来源不合规、缺少完整长度与字幕目录问题。
public enum DASHToHLSBridgeError: Error, Sendable, Equatable {
    case missingVideoRepresentation
    case unsupportedAudioTrackCount(Int)
    case unsupportedAudioTrackRole(String)
    case invalidAudioTrackSelection(trackID: String, representationID: Int)
    case invalidMediaKind(expected: MediaKind, actual: MediaKind)
    case duplicateVideoRepresentationID(Int)
    case missingCompleteMediaLength(representationID: Int)
    case disallowedMediaSource(representationID: Int)
    case subtitleCatalogTimedOut
    case inconsistentSubtitleTimeline
}

/// 一次已启动的 loopback 播放会话；其生命周期就是底层 server 的生命周期。
///
/// owner 必须在替换播放项或失败时调用 `stop`；`deinit` 只是最后一道幂等清理保障。
public final class PreparedPlaybackAsset: Sendable {
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

/// 把 DASH 或单文件 progressive Range 语义转换为 AVPlayer 可消费的本机播放会话。
///
/// Bridge 只构造内存 playlist 与按需代理，不下载完整媒体；任一步失败都会停止已启动 server。
public struct DASHToHLSBridge: Sendable {
    let indexLoader: RepresentationIndexLoader
    let initializationLoader: InitializationSegmentLoader
    private let mediaPlaylistBuilder: HLSMediaPlaylistBuilder
    private let iFramePlaylistBuilder: HLSIFramePlaylistBuilder
    let subtitlePlaylistBuilder: HLSSubtitlePlaylistBuilder
    private let masterPlaylistBuilder: HLSMasterPlaylistBuilder
    let webVTTEncoder: WebVTTEncoder
    private let serverFactory: @Sendable () -> LoopbackPlaybackServer

    public init() {
        // 同一 bridge 的 SIDX／init 读取与所有播放会话的分段转发共用一个媒体 Range 会话，起播与
        // 切换清晰度时复用 CDN 连接；server 停止只取消自己的在途请求。
        let rangeStreamer = HTTPRangeStreamingClient()
        self.init(
            rangeClient: HTTPRangeClient(streamer: rangeStreamer),
            serverFactory: { LoopbackPlaybackServer(rangeStreamer: rangeStreamer) }
        )
    }

    /// 媒体索引就绪后最多再等字幕目录这么久，超时按无字幕起播：加长会推迟首帧，缩短会在慢网下
    /// 丢掉本可显示的字幕。
    static let subtitleCatalogGrace: Duration = .seconds(2)

    /// `rangeClient` 负责 SIDX／init 读取，`serverFactory` 为每次 prepare 建一个 loopback server，
    /// 二者应共用同一媒体 Range 会话（见 `init()`）。
    init(
        rangeClient: HTTPRangeClient,
        serverFactory: @escaping @Sendable () -> LoopbackPlaybackServer
    ) {
        indexLoader = RepresentationIndexLoader(rangeClient: rangeClient)
        initializationLoader = InitializationSegmentLoader(rangeClient: rangeClient)
        mediaPlaylistBuilder = HLSMediaPlaylistBuilder()
        iFramePlaylistBuilder = HLSIFramePlaylistBuilder()
        subtitlePlaylistBuilder = HLSSubtitlePlaylistBuilder()
        masterPlaylistBuilder = HLSMasterPlaylistBuilder()
        webVTTEncoder = WebVTTEncoder()
        self.serverFactory = serverFactory
    }

    /// 在同一个 loopback owner 中登记 progressive MP4；正文由 server 按 AVPlayer 的单 Range
    /// 逐块转发，不在 bridge 或 server 中缓存完整媒体。
    public func prepare(
        progressive source: ProgressivePlaybackSource,
        headers: [String: String] = [:]
    ) async throws -> PreparedPlaybackAsset {
        let server = serverFactory()
        do {
            try await server.start()
            let resource = try LoopbackProgressiveResource(
                candidateURLs: source.urlCandidates,
                contentLength: source.contentLength,
                contentType: source.contentType,
                // 源声明为 MP4 容器且全部候选 URL 的扩展名都是 `.mp4`，才算有容器证据。
                allowsOctetStreamWithContainerEvidence:
                    source.container == .mp4
                    && source.urlCandidates.allSatisfy {
                        $0.pathExtension.lowercased() == "mp4"
                    },
                headers: headers
            )
            let localURL = try server.register(
                .progressive(resource),
                at: "progressive/media.mp4"
            )
            return PreparedPlaybackAsset(url: localURL, server: server)
        } catch {
            server.stop()
            throw error
        }
    }

    /// 并行解析各 representation，注册随机 loopback route，并返回会话 owner。
    ///
    /// `hdrVideos` 是调用方已按设置与环境决定允许加入的 HDR 候选档（杜比视界在前），至多加入其中一档；
    /// 为空时 master 与以前一样只有 SDR 档、不写 `VIDEO-RANGE`。
    func prepare(
        videos: [MediaRepresentation],
        hdrVideos: [MediaRepresentation] = [],
        audioTracks: [SelectedPlaybackAudioTrack],
        headers: [String: String],
        subtitleSource: NativeSubtitleSource?,
        startPositionSeconds: Double? = nil
    ) async throws -> PreparedPlaybackAsset {
        guard !videos.isEmpty else {
            throw DASHToHLSBridgeError.missingVideoRepresentation
        }
        var videoIDs = Set<Int>()
        for video in videos + hdrVideos {
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
        // ID 唯一、有音轨时恰好一条默认轨与音频 representation 由 AVPlayerEngine 在释放旧 item 前验证；
        // 这里只守住 bridge 自己的 HLS 角色约束。没有音轨（稿件没有声音）时 master 只有视频。
        for selectedAudio in audioTracks {
            guard
                selectedAudio.track.representations.contains(
                    selectedAudio.representation
                )
            else {
                throw DASHToHLSBridgeError.invalidAudioTrackSelection(
                    trackID: selectedAudio.track.id,
                    representationID: selectedAudio.representation.id
                )
            }
            // 附加版本只属于原声，每个都必须是这条音轨提供的版本，且 ID 互不相同（route 以 ID 命名）。
            var versionIDs: Set<Int> = [selectedAudio.representation.id]
            for version in selectedAudio.additionalRepresentations {
                guard selectedAudio.track.role == .original,
                    selectedAudio.track.offers(version),
                    versionIDs.insert(version.id).inserted
                else {
                    throw DASHToHLSBridgeError.invalidAudioTrackSelection(
                        trackID: selectedAudio.track.id,
                        representationID: version.id
                    )
                }
            }
            switch selectedAudio.track.role {
            case .original:
                guard selectedAudio.track.isDefault,
                    selectedAudio.track.isAutoselect
                else {
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
        }

        // SIDX 读取就是首个上游连接；此前复核每个候选来源，失败关闭，见 SECURITY-MODEL §4。
        let mediaURLPolicy = BiliMediaCDNURLPolicy()
        let audioRepresentations = audioTracks.flatMap {
            [$0.representation] + $0.additionalRepresentations
        }
        for representation in videos + hdrVideos + audioRepresentations
        where !representation.urlCandidates.allSatisfy(mediaURLPolicy.allows) {
            throw DASHToHLSBridgeError.disallowedMediaSource(
                representationID: representation.id
            )
        }

        let catalogTask = subtitleSource.map { source in
            Task { try await source.catalog() }
        }
        defer { catalogTask?.cancel() }

        async let audioRenditionsTask = loadAudioRenditions(
            audioTracks,
            headers: headers
        )
        async let loadedVideoVariants = loadVideoVariants(
            videos,
            headers: headers
        )
        async let loadedHDRVariant = loadHDRVariant(hdrVideos, headers: headers)
        let loadedAudioRenditions = try await audioRenditionsTask
        let videoVariants = try await loadedVideoVariants
        // HDR 档与 SDR 档在 AVPlayer 换档时按同一条时间线衔接，以排在最前的 SDR 档为准；起点不一致只丢
        // HDR 档。丢档在生成字幕 route 之前完成，字幕不受影响。
        var hdrVariant = try await loadedHDRVariant
        if let hdr = hdrVariant,
            !(videoVariants.first.map {
                hasMatchingTimelineOrigin(hdr.video.index.index, canonical: $0.index.index)
            } ?? false)
        {
            hdrVariant = nil
        }
        let subtitleCatalog = try await freezeCatalog(catalogTask)
        let canonicalAudio = loadedAudioRenditions.first(where: {
            $0.selectedTrack.track.isDefault
        })
        guard canonicalAudio != nil || audioTracks.isEmpty else {
            throw DASHToHLSBridgeError.unsupportedAudioTrackCount(0)
        }
        // 同一 AUDIO group 的音轨按同一条时间线互相切换，AI 配音以原声码率最高的 AAC 的 SIDX 起点为准。
        // 原声附加版本（另一组）的起点等于视频或这条 AAC 之一即可：较早稿件的 AAC 各档都比视频晚约 83 ms
        // 起播，杜比却与视频同从 0 开始（实测），只认 AAC 会丢掉杜比组，只认视频又会丢掉其余 AAC 组。
        // 两者都不等的才在生成 master 前丢弃，只少一条配音或一个音频组，不让播放失败。
        let audioRenditions = loadedAudioRenditions.filter { rendition in
            guard let canonicalAudio else { return false }
            return rendition.selectedTrack.track.isDefault
                || hasMatchingAudioTimeline(
                    rendition.index.index,
                    canonical: canonicalAudio.index.index
                )
        }
        let timelineOrigins =
            (canonicalAudio.map { [$0.index.index] } ?? [])
            + (videoVariants.first.map { [$0.index.index] } ?? [])
        let additionalAudioVersions =
            canonicalAudio?.additionalVersions.filter { version in
                timelineOrigins.contains {
                    hasMatchingAudioTimeline(version.index.index, canonical: $0)
                }
            } ?? []

        let server = serverFactory()
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
                hlsAudioRenditions.append(
                    try registerAudioRoute(
                        track: loadedAudio.selectedTrack.track,
                        representation: audio,
                        index: loadedAudio.index,
                        completeMediaLength: audioLength,
                        format: loadedAudio.format,
                        jointObjectCodedInitialization: nil,
                        directory: "\(offset)",
                        headers: headers,
                        server: server,
                        registrations: &registrations
                    )
                )
            }
            // 默认组之后每个原声附加版本一组：成员与默认组相同，只把原声换成这个版本；配音引用同一个 route。
            var audioGroups =
                hlsAudioRenditions.isEmpty ? [] : [HLSAudioGroup(renditions: hlsAudioRenditions)]
            if let canonicalAudio {
                for version in additionalAudioVersions {
                    let original = try registerAudioRoute(
                        track: canonicalAudio.selectedTrack.track,
                        representation: version.representation,
                        index: version.index,
                        completeMediaLength: version.completeMediaLength,
                        format: version.format,
                        jointObjectCodedInitialization: version.jointObjectCodedInitialization,
                        directory: "original",
                        headers: headers,
                        server: server,
                        registrations: &registrations
                    )
                    audioGroups.append(
                        HLSAudioGroup(
                            renditions: hlsAudioRenditions.map {
                                $0.track.isDefault ? original : $0
                            }
                        )
                    )
                }
            }
            var variants: [HLSVideoVariant] = []
            variants.reserveCapacity(videoVariants.count + 1)
            var iFrameVariants: [HLSIFrameVariant] = []
            iFrameVariants.reserveCapacity(videoVariants.count + 1)
            // 有 HDR 档时每个视频档与 I-frame 行都写 `VIDEO-RANGE`，SDR 档写 `SDR`；没有时都不写。
            let videoEntries: [(LoadedVideoVariant, VideoDynamicRangeMetadata?)] =
                videoVariants.map { ($0, nil) }
                + (hdrVariant.map { [($0.video, $0.metadata)] } ?? [])
            for (loadedVideo, dynamicRange) in videoEntries {
                let videoRange =
                    hdrVariant == nil ? nil : (dynamicRange?.range ?? .sdr)
                let video = loadedVideo.representation
                let videoIndex = loadedVideo.index
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
                                contentLength: loadedVideo.completeMediaLength,
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
                        playlistURI: videoPlaylistURL,
                        videoRange: videoRange,
                        supplementalCodecs: dynamicRange?.supplementalCodecs
                    )
                )
                // 不独立的分段只是不提供快进预览，不让播放失败。
                if videoIndex.index.hasIndependentSegments {
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
                            playlistURI: iFramePlaylistURL,
                            videoRange: videoRange
                        )
                    )
                }
            }

            let mediaRegistrationCount = registrations.count
            let masterPlaylist: String
            let localizedSubtitleCatalog: [NativeSubtitleCatalogEntry]
            do {
                let subtitleRenditions = try makeSubtitleRoutes(
                    catalog: subtitleCatalog,
                    source: subtitleSource,
                    videoIndices: videoVariants.map(\.index.index),
                    registrations: &registrations,
                    server: server
                )
                masterPlaylist = try masterPlaylistBuilder.build(
                    videoVariants: variants,
                    audioGroups: audioGroups,
                    subtitleRenditions: subtitleRenditions,
                    iFrameVariants: iFrameVariants,
                    localizedRenditionNamesURI: localizedRenditionNamesURL,
                    startOffsetSeconds: startPositionSeconds
                )
                localizedSubtitleCatalog = subtitleCatalog
            } catch {
                // 字幕 route 或带字幕的 master 生成失败只放弃字幕，按无字幕重新生成 master；
                // 这次再失败才让播放失败。
                registrations.removeSubrange(mediaRegistrationCount...)
                masterPlaylist = try masterPlaylistBuilder.build(
                    videoVariants: variants,
                    audioGroups: audioGroups,
                    iFrameVariants: iFrameVariants,
                    localizedRenditionNamesURI: localizedRenditionNamesURL,
                    startOffsetSeconds: startPositionSeconds
                )
                localizedSubtitleCatalog = []
            }
            // 两条 master 路径都引用这份显示名；原声音轨不写 LANGUAGE，菜单里的“原声”只来自这里。
            registrations.append(
                LoopbackRouteRegistration(
                    relativePath: "metadata/localized-rendition-names.json",
                    resource: try localizedRenditionNamesResource(
                        audioTracks: audioRenditions.map(\.selectedTrack.track),
                        subtitleCatalog: localizedSubtitleCatalog
                    )
                )
            )
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

    /// 为一条音频 rendition 登记媒体与 media playlist 两个 route（`audio/<directory>/<id>.m3u8`），返回它在
    /// master 里的描述。
    ///
    /// `directory` 区分音轨（音轨序号）与原声附加版本（`original`），同一目录内以
    /// representation ID 区分。给了 `jointObjectCodedInitialization` 时另登记一个内存 init route，
    /// `EXT-X-MAP` 指向它，master 同时写 `CHANNELS="<复杂度>/JOC"`：两者只由这一份 init 决定，不会一个
    /// 声明全景声、另一个仍是没有标记的 init。
    private func registerAudioRoute(
        track: PlaybackAudioTrack,
        representation: MediaRepresentation,
        index: LoadedSegmentIndex,
        completeMediaLength: Int64,
        format: AudioFormatMetadata?,
        jointObjectCodedInitialization: Data?,
        directory: String,
        headers: [String: String],
        server: LoopbackPlaybackServer,
        registrations: inout [LoopbackRouteRegistration]
    ) throws -> HLSAudioRendition {
        let playlistPath = "audio/\(directory)/\(representation.id).m3u8"
        let mediaPath = "media/audio/\(directory)/\(representation.id).mp4"
        let mediaURL = try server.url(for: mediaPath)
        registrations.append(
            LoopbackRouteRegistration(
                relativePath: mediaPath,
                resource: .remote(
                    try LoopbackRemoteResource(
                        sourceURL: index.sourceURL,
                        contentLength: completeMediaLength,
                        contentType: representation.mimeType,
                        headers: headers
                    )
                )
            )
        )
        var initializationURL: URL?
        if let jointObjectCodedInitialization {
            let initializationPath = "media/audio/\(directory)/\(representation.id)-init.mp4"
            registrations.append(
                LoopbackRouteRegistration(
                    relativePath: initializationPath,
                    resource: .inMemory(
                        data: jointObjectCodedInitialization,
                        contentType: representation.mimeType
                    )
                )
            )
            initializationURL = try server.url(for: initializationPath)
        }
        let playlist = try mediaPlaylistBuilder.build(
            representation: representation,
            index: index.index,
            mediaURI: mediaURL,
            initializationURI: initializationURL
        )
        registrations.append(
            LoopbackRouteRegistration(
                relativePath: playlistPath,
                resource: playlistResource(playlist)
            )
        )
        return HLSAudioRendition(
            track: track,
            representation: representation,
            channelCount: jointObjectCodedInitialization == nil
                ? format?.channelCount : Int(EAC3JointObjectCodingMarker.complexityIndex),
            isJointObjectCoded: jointObjectCodedInitialization != nil,
            bitDepth: format?.bitDepth,
            sampleRate: format?.sampleRate,
            index: index.index,
            playlistURI: try server.url(for: playlistPath)
        )
    }

    func hasMatchingSubtitleTimeline(
        _ candidate: SegmentIndex,
        canonical: SegmentIndex
    ) -> Bool {
        hasMatchingTimelineOrigin(candidate, canonical: canonical)
    }

    func hasMatchingAudioTimeline(
        _ candidate: SegmentIndex,
        canonical: SegmentIndex
    ) -> Bool {
        hasMatchingTimelineOrigin(candidate, canonical: canonical)
    }

    /// 两份 SIDX 的起始呈现时间换算成秒后相差不超过 1/90000 秒（HLS 90 kHz 时钟的一个 tick）
    /// 即视为同一起点。
    private func hasMatchingTimelineOrigin(
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

    func playlistResource(_ playlist: String) -> LoopbackPlaybackResource {
        .inMemory(
            data: Data(playlist.utf8),
            contentType: "application/vnd.apple.mpegurl"
        )
    }
}
