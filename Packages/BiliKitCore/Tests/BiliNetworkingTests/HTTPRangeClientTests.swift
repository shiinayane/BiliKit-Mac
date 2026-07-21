import Foundation
import Testing
@testable import BiliNetworking

struct HTTPRangeClientTests {
    @Test
    func sendsRangeHeaderAndAcceptsMatchingPartialResponse() async throws {
        let url = try #require(URL(string: "https://cdn.example/media"))
        let transport = RangeStubTransport(
            responses: [
                HTTPResponse(
                    statusCode: 206,
                    headers: ["content-range": "bytes 10-12/100"],
                    body: Data([0xaa, 0xbb, 0xcc])
                ),
            ]
        )
        let client = HTTPRangeClient(transport: transport)
        let range = try HTTPByteRange(start: 10, endInclusive: 12)

        let result = try await client.fetch(
            from: [url],
            range: range,
            headers: ["Range": "bytes=0-0", "Referer": "https://example.com"]
        )

        #expect(result.sourceURL == url)
        #expect(result.body == Data([0xaa, 0xbb, 0xcc]))
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].headers["Range"] == "bytes=10-12")
        #expect(requests[0].headers["Referer"] == "https://example.com")
    }

    @Test
    func failsOverAfterStatusAndContentRangeFailures() async throws {
        let first = try #require(URL(string: "https://first.example/media"))
        let second = try #require(URL(string: "https://second.example/media"))
        let third = try #require(URL(string: "https://third.example/media"))
        let transport = RangeStubTransport(
            responses: [
                HTTPResponse(statusCode: 403, body: Data()),
                HTTPResponse(
                    statusCode: 206,
                    headers: ["Content-Range": "bytes 0-1/100"],
                    body: Data([0, 1])
                ),
                HTTPResponse(
                    statusCode: 206,
                    headers: ["Content-Range": "bytes 10-12/100"],
                    body: Data([2, 3, 4])
                ),
            ]
        )
        let client = HTTPRangeClient(transport: transport)

        let result = try await client.fetch(
            from: [first, second, third],
            range: try HTTPByteRange(start: 10, endInclusive: 12)
        )

        #expect(result.sourceURL == third)
        #expect(await transport.requests.map(\.url) == [first, second, third])
    }

    @Test
    func reportsAllCandidateFailuresWithoutResponseBodies() async throws {
        let first = try #require(URL(string: "https://first.example/media"))
        let second = try #require(URL(string: "https://second.example/media"))
        let transport = RangeStubTransport(
            responses: [
                HTTPResponse(statusCode: 403, body: Data("secret-page".utf8)),
                HTTPResponse(
                    statusCode: 206,
                    headers: [:],
                    body: Data([0, 1, 2])
                ),
            ]
        )
        let client = HTTPRangeClient(transport: transport)

        do {
            _ = try await client.fetch(
                from: [first, second],
                range: try HTTPByteRange(start: 0, endInclusive: 2)
            )
            Issue.record("Expected every CDN candidate to fail")
        } catch let HTTPRangeClientError.allCandidatesFailed(attempts) {
            #expect(
                attempts == [
                    HTTPRangeAttempt(url: first, failure: .statusCode(403)),
                    HTTPRangeAttempt(url: second, failure: .missingContentRange),
                ]
            )
            #expect(!String(describing: attempts).contains("secret-page"))
        }
    }

    @Test
    func cancellationStopsTheActiveRequestWithoutTryingBackup() async throws {
        let first = try #require(URL(string: "https://first.example/media"))
        let second = try #require(URL(string: "https://second.example/media"))
        let transport = CancellationObservingTransport()
        let client = HTTPRangeClient(transport: transport)
        let range = try HTTPByteRange(start: 0, endInclusive: 2)

        let task = Task {
            try await client.fetch(from: [first, second], range: range)
        }
        while !(await transport.hasStarted) {
            await Task.yield()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await transport.wasCancelled)
        #expect(await transport.requests.count == 1)
    }

    @Test
    func rejectsUnsafeCandidatesBeforeTransportAndUsesSafeBackup() async throws {
        let local = try #require(URL(string: "https://127.0.0.1/media"))
        let integerLocal = try #require(URL(string: "https://2130706433/media"))
        let octalLocal = try #require(URL(string: "https://0177.0.0.1/media"))
        let hexadecimalLocal = try #require(URL(string: "https://0x7f000001/media"))
        let plaintext = try #require(URL(string: "http://cdn.example/media"))
        let safe = try #require(URL(string: "https://cdn.example/media"))
        let transport = RangeStubTransport(
            responses: [
                HTTPResponse(
                    statusCode: 206,
                    headers: ["Content-Range": "bytes 0-2/100"],
                    body: Data([0, 1, 2])
                ),
            ]
        )
        let client = HTTPRangeClient(transport: transport)

        let result = try await client.fetch(
            from: [
                local,
                integerLocal,
                octalLocal,
                hexadecimalLocal,
                plaintext,
                safe,
            ],
            range: try HTTPByteRange(start: 0, endInclusive: 2)
        )

        #expect(result.sourceURL == safe)
        #expect(await transport.requests.map(\.url) == [safe])
    }
}

private actor RangeStubTransport: HTTPTransport {
    private var queuedResponses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []

    init(responses: [HTTPResponse]) {
        queuedResponses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !queuedResponses.isEmpty else {
            throw RangeStubError.noResponse
        }
        return queuedResponses.removeFirst()
    }
}

private actor CancellationObservingTransport: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    private(set) var hasStarted = false
    private(set) var wasCancelled = false

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        hasStarted = true

        do {
            try await Task.sleep(for: .seconds(60))
            return HTTPResponse(statusCode: 500, body: Data())
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }
}

private enum RangeStubError: Error {
    case noResponse
}
