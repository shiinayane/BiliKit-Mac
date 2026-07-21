import Foundation
import Testing
@testable import BiliNetworking

struct HTTPClientTests {
    @Test
    func returnsAcceptedResponse() async throws {
        let expected = HTTPResponse(statusCode: 206, body: Data("partial".utf8))
        let client = HTTPClient(transport: StubTransport(response: expected))
        let request = HTTPRequest(url: try #require(URL(string: "https://example.com")))

        let response = try await client.send(request)

        #expect(response == expected)
    }

    @Test
    func rejectsUnexpectedStatusCode() async throws {
        let client = HTTPClient(
            transport: StubTransport(
                response: HTTPResponse(statusCode: 403, body: Data())
            )
        )
        let request = HTTPRequest(url: try #require(URL(string: "https://example.com")))

        await #expect(throws: HTTPClientError.unacceptableStatusCode(403)) {
            try await client.send(request)
        }
    }

    @Test
    func redactsSensitiveRequestData() throws {
        let redactor = HTTPLogRedactor()
        let url = try #require(
            URL(string: "https://example.com/play?bvid=BV1xx&access_key=secret&w_rid=signed")
        )

        let redactedURL = redactor.redact(url: url)
        let redactedHeaders = redactor.redact(
            headers: ["Cookie": "SESSDATA=secret", "Accept": "application/json"]
        )

        #expect(redactedURL.contains("bvid=BV1xx"))
        #expect(!redactedURL.contains("secret"))
        #expect(!redactedURL.contains("signed"))
        #expect(redactedHeaders["Cookie"] == "<redacted>")
        #expect(redactedHeaders["Accept"] == "application/json")
    }
}

private struct StubTransport: HTTPTransport {
    let response: HTTPResponse

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        response
    }
}

