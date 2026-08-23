import Foundation
import Testing

@testable import BiliNetworking

@Suite(.serialized, .timeLimit(.minutes(1)))
struct HTTPRangeStreamingClientTests {
    @Test
    func exact206StreamsOnlyAfterValidatedResponseAndStripsCredentials() async throws {
        RangeStreamURLProtocol.state.configure(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes 10-13/100",
                "Content-Length": "4",
                "Content-Type": "video/mp4; charset=binary",
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
                "Referer": "https://www.bilibili.com/",
            ],
            allowedContentTypes: ["video/mp4"],
            onResponse: { _ in await events.append("response") },
            onChunk: { data in await events.append("chunk:\(data.count)") }
        )

        #expect(result.byteCount == 4)
        #expect(await events.values.first == "response")
        let request = RangeStreamURLProtocol.state.lastRequest
        #expect(request?.value(forHTTPHeaderField: "Range") == "bytes=10-13")
        #expect(request?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request?.value(forHTTPHeaderField: "Referer") != nil)
    }

    @Test
    func rejectsStatusRangeLengthTotalAndContentTypeBeforeBody() async throws {
        let cases: [(Int, [String: String], HTTPRangeStreamingError)] = [
            (200, [:], .statusCode(200)),
            (302, ["Location": "https://redirect.example/video.mp4"], .statusCode(302)),
            (
                206,
                [
                    "Content-Range": "bytes 0-2/10", "Content-Length": "3",
                    "Content-Type": "video/mp4",
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
                    "Content-Type": "video/mp4",
                ],
                .mismatchedCompleteLength(expected: 10, actual: 11)
            ),
            (
                206,
                [
                    "Content-Range": "bytes 0-3/10", "Content-Length": "3",
                    "Content-Type": "video/mp4",
                ],
                .mismatchedContentLength(expected: 4, actual: 3)
            ),
            (
                206,
                [
                    "Content-Range": "bytes 0-3/10", "Content-Length": "4",
                    "Content-Type": "text/html",
                ],
                .unsupportedContentType("text/html")
            ),
        ]

        for (status, headers, expectedError) in cases {
            let events = StreamEventRecorder()
            RangeStreamURLProtocol.state.configure(
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
            "Content-Type": "video/mp4",
        ]
        RangeStreamURLProtocol.state.configure(
            statusCode: 206,
            headers: headers,
            chunks: [Data([1, 2, 3])]
        )
        await #expect(
            throws: HTTPRangeStreamingError.bodyLengthMismatch(expected: 4, actual: 3)
        ) {
            try await streamFourBytes()
        }
        RangeStreamURLProtocol.state.configure(
            statusCode: 206,
            headers: headers,
            chunks: [Data([1, 2, 3, 4, 5])]
        )
        await #expect(
            throws: HTTPRangeStreamingError.bodyLengthMismatch(expected: 4, actual: 5)
        ) {
            try await streamFourBytes()
        }
    }

    @Test
    func slowForwardingAcceptsCompleteBodyWithBoundedChunkDelivery() async throws {
        RangeStreamURLProtocol.state.configure(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes 0-3/10",
                "Content-Length": "4",
                "Content-Type": "video/mp4",
            ],
            chunks: [Data([1, 2]), Data([3, 4])]
        )
        let recorder = StreamEventRecorder()

        let result = try await makeClient().stream(
            from: URL(string: "https://cdn.example/video.mp4")!,
            rangeHeader: "bytes=0-3",
            expectedRange: try HTTPByteRange(start: 0, endInclusive: 3),
            expectedCompleteLength: 10,
            headers: [:],
            allowedContentTypes: ["video/mp4"],
            onResponse: { _ in },
            onChunk: { data in
                await recorder.append("chunk:\(data.count)")
                try await Task.sleep(for: .milliseconds(10))
            }
        )

        #expect(result.byteCount == 4)
        let deliveredSizes = await recorder.values.compactMap {
            Int($0.replacingOccurrences(of: "chunk:", with: ""))
        }
        #expect(deliveredSizes.reduce(0, +) == 4)
        #expect(deliveredSizes.count <= 2)
    }

    @Test
    func cancellationStopsTheUpstreamTask() async throws {
        RangeStreamURLProtocol.state.configure(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes 0-3/10",
                "Content-Length": "4",
                "Content-Type": "video/mp4",
            ],
            chunks: [Data([1, 2, 3, 4])],
            delay: 5
        )
        let task = Task { try await streamFourBytes() }
        await RangeStreamURLProtocol.state.waitUntilStarted()
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        try await waitUntil { RangeStreamURLProtocol.state.wasStopped }
    }

    private func streamFourBytes(
        events: StreamEventRecorder? = nil
    ) async throws -> HTTPRangeStreamResult {
        let url = try #require(URL(string: "https://cdn.example/video.mp4"))
        return try await makeClient().stream(
            from: url,
            rangeHeader: "bytes=0-3",
            expectedRange: try HTTPByteRange(start: 0, endInclusive: 3),
            expectedCompleteLength: 10,
            headers: [:],
            allowedContentTypes: ["video/mp4"],
            onResponse: { _ in await events?.append("response") },
            onChunk: { data in await events?.append("chunk:\(data.count)") }
        )
    }

    private func makeClient() -> HTTPRangeStreamingClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeStreamURLProtocol.self]
        return HTTPRangeStreamingClient(
            transport: URLSessionRangeStreamingTransport(configuration: configuration)
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition())
    }
}

private actor StreamEventRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private final class RangeStreamURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = RangeStreamURLProtocolState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let configuration = Self.state.begin(request: request)
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: configuration.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: configuration.headers
            )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let deliver: @Sendable () -> Void = { [weak self] in
            guard let self, !Self.state.wasStopped else { return }
            for chunk in configuration.chunks {
                guard !Self.state.wasStopped else { return }
                Self.state.markDelivered(chunk.count)
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        if configuration.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + configuration.delay) {
                deliver()
            }
        } else {
            deliver()
        }
    }

    override func stopLoading() { Self.state.markStopped() }
}

private struct RangeStreamConfiguration: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let chunks: [Data]
    let delay: TimeInterval
}

private final class RangeStreamURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var configuration = RangeStreamConfiguration(
        statusCode: 500,
        headers: [:],
        chunks: [],
        delay: 0
    )
    private var stopped = false
    private var delivered = 0
    private var capturedRequest: URLRequest?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    var wasStopped: Bool { lock.withLock { stopped } }
    var deliveredBodyBytes: Int { lock.withLock { delivered } }
    var lastRequest: URLRequest? { lock.withLock { capturedRequest } }

    func configure(
        statusCode: Int,
        headers: [String: String],
        chunks: [Data],
        delay: TimeInterval = 0
    ) {
        lock.withLock {
            configuration = RangeStreamConfiguration(
                statusCode: statusCode,
                headers: headers,
                chunks: chunks,
                delay: delay
            )
            stopped = false
            delivered = 0
            capturedRequest = nil
        }
    }

    func begin(request: URLRequest) -> RangeStreamConfiguration {
        let result = lock.withLock {
            capturedRequest = request
            let waiters = startWaiters
            startWaiters.removeAll()
            return (configuration, waiters)
        }
        for waiter in result.1 { waiter.resume() }
        return result.0
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let isStarted = lock.withLock {
                guard capturedRequest == nil else { return true }
                startWaiters.append(continuation)
                return false
            }
            if isStarted { continuation.resume() }
        }
    }

    func markStopped() { lock.withLock { stopped = true } }
    func markDelivered(_ count: Int) { lock.withLock { delivered += count } }
}
