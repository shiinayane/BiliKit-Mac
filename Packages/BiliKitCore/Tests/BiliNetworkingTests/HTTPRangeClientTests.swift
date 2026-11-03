import Foundation
import Testing

@testable import BiliNetworking

/// 固定逐候选 Range 读取的契约：按顺序尝试候选，返回第一个完全验证的响应，全部失败时逐个报告原因。
///
/// 不安全的候选（loopback 的各种 IP 写法、明文 HTTP）到达 transport 之前就被跳过；请求只带自己的 Range、不带
/// Cookie（见 SECURITY-MODEL §4）；忽略 Range 的 200 在响应头阶段失败；调用方取消时立即以取消结束，不再尝试
/// 后备候选。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HTTPRangeClientTests {
    @Test
    func sendsOwnRangeWithoutCredentialsAndCollectsExactBody() async throws {
        RangeClientURLProtocol.state.configure(
            statusCode: 206,
            headers: ["Content-Range": "bytes 10-12/100"],
            chunks: [Data([0xaa]), Data([0xbb, 0xcc])]
        )
        let url = try #require(URL(string: "https://cdn.example/media"))

        let result = try await makeURLProtocolClient().fetch(
            from: [url],
            range: try HTTPByteRange(start: 10, endInclusive: 12),
            headers: [
                "Range": "bytes=0-0",
                "Cookie": "must-not-leave",
                "Referer": "https://example.com"
            ]
        )

        #expect(result.sourceURL == url)
        #expect(result.contentRange.completeLength == 100)
        #expect(result.body == Data([0xaa, 0xbb, 0xcc]))
        let request = RangeClientURLProtocol.state.lastRequest
        #expect(request?.value(forHTTPHeaderField: "Range") == "bytes=10-12")
        #expect(request?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request?.value(forHTTPHeaderField: "Referer") == "https://example.com")
    }

    /// 服务端忽略 Range 返回 200 整段时，响应头阶段即失败并取消任务，不等待、不累积正文。
    @Test
    func ignoredRangeFailsAtResponseHeadWithoutReadingBody() async throws {
        RangeClientURLProtocol.state.configure(
            statusCode: 200,
            // 声明 Content-Type 让 URLSession 不为内容嗅探等正文，响应头可在正文前交给 client。
            headers: ["Content-Length": "104857600", "Content-Type": "video/mp4"],
            chunks: [],
            withholdsBody: true
        )
        let url = try #require(URL(string: "https://cdn.example/media"))

        let error = await #expect(throws: HTTPRangeClientError.self) {
            try await makeURLProtocolClient().fetch(
                from: [url],
                range: try HTTPByteRange(start: 0, endInclusive: 1_023)
            )
        }

        #expect(
            error == .allCandidatesFailed([HTTPRangeAttempt(url: url, failure: .statusCode(200))])
        )
        await RangeClientURLProtocol.state.waitUntilStopped()
    }

    @Test
    func rejectsUnsafeCandidatesBeforeTransportAndUsesSafeBackup() async throws {
        RangeClientURLProtocol.state.configure(
            statusCode: 206,
            headers: ["Content-Range": "bytes 0-2/100"],
            chunks: [Data([0, 1, 2])]
        )
        let local = try #require(URL(string: "https://127.0.0.1/media"))
        let integerLocal = try #require(URL(string: "https://2130706433/media"))
        let octalLocal = try #require(URL(string: "https://0177.0.0.1/media"))
        let hexadecimalLocal = try #require(URL(string: "https://0x7f000001/media"))
        let plaintext = try #require(URL(string: "http://cdn.example/media"))
        let safe = try #require(URL(string: "https://cdn.example/media"))
        let unsafe = [local, integerLocal, octalLocal, hexadecimalLocal, plaintext]

        // 任一不安全候选若到达 transport 都会拿到同一个 206 并成为结果来源。
        let result = try await makeURLProtocolClient().fetch(
            from: unsafe + [safe],
            range: try HTTPByteRange(start: 0, endInclusive: 2)
        )

        #expect(result.sourceURL == safe)
        #expect(RangeClientURLProtocol.state.lastRequest?.url == safe)
    }

    @Test
    func failsOverAfterCandidateFailures() async throws {
        let first = try #require(URL(string: "https://first.example/media"))
        let second = try #require(URL(string: "https://second.example/media"))
        let third = try #require(URL(string: "https://third.example/media"))
        let streamer = ScriptedRangeStreamer(outcomes: [
            .failure(.statusCode(403)),
            .failure(.invalidContentRange),
            .body(Data([2, 3, 4]))
        ])

        let result = try await HTTPRangeClient(streamer: streamer).fetch(
            from: [first, second, third],
            range: try HTTPByteRange(start: 10, endInclusive: 12)
        )

        #expect(result.sourceURL == third)
        #expect(result.body == Data([2, 3, 4]))
        #expect(await streamer.requestedURLs == [first, second, third])
    }

    @Test
    func reportsEveryCandidateFailure() async throws {
        let first = try #require(URL(string: "https://first.example/media"))
        let second = try #require(URL(string: "https://second.example/media"))
        let third = try #require(URL(string: "https://third.example/media"))
        let streamer = ScriptedRangeStreamer(outcomes: [
            .failure(.statusCode(403)),
            .failure(.missingContentRange),
            .body(Data([0xff, 0xff, 0xff]))
        ])

        let error = await #expect(throws: HTTPRangeClientError.self) {
            try await HTTPRangeClient(streamer: streamer).fetch(
                from: [first, second, third],
                range: try HTTPByteRange(start: 0, endInclusive: 2),
                validateBody: { $0.first == 0 }
            )
        }

        #expect(
            error
                == .allCandidatesFailed([
                    HTTPRangeAttempt(url: first, failure: .statusCode(403)),
                    HTTPRangeAttempt(url: second, failure: .missingContentRange),
                    HTTPRangeAttempt(url: third, failure: .rejectedBody)
                ])
        )
    }

    /// 调用方取消后上游即使以 transport 错误结束，最后一个候选也必须报告为取消。
    @Test(arguments: [false, true])
    func cancellationStopsTheActiveRequestWithoutTryingBackup(
        upstreamReportsTransportError: Bool
    ) async throws {
        let first = try #require(URL(string: "https://first.example/media"))
        let second = try #require(URL(string: "https://second.example/media"))
        let streamer = ScriptedRangeStreamer(outcomes: [
            .hangUntilCancelled(reportsTransportError: upstreamReportsTransportError)
        ])
        let candidates = upstreamReportsTransportError ? [first] : [first, second]
        let range = try HTTPByteRange(start: 0, endInclusive: 2)

        let task = Task {
            try await HTTPRangeClient(streamer: streamer).fetch(
                from: candidates,
                range: range
            )
        }
        await streamer.waitForFirstRequest()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await streamer.requestedURLs == [first])
    }

    private func makeURLProtocolClient() -> HTTPRangeClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeClientURLProtocol.self]
        return HTTPRangeClient(
            streamer: HTTPRangeStreamingClient(
                transport: URLSessionRangeTransport(configuration: configuration)
            )
        )
    }
}

