import Foundation
import Testing

@testable import BiliNetworking

struct HTTPClientTests {
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
