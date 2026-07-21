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
            URL(string: "https://example.com/play?bvid=BV1xx&access_key=secret&w_rid=signed&qrcode_key=qr-secret")
        )

        let redactedURL = redactor.redact(url: url)
        let redactedHeaders = redactor.redact(
            headers: ["Cookie": "SESSDATA=secret", "Accept": "application/json"]
        )

        #expect(redactedURL.contains("bvid=BV1xx"))
        #expect(!redactedURL.contains("secret"))
        #expect(!redactedURL.contains("signed"))
        #expect(!redactedURL.contains("qr-secret"))
        #expect(redactedHeaders["Cookie"] == "<redacted>")
        #expect(redactedHeaders["Accept"] == "application/json")
    }

    @Test
    func rejectRedirectDelegateStopsCrossHostRedirect() async throws {
        let delegate = RejectHTTPRedirectDelegate()
        let original = try #require(URL(string: "https://api.example.com/private"))
        let redirected = try #require(URL(string: "https://cdn.example.com/private"))
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: original)
        let response = try #require(
            HTTPURLResponse(
                url: original,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirected.absoluteString]
            )
        )

        await confirmation { completed in
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: redirected)
            ) { request in
                #expect(request == nil)
                completed()
            }
        }
        session.invalidateAndCancel()
    }
}

private struct StubTransport: HTTPTransport {
    let response: HTTPResponse

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        response
    }
}
