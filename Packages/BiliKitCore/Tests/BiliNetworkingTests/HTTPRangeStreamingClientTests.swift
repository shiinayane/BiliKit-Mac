import Foundation
import Testing

@testable import BiliNetworking

@Suite(.serialized, .timeLimit(.minutes(1)))
struct HTTPRangeStreamingClientTests {
    @Test
    func exact206StreamsOnlyAfterValidatedResponseAndStripsCredentials() async throws {
        StreamingRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes 10-13/100",
                "Content-Length": "4",
                "Content-Type": "video/mp4; charset=binary"
            ],
            chunks: [Data([1, 2]), Data([3, 4])]
        )
        let events = StreamEventRecorder()
        let result = try await makeClient().stream(
            from: URL(string: "https://cdn.example/video.mp4")!,
            rangeHeader: "bytes=10-13",
            expectedRange: try HTTPByteRange(start: 10, endInclusive: 13),
            expectedCompleteLength: 100,
            headers: [
                "Cookie": "must-not-leave",
                "Authorization": "must-not-leave",
                "Referer": "https://www.bilibili.com/"
            ],
            allowedContentTypes: ["video/mp4"],
            onResponse: { _ in await events.append("response") },
            onChunk: { data in await events.append("chunk:\(data.count)") }
        )

        #expect(result.byteCount == 4)
        #expect(await events.values.first == "response")
        let request = StreamingRangeURLProtocol.state.lastRequest
        #expect(request?.value(forHTTPHeaderField: "Range") == "bytes=10-13")
        #expect(request?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request?.value(forHTTPHeaderField: "Referer") != nil)
    }

    @Test
    func rejectsStatusRangeLengthTotalAndContentTypeBeforeBody() async throws {
        let cases: [(Int, [String: String], HTTPRangeResponseError)] = [
            (200, [:], .statusCode(200)),
            (302, ["Location": "https://redirect.example/video.mp4"], .statusCode(302)),
            (
                206,
                [
                    "Content-Range": "bytes 0-2/10", "Content-Length": "3",
                    "Content-Type": "video/mp4"
                ],
                .mismatchedContentRange(
                    expected: try HTTPByteRange(start: 0, endInclusive: 3),
                    actual: try HTTPContentRange.parse("bytes 0-2/10")
                )
            ),
            (
                206,
                [
                    "Content-Range": "bytes 0-3/11", "Content-Length": "4",
                    "Content-Type": "video/mp4"
                ],
                .mismatchedCompleteLength(expected: 10, actual: 11)
            ),
            (
                206,
                [
                    "Content-Range": "bytes 0-3/10", "Content-Length": "3",
                    "Content-Type": "video/mp4"
                ],
                .mismatchedContentLength(expected: 4, actual: 3)
            ),
            (
                206,
                [
                    "Content-Range": "bytes 0-3/10", "Content-Length": "4",
                    "Content-Type": "text/html"
                ],
                .unsupportedContentType("text/html")
            )
        ]

        for (status, headers, expectedError) in cases {
            let events = StreamEventRecorder()
            StreamingRangeURLProtocol.state.configure(
                statusCode: status,
                headers: headers,
                chunks: [Data([1, 2, 3, 4])]
            )
            await #expect(throws: expectedError) {
                try await streamFourBytes(events: events)
            }
            #expect(await events.values.isEmpty)
        }
    }

    @Test
    func rejectsShortAndLongBodies() async throws {
        let headers = [
            "Content-Range": "bytes 0-3/10",
            "Content-Length": "4",
            "Content-Type": "video/mp4"
        ]
        StreamingRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: headers,
            chunks: [Data([1, 2, 3])]
        )
        await #expect(
            throws: HTTPRangeResponseError.bodyLengthMismatch(expected: 4, actual: 3)
        ) {
            try await streamFourBytes()
        }
        StreamingRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: headers,
            chunks: [Data([1, 2, 3, 4, 5])]
        )
        await #expect(
            throws: HTTPRangeResponseError.bodyLengthMismatch(expected: 4, actual: 5)
        ) {
            try await streamFourBytes()
        }
    }

    @Test(arguments: [nil, "text/html", "application/octet-stream"] as [String?])
    func unrestrictedContentTypeStillRequiresExactRangeAndLength(
        contentType: String?
    ) async throws {
        var headers = ["Content-Range": "bytes 0-3/10", "Content-Length": "4"]
        headers["Content-Type"] = contentType
        StreamingRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: headers,
            chunks: [Data([1, 2, 3, 4])]
        )
        #expect(try await streamFourBytes(allowedContentTypes: nil).byteCount == 4)

        headers["Content-Range"] = "bytes 0-3/11"
        StreamingRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: headers,
            chunks: [Data([1, 2, 3, 4])]
        )
        await #expect(
            throws: HTTPRangeResponseError.mismatchedCompleteLength(expected: 10, actual: 11)
        ) {
            try await streamFourBytes(allowedContentTypes: nil)
        }
    }

    /// 只有要求时才拒绝缺少 Content-Length 的响应。
    ///
    /// DASH 分段允许上游省略该头，progressive 仍要求；两者都按实际字节核对正文长度。
    @Test(arguments: [true, false])
    func missingContentLengthIsRejectedOnlyWhenRequired(requiresContentLength: Bool) async throws {
        StreamingRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: ["Content-Range": "bytes 0-3/10", "Content-Type": "video/mp4"],
            chunks: [Data([1, 2, 3, 4])]
        )
        if requiresContentLength {
            await #expect(throws: HTTPRangeResponseError.missingContentLength) {
                try await streamFourBytes(requiresContentLength: true)
            }
        } else {
            #expect(try await streamFourBytes(requiresContentLength: false).byteCount == 4)
        }

        StreamingRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: ["Content-Range": "bytes 0-3/10", "Content-Type": "video/mp4"],
            chunks: [Data([1, 2, 3])]
        )
        await #expect(
            throws: HTTPRangeResponseError.bodyLengthMismatch(expected: 4, actual: 3)
        ) {
            try await streamFourBytes(requiresContentLength: false)
        }
    }

    /// 下游阻塞期间上游继续送达：最多暂存一个 chunk，回调串行执行，正文完整且有序。
    @Test
    func blockedDownstreamReceivesCompleteOrderedBodyOneCallbackAtATime() async throws {
        StreamingRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes 0-3/10",
                "Content-Length": "4",
                "Content-Type": "video/mp4"
            ],
            chunks: [Data([1, 2]), Data([3, 4])]
        )
        let consumer = GatedChunkConsumer()
        let url = try #require(URL(string: "https://cdn.example/video.mp4"))
        let range = try HTTPByteRange(start: 0, endInclusive: 3)
        let client = makeClient()
        let stream = Task {
            try await client.stream(
                from: url,
                rangeHeader: "bytes=0-3",
                expectedRange: range,
                expectedCompleteLength: 10,
                headers: [:],
                allowedContentTypes: ["video/mp4"],
                onResponse: { _ in },
                onChunk: { data in await consumer.consume(data) }
            )
        }

        await StreamingRangeURLProtocol.state.waitUntilDelivered(bytes: 4)
        await consumer.release()
        let result = try await stream.value

        #expect(result.byteCount == 4)
        #expect(await consumer.received == Data([1, 2, 3, 4]))
        #expect(await consumer.maximumConcurrentCallbacks == 1)
    }

    @Test
    func cancellationStopsTheUpstreamTask() async throws {
        StreamingRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes 0-3/10",
                "Content-Length": "4",
                "Content-Type": "video/mp4"
            ],
            chunks: [Data([1, 2, 3, 4])],
            delay: 5
        )
        let task = Task { try await streamFourBytes() }
        await StreamingRangeURLProtocol.state.waitUntilStarted()
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        await StreamingRangeURLProtocol.state.waitUntilStopped()
    }

    private func streamFourBytes(
        events: StreamEventRecorder? = nil,
        allowedContentTypes: Set<String>? = ["video/mp4"],
        requiresContentLength: Bool = true
    ) async throws -> HTTPRangeStreamResult {
        let url = try #require(URL(string: "https://cdn.example/video.mp4"))
        return try await makeClient().stream(
            from: url,
            rangeHeader: "bytes=0-3",
            expectedRange: try HTTPByteRange(start: 0, endInclusive: 3),
            expectedCompleteLength: 10,
            headers: [:],
            allowedContentTypes: allowedContentTypes,
            requiresContentLength: requiresContentLength,
            onResponse: { _ in await events?.append("response") },
            onChunk: { data in await events?.append("chunk:\(data.count)") }
        )
    }

    private func makeClient() -> HTTPRangeStreamingClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingRangeURLProtocol.self]
        return HTTPRangeStreamingClient(
            transport: URLSessionRangeTransport(configuration: configuration)
        )
    }
}

/// 第一个 chunk 的回调被挡住直到 `release()`，同时记录并发回调的峰值。
private actor GatedChunkConsumer {
    private(set) var received = Data()
    private(set) var maximumConcurrentCallbacks = 0
    private var activeCallbacks = 0
    private var isReleased = false
    private var gate: CheckedContinuation<Void, Never>?

    func consume(_ data: Data) async {
        activeCallbacks += 1
        maximumConcurrentCallbacks = max(maximumConcurrentCallbacks, activeCallbacks)
        if !isReleased {
            await withCheckedContinuation { gate = $0 }
        }
        received.append(data)
        activeCallbacks -= 1
    }

    func release() {
        isReleased = true
        gate?.resume()
        gate = nil
    }
}

private actor StreamEventRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private final class StreamingRangeURLProtocol: ScriptedRangeURLProtocol, @unchecked Sendable {
    private static let sharedState = ScriptedRangeURLProtocolState()
    override class var state: ScriptedRangeURLProtocolState { sharedState }
}
