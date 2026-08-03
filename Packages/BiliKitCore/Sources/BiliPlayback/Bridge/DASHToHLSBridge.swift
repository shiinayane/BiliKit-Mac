import BiliModels
import BiliNetworking
import Foundation

public enum DASHToHLSBridgeError: Error, Sendable, Equatable {
    case missingVideoRepresentation
    case invalidMediaKind(expected: MediaKind, actual: MediaKind)
    case duplicateVideoRepresentationID(Int)
    case missingCompleteMediaLength(representationID: Int)
}

/// 一次已启动的 loopback HLS 会话；其生命周期就是底层 server 的生命周期。
///
/// owner 必须在替换播放项或失败时调用 `stop`；`deinit` 只是最后一道幂等清理保障。
public final class PreparedPlaybackAsset: @unchecked Sendable {
    public let url: URL
    private let server: LoopbackPlaybackServer

    fileprivate init(url: URL, server: LoopbackPlaybackServer) {
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
    private let masterPlaylistBuilder: HLSMasterPlaylistBuilder
    private let serverFactory: @Sendable (HTTPRangeClient) -> LoopbackPlaybackServer

    public init(rangeClient: HTTPRangeClient = HTTPRangeClient()) {
        self.init(
            rangeClient: rangeClient,
            serverFactory: { LoopbackPlaybackServer(rangeClient: $0) }
        )
    }

    init(
        rangeClient: HTTPRangeClient,
        serverFactory: @escaping @Sendable (HTTPRangeClient) -> LoopbackPlaybackServer
    ) {
        self.rangeClient = rangeClient
        indexLoader = RepresentationIndexLoader(rangeClient: rangeClient)
        mediaPlaylistBuilder = HLSMediaPlaylistBuilder()
        masterPlaylistBuilder = HLSMasterPlaylistBuilder()
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
            headers: headers
        )
    }

    /// 并行解析各 representation，注册随机 loopback route，并返回会话 owner。
    public func prepare(
        videos: [MediaRepresentation],
        audio: MediaRepresentation,
        headers: [String: String] = [:]
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

        let server = serverFactory(rangeClient)
        do {
            try await server.start()
            let masterURL = try server.url(for: "master.m3u8")
            let audioPlaylistURL = try server.url(for: "audio/\(audio.id).m3u8")
            let audioMediaURL = try server.register(
                .remote(
                    try LoopbackRemoteResource(
                        sourceURL: audioIndex.sourceURL,
                        contentLength: audioLength,
                        contentType: audio.mimeType,
                        headers: headers
                    )
                ),
                at: "media/audio/\(audio.id).mp4"
            )

            let audioPlaylist = try mediaPlaylistBuilder.build(
                representation: audio,
                index: audioIndex.index,
                mediaURI: audioMediaURL
            )
            _ = try server.register(
                playlistResource(audioPlaylist),
                at: "audio/\(audio.id).m3u8"
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
                let videoMediaURL = try server.register(
                    .remote(
                        try LoopbackRemoteResource(
                            sourceURL: videoIndex.sourceURL,
                            contentLength: videoLength,
                            contentType: video.mimeType,
                            headers: headers
                        )
                    ),
                    at: "media/video/\(video.id).mp4"
                )
                let videoPlaylist = try mediaPlaylistBuilder.build(
                    representation: video,
                    index: videoIndex.index,
                    mediaURI: videoMediaURL
                )
                _ = try server.register(
                    playlistResource(videoPlaylist),
                    at: "video/\(video.id).m3u8"
                )
                variants.append(
                    HLSVideoVariant(
                        representation: video,
                        index: videoIndex.index,
                        playlistURI: videoPlaylistURL
                    )
                )
            }

            let masterPlaylist = try masterPlaylistBuilder.build(
                videoVariants: variants,
                audio: audio,
                audioIndex: audioIndex.index,
                audioPlaylistURI: audioPlaylistURL
            )
            _ = try server.register(
                playlistResource(masterPlaylist),
                at: "master.m3u8"
            )

            return PreparedPlaybackAsset(url: masterURL, server: server)
        } catch {
            server.stop()
            throw error
        }
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
