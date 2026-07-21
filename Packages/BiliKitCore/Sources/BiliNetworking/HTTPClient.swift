import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

public struct HTTPRequest: Sendable, Equatable {
    public let url: URL
    public let method: HTTPMethod
    public let headers: [String: String]
    public let body: Data?

    public init(
        url: URL,
        method: HTTPMethod = .get,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public enum HTTPClientError: Error, Sendable, Equatable {
    case nonHTTPResponse
    case unacceptableStatusCode(Int)
}

public actor HTTPClient {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func send(
        _ request: HTTPRequest,
        accepting acceptedStatusCodes: Range<Int> = 200..<300
    ) async throws -> HTTPResponse {
        let response = try await transport.send(request)
        guard acceptedStatusCodes.contains(response.statusCode) else {
            throw HTTPClientError.unacceptableStatusCode(response.statusCode)
        }
        return response
    }
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.nonHTTPResponse
        }

        let headers = httpResponse.allHeaderFields.reduce(
            into: [String: String](),
            { result, entry in
                result[String(describing: entry.key)] = String(describing: entry.value)
            }
        )

        return HTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: data
        )
    }
}

