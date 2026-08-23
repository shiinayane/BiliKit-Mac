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
        let source = URL(string: "https://primary.example.invalid/video.mp4")!
        let streamer = FixtureProgressiveStreamer(
            bodies: [source: Data([0, 1, 2, 3, 4])]
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
        #expect(streamer.requests.map(\.rangeHeader) == ["bytes=1-"])
        #expect(streamer.requests.first?.headers["Cookie"] == nil)
    }

    @Test
    func firstValidatedSourceSticksAcrossLaterRanges() async throws {
        let primary = URL(string: "https://primary.example.invalid/video.mp4")!
        let backup = URL(string: "https://backup.example.invalid/video.mp4")!
        let streamer = FixtureProgressiveStreamer(
            bodies: [backup: Data([0, 1, 2, 3])],
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

        #expect(streamer.requests.map(\.url) == [primary, backup, backup])
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
                candidateURLs: [URL(string: "https://primary.example.invalid/video.mp4")!],
                contentLength: 4,
                contentType: "video/webm",
                allowsOctetStreamWithContainerEvidence: false
            )
        }
    }

    @Test
    func stopInvalidatesAndCancelsProgressiveStreamer() async throws {
        let streamer = FixtureProgressiveStreamer(bodies: [:])
        let server = LoopbackPlaybackServer(rangeStreamer: streamer)
        try await server.start()
        server.stop()
        #expect(streamer.wasInvalidated)
        #expect(!server.diagnosticsSnapshot().isRunning)
    }

    @Test(arguments: [Data(), Data([0, 1])])
    func closesConnectionWhenUpstreamFailsAfterSending206(bodyPrefix: Data) async throws {
        let source = URL(string: "https://primary.example.invalid/video.mp4")!
        let server = LoopbackPlaybackServer(
            rangeStreamer: PostHeadFailureStreamer(bodyPrefix: bodyPrefix)
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
        let source = URL(string: "https://primary.example.invalid/video.mp4")!
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "video-avc",
                withExtension: "mp4",
                subdirectory: "Fixtures"
            )
        )
        let body = try Data(contentsOf: fixtureURL)
        let streamer = FixtureProgressiveStreamer(bodies: [source: body])
        let bridge = DASHToHLSBridge(
            rangeClient: HTTPRangeClient(),
            serverFactory: { rangeClient in
                LoopbackPlaybackServer(
                    rangeClient: rangeClient,
                    rangeStreamer: streamer
                )
            }
        )
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

private struct ProgressiveStreamRequest: Sendable {
    let url: URL
    let rangeHeader: String
    let headers: [String: String]
}

private final class FixtureProgressiveStreamer: HTTPRangeStreaming,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let bodies: [URL: Data]
    private let failingURLs: Set<URL>
    private var capturedRequests: [ProgressiveStreamRequest] = []
    private var invalidated = false

    init(bodies: [URL: Data], failingURLs: Set<URL> = []) {
        self.bodies = bodies
        self.failingURLs = failingURLs
    }

    var requests: [ProgressiveStreamRequest] { lock.withLock { capturedRequests } }
    var wasInvalidated: Bool { lock.withLock { invalidated } }

    func stream(
        from url: URL,
        rangeHeader: String,
        expectedRange: HTTPByteRange,
        expectedCompleteLength: Int64,
        headers: [String: String],
        allowedContentTypes: Set<String>,
        onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> HTTPRangeStreamResult {
        lock.withLock {
            capturedRequests.append(
                ProgressiveStreamRequest(
                    url: url,
                    rangeHeader: rangeHeader,
                    headers: headers
                )
            )
        }
        if failingURLs.contains(url) { throw FixtureProgressiveError.rejected }
        guard let body = bodies[url] else { throw FixtureProgressiveError.rejected }
        let lower = Int(expectedRange.start)
        let upper = Int(expectedRange.endInclusive) + 1
        let slice = body.subdata(in: lower..<upper)
        try await onResponse(
            HTTPRangeStreamResponse(
                contentRange: try HTTPContentRange(
                    start: expectedRange.start,
                    endInclusive: expectedRange.endInclusive,
                    completeLength: expectedCompleteLength
                ),
                contentLength: expectedRange.length,
                contentType: "video/mp4"
            )
        )
        let midpoint = max(1, slice.count / 2)
        try await onChunk(slice.prefix(midpoint))
        if midpoint < slice.count {
            try await onChunk(slice.suffix(from: midpoint))
        }
        return HTTPRangeStreamResult(byteCount: UInt64(slice.count))
    }

    func invalidate() { lock.withLock { invalidated = true } }
}

private enum FixtureProgressiveError: Error { case rejected }

private struct PostHeadFailureStreamer: HTTPRangeStreaming {
    let bodyPrefix: Data

    func stream(
        from url: URL,
        rangeHeader: String,
        expectedRange: HTTPByteRange,
        expectedCompleteLength: Int64,
        headers: [String: String],
        allowedContentTypes: Set<String>,
        onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> HTTPRangeStreamResult {
        try await onResponse(
            HTTPRangeStreamResponse(
                contentRange: try HTTPContentRange(
                    start: expectedRange.start,
                    endInclusive: expectedRange.endInclusive,
                    completeLength: expectedCompleteLength
                ),
                contentLength: expectedRange.length,
                contentType: "video/mp4"
            )
        )
        if !bodyPrefix.isEmpty {
            try await onChunk(bodyPrefix)
        }
        throw HTTPRangeStreamingError.bodyLengthMismatch(
            expected: expectedRange.length,
            actual: UInt64(bodyPrefix.count)
        )
    }

    func invalidate() {}
}
