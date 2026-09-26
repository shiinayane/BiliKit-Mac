@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliPlayback

@Suite(.serialized, .timeLimit(.minutes(1)))
struct LoopbackProgressiveStreamingTests {
    @Test
    func progressiveRangePreservesHeaderAndStreamsExactBody() async throws {
        let source = URL(string: "https://primary.fixture.bilivideo.com/video.mp4")!
        let streamer = FixtureRangeTransport(
            media: [source: Data([0, 1, 2, 3, 4])]
        )
        let server = LoopbackPlaybackServer(rangeStreamer: streamer)
        try await server.start()
        defer { server.stop() }
        let localURL = try server.register(
            .progressive(
                try LoopbackProgressiveResource(
                    candidateURLs: [source],
                    contentLength: 5,
                    contentType: "video/mp4",
                    allowsOctetStreamWithContainerEvidence: true,
                    headers: ["Cookie": "must-not-leave"]
                )
            ),
            at: "progressive/media.mp4"
        )
        var request = URLRequest(url: localURL)
        request.setValue("bytes=1-", forHTTPHeaderField: "Range")

        let (body, response) = try await URLSession.shared.data(for: request)

        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")
                == "bytes 1-4/5"
        )
        #expect(body == Data([1, 2, 3, 4]))
        let requests = await streamer.requests
        #expect(requests.map { $0.headers["Range"] } == ["bytes=1-"])
        #expect(requests.first?.headers["Cookie"] == nil)
    }

    @Test
    func firstValidatedSourceSticksAcrossLaterRanges() async throws {
        let primary = URL(string: "https://primary.fixture.bilivideo.com/video.mp4")!
        let backup = URL(string: "https://backup.fixture.bilivideo.com/video.mp4")!
        let streamer = FixtureRangeTransport(
            media: [backup: Data([0, 1, 2, 3])],
            failingURLs: [primary]
        )
        let server = LoopbackPlaybackServer(rangeStreamer: streamer)
        try await server.start()
        defer { server.stop() }
        let localURL = try server.register(
            .progressive(
                try LoopbackProgressiveResource(
                    candidateURLs: [primary, backup],
                    contentLength: 4,
                    contentType: "video/mp4",
                    allowsOctetStreamWithContainerEvidence: false
                )
            ),
            at: "progressive/media.mp4"
        )

        _ = try await request(localURL, range: "bytes=0-1")
        _ = try await request(localURL, range: "bytes=2-3")

        #expect(await streamer.requests.map(\.url) == [primary, backup, backup])
    }

    @Test
    func rejectsUntrustedSourceBeforeStartingServerRoute() throws {
        #expect(throws: LoopbackPlaybackServerError.invalidProgressiveSource) {
            try LoopbackProgressiveResource(
                candidateURLs: [URL(string: "https://example.com/video.mp4")!],
                contentLength: 4,
                contentType: "video/mp4",
                allowsOctetStreamWithContainerEvidence: false
            )
        }
    }

    @Test
    func rejectsProgressiveSourceWhoseDeclaredContainerIsNotMP4() throws {
        #expect(throws: LoopbackPlaybackServerError.invalidProgressiveSource) {
            try LoopbackProgressiveResource(
                candidateURLs: [URL(string: "https://primary.fixture.bilivideo.com/video.mp4")!],
                contentLength: 4,
                contentType: "video/webm",
                allowsOctetStreamWithContainerEvidence: false
            )
        }
    }

    @Test
    func stopReleasesRoutes() async throws {
        let streamer = FixtureRangeTransport(media: [:])
        let server = LoopbackPlaybackServer(rangeStreamer: streamer)
        try await server.start()
        server.stop()
        #expect(throws: LoopbackPlaybackServerError.notStarted) {
            try server.url(for: "progressive/media.mp4")
        }
    }

    @Test(arguments: [0, 2])
    func closesConnectionWhenUpstreamFailsAfterSending206(bodyPrefixLength: Int) async throws {
        let source = URL(string: "https://primary.fixture.bilivideo.com/video.mp4")!
        let server = LoopbackPlaybackServer(
            rangeStreamer: FixtureRangeTransport(
                media: [source: Data([0, 1, 2, 3])],
                truncatedBodyLengths: [source: bodyPrefixLength]
            )
        )
        try await server.start()
        defer { server.stop() }
        let localURL = try server.register(
            .progressive(
                try LoopbackProgressiveResource(
                    candidateURLs: [source],
                    contentLength: 4,
                    contentType: "video/mp4",
                    allowsOctetStreamWithContainerEvidence: true
                )
            ),
            at: "progressive/media.mp4"
        )
        var request = URLRequest(url: localURL)
        request.setValue("bytes=0-3", forHTTPHeaderField: "Range")

        await #expect(throws: (any Error).self) {
            _ = try await URLSession.shared.data(for: request)
        }
    }

    @Test
    @MainActor
    func progressiveUsesTheExistingEngineItemAndClearsItOnStop() async throws {
        let source = URL(string: "https://primary.fixture.bilivideo.com/video.mp4")!
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "video-avc",
                withExtension: "mp4",
                subdirectory: "Fixtures"
            )
        )
        let body = try Data(contentsOf: fixtureURL)
        let bridge = makeFixtureBridge(FixtureRangeTransport(media: [source: body]))
        let engine = AVPlayerEngine(bridge: bridge)
        let player = engine.player
        let sourceModel = ProgressivePlaybackSource(
            primaryURL: source,
            contentLength: Int64(body.count),
            durationMilliseconds: 1_000,
            contentType: "video/mp4",
            container: .mp4
        )

        try await engine.load(
            PlaybackRequest(media: .progressive(sourceModel)),
            identity: PlaybackItemIdentity(bvid: "BVProgressiveFixture", cid: 1)
        )

        let item = try #require(player.currentItem)
        #expect(engine.player === player)
        #expect(item.forwardPlaybackEndTime.isValid)
        #expect(item.forwardPlaybackEndTime.seconds > 0)
        engine.stop()
        #expect(player.currentItem == nil)
        #expect(engine.currentTimelineSnapshot.state == .idle)
    }

    private func request(_ url: URL, range: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        return try await URLSession.shared.data(for: request).0
    }
}
