import Foundation
import Testing

@testable import BiliNetworking

/// 固定有界 Range 读取的契约：只接受精确的 206 与对得上的 Content-Range、Content-Length，不符时在响应头阶段
/// 失败并取消任务，不等正文。
///
/// 请求只带自己的 Range、不带 Cookie（见 SECURITY-MODEL §4）；按要求只计数或保留正文；超大区间按协议失败，
/// 不触发整数溢出。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HTTPBoundedRangeClientTests {
    @Test
    func rejectsHTTP200WithoutWaitingForDeclaredFullBodyAndCancelsTask() async throws {
        BoundedRangeURLProtocol.state.configure(
            statusCode: 200,
            // 声明 Content-Type 让 URLSession 不为内容嗅探等正文，响应头可在正文前交给 client。
            headers: ["Content-Length": "104857600", "Content-Type": "video/mp4"],
            chunks: [],
            withholdsBody: true
        )
        let client = makeClient()

        await #expect(throws: HTTPRangeResponseError.statusCode(200)) {
            try await client.fetch(
                from: URL(string: "https://cdn.example/video")!,
                range: try HTTPByteRange(start: 0, endInclusive: 1_023),
                headers: [:],
                collectBody: false
            )
        }
        await BoundedRangeURLProtocol.state.waitUntilStopped()
    }

    @Test
    func acceptsOnlyExact206ContentRangeLengthAndDiscardsBodyWhenRequested() async throws {
        BoundedRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes 10-12/100",
                "Content-Length": "3"
            ],
            chunks: [Data([1, 2, 3])]
        )
        let result = try await makeClient().fetch(
            from: URL(string: "https://cdn.example/video")!,
            range: try HTTPByteRange(start: 10, endInclusive: 12),
            headers: ["Cookie": "must-not-leave", "Referer": "https://www.bilibili.com/"],
            collectBody: false
        )

        #expect(result.byteCount == 3)
        #expect(result.body == nil)
        #expect(result.requestDurationSeconds > 0)
        #expect(
            BoundedRangeURLProtocol.state.lastRequest?.value(forHTTPHeaderField: "Range")
                == "bytes=10-12"
        )
        #expect(
            BoundedRangeURLProtocol.state.lastRequest?.value(forHTTPHeaderField: "Cookie") == nil
        )
    }

    @Test
    func rejectsMismatchedContentLengthWithoutReadingBody() async throws {
        BoundedRangeURLProtocol.state.configure(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes 0-2/100",
                "Content-Length": "4",
                "Content-Type": "video/mp4"
            ],
            chunks: [],
            withholdsBody: true
        )

        await #expect(
            throws: HTTPRangeResponseError.mismatchedContentLength(expected: 3, actual: 4)
        ) {
            try await makeClient().fetch(
                from: URL(string: "https://cdn.example/video")!,
                range: try HTTPByteRange(start: 0, endInclusive: 2),
                headers: [:],
                collectBody: true
            )
        }
        await BoundedRangeURLProtocol.state.waitUntilStopped()
    }

    @Test
    func hugeRetainedRangeFailsByProtocolWithoutIntegerTrap() async throws {
        BoundedRangeURLProtocol.state.configure(
            statusCode: 200,
            headers: ["Content-Length": "0"],
            chunks: [Data()]
        )

        await #expect(throws: HTTPRangeResponseError.statusCode(200)) {
            try await makeClient().fetch(
                from: URL(string: "https://cdn.example/video")!,
                range: try HTTPByteRange(start: 0, endInclusive: .max),
                headers: [:],
                collectBody: true
            )
        }
    }

    private func makeClient() -> HTTPBoundedRangeClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedRangeURLProtocol.self]
        return HTTPBoundedRangeClient(
            transport: URLSessionRangeTransport(configuration: configuration)
        )
    }
}

private final class BoundedRangeURLProtocol: ScriptedRangeURLProtocol, @unchecked Sendable {
    private static let sharedState = ScriptedRangeURLProtocolState()
    override class var state: ScriptedRangeURLProtocolState { sharedState }
}
