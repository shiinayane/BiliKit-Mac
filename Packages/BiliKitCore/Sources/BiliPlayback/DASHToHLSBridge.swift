import BiliModels
import BiliNetworking
import Foundation

public enum DASHToHLSBridgeError: Error, Sendable, Equatable {
    case invalidMediaKind(expected: MediaKind, actual: MediaKind)
    case missingCompleteMediaLength(representationID: Int)
}

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

public struct DASHToHLSBridge: Sendable {
    private let rangeClient: HTTPRangeClient
    private let indexLoader: RepresentationIndexLoader
    private let mediaPlaylistBuilder: HLSMediaPlaylistBuilder
    private let masterPlaylistBuilder: HLSMasterPlaylistBuilder

    public init(rangeClient: HTTPRangeClient = HTTPRangeClient()) {
        self.rangeClient = rangeClient
        indexLoader = RepresentationIndexLoader(rangeClient: rangeClient)
        mediaPlaylistBuilder = HLSMediaPlaylistBuilder()
        masterPlaylistBuilder = HLSMasterPlaylistBuilder()
    }

    public func prepare(
        video: MediaRepresentation,
        audio: MediaRepresentation,
        headers: [String: String] = [:]
    ) async throws -> PreparedPlaybackAsset {
        guard video.kind == .video else {
            throw DASHToHLSBridgeError.invalidMediaKind(
                expected: .video,
                actual: video.kind
            )
        }
        guard audio.kind == .audio else {
            throw DASHToHLSBridgeError.invalidMediaKind(
                expected: .audio,
                actual: audio.kind
            )
        }

        async let loadedVideo = indexLoader.load(
            for: video,
            headers: headers
        )
        async let loadedAudio = indexLoader.load(
            for: audio,
            headers: headers
        )
        let (videoIndex, audioIndex) = try await (loadedVideo, loadedAudio)

        guard let videoLength = videoIndex.completeMediaLength else {
            throw DASHToHLSBridgeError.missingCompleteMediaLength(
                representationID: video.id
            )
        }
        guard let audioLength = audioIndex.completeMediaLength else {
            throw DASHToHLSBridgeError.missingCompleteMediaLength(
                representationID: audio.id
            )
        }

        let server = LoopbackPlaybackServer(rangeClient: rangeClient)
        do {
            try await server.start()
            let masterURL = try server.url(for: "master.m3u8")
            let videoPlaylistURL = try server.url(for: "video/\(video.id).m3u8")
            let audioPlaylistURL = try server.url(for: "audio/\(audio.id).m3u8")
            let videoMediaURL = try server.register(
                .remote(
                    try LoopbackRemoteResource(
                        candidateURLs: preferredCandidates(
                            selected: videoIndex.sourceURL,
                            all: video.urlCandidates
                        ),
                        contentLength: videoLength,
                        contentType: video.mimeType,
                        headers: headers
                    )
                ),
                at: "media/video/\(video.id).mp4"
            )
            let audioMediaURL = try server.register(
                .remote(
                    try LoopbackRemoteResource(
                        candidateURLs: preferredCandidates(
                            selected: audioIndex.sourceURL,
                            all: audio.urlCandidates
                        ),
                        contentLength: audioLength,
                        contentType: audio.mimeType,
                        headers: headers
                    )
                ),
                at: "media/audio/\(audio.id).mp4"
            )

            let videoPlaylist = try mediaPlaylistBuilder.build(
                representation: video,
                index: videoIndex.index,
                mediaURI: videoMediaURL
            )
            let audioPlaylist = try mediaPlaylistBuilder.build(
                representation: audio,
                index: audioIndex.index,
                mediaURI: audioMediaURL
            )
            let masterPlaylist = try masterPlaylistBuilder.build(
                video: video,
                videoPlaylistURI: videoPlaylistURL,
                audio: audio,
                audioPlaylistURI: audioPlaylistURL
            )

            _ = try server.register(
                playlistResource(videoPlaylist),
                at: "video/\(video.id).m3u8"
            )
            _ = try server.register(
                playlistResource(audioPlaylist),
                at: "audio/\(audio.id).m3u8"
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

    private func preferredCandidates(
        selected: URL,
        all candidates: [URL]
    ) -> [URL] {
        [selected] + candidates.filter { $0 != selected }
    }

    private func playlistResource(_ playlist: String) -> LoopbackPlaybackResource {
        .inMemory(
            data: Data(playlist.utf8),
            contentType: "application/vnd.apple.mpegurl"
        )
    }
}
