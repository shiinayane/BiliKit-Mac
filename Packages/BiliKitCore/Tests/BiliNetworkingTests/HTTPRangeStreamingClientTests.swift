import Foundation
import Testing

@testable import BiliNetworking

/// 固定流式 Range 读取的契约：响应头先按状态码、Content-Range、总长、Content-Length 与类型验证，通过之后才交付
/// 正文回调。
///
/// 请求去掉 Cookie 与 Authorization、只带自己的 Range（见 SECURITY-MODEL §4）；被拒绝的重定向不等 3xx 正文；
/// 正文长度必须与区间完全一致；只有要求时才拒绝缺少 Content-Length 的响应；下游阻塞时回调串行、正文完整有序；
/// 取消会停掉上游任务。
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

    /// 状态码、区间、总长、长度与类型不符时在响应头阶段失败，一个回调也不调；被拒绝的 3xx 见
    /// `rejectedRedirectFailsWithoutWaitingForItsBody`。
    @Test(arguments: RejectedResponseHead.allCases)
    func rejectsStatusRangeLengthTotalAndContentTypeBeforeBody(
        head: RejectedResponseHead
    ) async throws {
        let events = StreamEventRecorder()
        StreamingRangeURLProtocol.state.configure(
            statusCode: head.statusCode,
            headers: head.headers,
            chunks: [Data([1, 2, 3, 4])]
        )
        await #expect(throws: try head.expectedError()) {
            try await streamFourBytes(events: events)
        }
        #expect(await events.values.isEmpty)
    }

    /// 被拒绝的重定向在重定向回调里就以它的状态码失败并取消上游，不等 3xx 正文传完。
    @Test
    func rejectedRedirectFailsWithoutWaitingForItsBody() async throws {
        StreamingRangeURLProtocol.state.configure(
            statusCode: 302,
            headers: ["Location": "https://redirect.example/video.mp4"],
            chunks: [],
            withholdsBody: true
        )
        let events = StreamEventRecorder()
        await #expect(throws: HTTPRangeResponseError.statusCode(302)) {
            try await streamFourBytes(events: events)
        }
        #expect(await events.values.isEmpty)
        await StreamingRangeURLProtocol.state.waitUntilStopped()
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
            chunks: [],
            withholdsBody: true
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

/// 请求 `bytes=0-3`、总长 10、只接受 `video/mp4` 时，在正文之前就被拒绝的响应头。
enum RejectedResponseHead: CaseIterable, Sendable {
    case ignoredRange
    case mismatchedRange
    case mismatchedCompleteLength
    case mismatchedContentLength
    case unsupportedContentType

    var statusCode: Int { self == .ignoredRange ? 200 : 206 }

    var headers: [String: String] {
        switch self {
        case .ignoredRange: [:]
        case .mismatchedRange: Self.head("bytes 0-2/10", length: "3", type: "video/mp4")
        case .mismatchedCompleteLength: Self.head("bytes 0-3/11", length: "4", type: "video/mp4")
        case .mismatchedContentLength: Self.head("bytes 0-3/10", length: "3", type: "video/mp4")
        case .unsupportedContentType: Self.head("bytes 0-3/10", length: "4", type: "text/html")
        }
    }

    private static func head(
        _ contentRange: String,
        length: String,
        type: String
    ) -> [String: String] {
        ["Content-Range": contentRange, "Content-Length": length, "Content-Type": type]
    }

    func expectedError() throws -> HTTPRangeResponseError {
        switch self {
        case .ignoredRange:
            .statusCode(200)
        case .mismatchedRange:
            .mismatchedContentRange(
                expected: try HTTPByteRange(start: 0, endInclusive: 3),
                actual: try HTTPContentRange.parse("bytes 0-2/10")
            )
        case .mismatchedCompleteLength:
            .mismatchedCompleteLength(expected: 10, actual: 11)
        case .mismatchedContentLength:
            .mismatchedContentLength(expected: 4, actual: 3)
        case .unsupportedContentType:
            .unsupportedContentType("text/html")
        }
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