/// 只服务候选循环测试的 streamer：按顺序回放每个候选的结果并记录请求的 URL。
private actor ScriptedRangeStreamer: HTTPRangeStreaming {
    enum Outcome: Sendable {
        case body(Data)
        case failure(HTTPRangeResponseError)
        /// 挂起到调用方取消；60 秒只作超时。
        case hangUntilCancelled(reportsTransportError: Bool)
    }

    private var outcomes: [Outcome]
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedURLs: [URL] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func stream(
        from url: URL,
        rangeHeader: String,
        expectedRange: HTTPByteRange,
        expectedCompleteLength: Int64?,
        headers: [String: String],
        allowedContentTypes: Set<String>?,
        requiresContentLength: Bool,
        onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> HTTPRangeStreamResult {
        requestedURLs.append(url)
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        switch outcomes.removeFirst() {
        case .body(let body):
            try await onResponse(
                HTTPRangeStreamResponse(
                    contentRange: try HTTPContentRange(
                        start: expectedRange.start,
                        endInclusive: expectedRange.endInclusive,
                        completeLength: 100
                    ),
                    contentLength: expectedRange.length,
                    contentType: nil
                )
            )
            try await onChunk(body)
            return HTTPRangeStreamResult(byteCount: UInt64(body.count))
        case .failure(let failure):
            throw failure
        case .hangUntilCancelled(let reportsTransportError):
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                if reportsTransportError {
                    throw HTTPRangeResponseError.transport(errorType: "NSURLError")
                }
                throw error
            }
            throw HTTPRangeResponseError.transport(errorType: "TimedOut")
        }
    }

    func waitForFirstRequest() async {
        guard requestedURLs.isEmpty else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }
}

private final class RangeClientURLProtocol: ScriptedRangeURLProtocol, @unchecked Sendable {
    private static let sharedState = ScriptedRangeURLProtocolState()
    override class var state: ScriptedRangeURLProtocolState { sharedState }
}
