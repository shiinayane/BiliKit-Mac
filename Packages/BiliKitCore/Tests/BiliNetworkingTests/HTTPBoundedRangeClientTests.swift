import Foundation
import Testing

@testable import BiliNetworking

@Suite(.serialized, .timeLimit(.minutes(1)))
struct HTTPBoundedRangeClientTests {
    @Test
    func rejectsHTTP200WithoutWaitingForDeclaredFullBodyAndCancelsTask() async throws {
        RangeStreamingURLProtocol.state.configure(
            statusCode: 200,
            headers: ["Content-Length": "104857600"],
            body: Data(repeating: 0xaa, count: 1_024),
            keepsBodyPending: true
        )
        let client = makeClient()

        await #expect(throws: HTTPBoundedRangeError.statusCode(200)) {
            try await client.fetch(
                from: URL(string: "https://cdn.example/video")!,
                range: try HTTPByteRange(start: 0, endInclusive: 1_023),
                headers: [:],
                collectBody: false
            )
        }
        try await waitUntil { RangeStreamingURLProtocol.state.wasStopped }
        #expect(RangeStreamingURLProtocol.state.deliveredBodyBytes < 100 * 1_024 * 1_024)
    }

    @Test
    func acceptsOnlyExact206ContentRangeLengthAndDiscardsBodyWhenRequested() async throws {
        RangeStreamingURLProtocol.state.configure(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes 10-12/100",
                "Content-Length": "3",
            ],
            body: Data([1, 2, 3]),
            keepsBodyPending: false
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
            RangeStreamingURLProtocol.state.lastRequest?.value(forHTTPHeaderField: "Range")
                == "bytes=10-12"
        )
        #expect(
            RangeStreamingURLProtocol.state.lastRequest?.value(forHTTPHeaderField: "Cookie") == nil
        )
    }

    @Test
    func sharedSessionAcceptsSequentialExactRanges() async throws {
        let client = makeClient()
        RangeStreamingURLProtocol.state.configure(
            statusCode: 206,
            headers: ["Content-Range": "bytes 0-2/100", "Content-Length": "3"],
            body: Data([1, 2, 3]),
            keepsBodyPending: false
        )
        let first = try await client.fetch(
            from: URL(string: "https://cdn.example/video")!,
            range: try HTTPByteRange(start: 0, endInclusive: 2),
            headers: [:],
            collectBody: false
        )

        RangeStreamingURLProtocol.state.configure(
            statusCode: 206,
            headers: ["Content-Range": "bytes 3-5/100", "Content-Length": "3"],
            body: Data([4, 5, 6]),
            keepsBodyPending: false
        )
        let second = try await client.fetch(
            from: URL(string: "https://cdn.example/video")!,
            range: try HTTPByteRange(start: 3, endInclusive: 5),
            headers: [:],
            collectBody: false
        )
        client.invalidate()

        #expect(first.byteCount == 3)
        #expect(second.byteCount == 3)
    }

    @Test
    func rejectsMismatchedContentLengthWithoutReadingBody() async throws {
        RangeStreamingURLProtocol.state.configure(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes 0-2/100",
                "Content-Length": "4",
            ],
            body: Data([1, 2, 3, 4]),
            keepsBodyPending: true
        )

        await #expect(
            throws: HTTPBoundedRangeError.mismatchedContentLength(expected: 3, actual: 4)
        ) {
            try await makeClient().fetch(
                from: URL(string: "https://cdn.example/video")!,
                range: try HTTPByteRange(start: 0, endInclusive: 2),
                headers: [:],
                collectBody: true
            )
        }
    }

    @Test
    func hugeRetainedRangeFailsByProtocolWithoutIntegerTrap() async throws {
        RangeStreamingURLProtocol.state.configure(
            statusCode: 200,
            headers: ["Content-Length": "0"],
            body: Data(),
            keepsBodyPending: false
        )

        await #expect(throws: HTTPBoundedRangeError.statusCode(200)) {
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
        configuration.protocolClasses = [RangeStreamingURLProtocol.self]
        return HTTPBoundedRangeClient(
            transport: URLSessionBoundedRangeTransport(configuration: configuration)
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

private final class RangeStreamingURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = RangeStreamingURLProtocolState()

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
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if configuration.keepsBodyPending {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
                [weak self] in
                guard let self, !Self.state.wasStopped else { return }
                Self.state.markDelivered(configuration.body.count)
                client?.urlProtocol(self, didLoad: configuration.body)
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        Self.state.markDelivered(configuration.body.count)
        client?.urlProtocol(self, didLoad: configuration.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.state.markStopped()
    }
}

private struct RangeProtocolConfiguration {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    let keepsBodyPending: Bool
}

private final class RangeStreamingURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var configuration = RangeProtocolConfiguration(
        statusCode: 500,
        headers: [:],
        body: Data(),
        keepsBodyPending: false
    )
    private var stopped = false
    private var delivered = 0
    private var capturedRequest: URLRequest?

    var wasStopped: Bool { lock.withLock { stopped } }
    var deliveredBodyBytes: Int { lock.withLock { delivered } }
    var lastRequest: URLRequest? { lock.withLock { capturedRequest } }

    func configure(
        statusCode: Int,
        headers: [String: String],
        body: Data,
        keepsBodyPending: Bool
    ) {
        lock.withLock {
            configuration = RangeProtocolConfiguration(
                statusCode: statusCode,
                headers: headers,
                body: body,
                keepsBodyPending: keepsBodyPending
            )
            stopped = false
            delivered = 0
            capturedRequest = nil
        }
    }

    func begin(request: URLRequest) -> RangeProtocolConfiguration {
        lock.withLock {
            capturedRequest = request
            return configuration
        }
    }

    func markStopped() { lock.withLock { stopped = true } }
    func markDelivered(_ count: Int) { lock.withLock { delivered += count } }
}
