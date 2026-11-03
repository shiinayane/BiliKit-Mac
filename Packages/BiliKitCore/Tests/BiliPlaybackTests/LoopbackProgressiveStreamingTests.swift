import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliPlayback

/// progressive 路由原样转发单一 Range，固定首个通过验证的来源，下游断开即取消上游。
///
/// 对应 SECURITY-MODEL §5：上游请求去除 Cookie，构造时拒绝白名单外或非 MP4 的来源，206 之后的上游失败只能断开连接，
/// server 停止后不再生成路由地址。
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

    /// AVPlayer 在响应头之前断开时立即取消上游请求，且不把断开当成来源失败去请求备用线路。
    @Test
    func downstreamCloseCancelsUpstreamWithoutTryingBackup() async throws {
        let primary = URL(string: "https://primary.fixture.bilivideo.com/video.mp4")!
        let backup = URL(string: "https://backup.fixture.bilivideo.com/video.mp4")!
        let streamer = FixtureRangeTransport(
            media: [primary: Data([0, 1, 2, 3]), backup: Data([0, 1, 2, 3])],
            // 除 0-0 以外的 Range 在 primary 上挂起到取消。
            blockingURLIndexRanges: [primary: try MediaByteRange(start: 0, endInclusive: 0)]
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
        let port = try #require(localURL.port)
        let client = try RawLoopbackClient(port: port)
        try await client.connect()
        try await client.send(
            Data(
                ("GET \(localURL.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
                    + "Range: bytes=1-3\r\n\r\n").utf8
            )
        )

        await streamer.waitForBlockedRequest()
        client.cancel()
        await streamer.waitForCancelledBlockedRequests(1)

        #expect(await streamer.requests.map(\.url) == [primary])
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

    private func request(_ url: URL, range: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        return try await URLSession.shared.data(for: request).0
    }
}
