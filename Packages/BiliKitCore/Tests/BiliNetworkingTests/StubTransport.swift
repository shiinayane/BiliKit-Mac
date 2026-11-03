import Foundation

@testable import BiliNetworking

/// BiliNetworkingTests 共用的 HTTPTransport 替身：按顺序回放响应，队列耗尽后立即失败。
actor StubTransport: HTTPTransport {
    private var responses: [HTTPResponse]

    init(responses: [HTTPResponse] = []) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard !responses.isEmpty else { throw StubTransportError.noResponse }
        return responses.removeFirst()
    }
}

enum StubTransportError: Error {
    case noResponse
}
