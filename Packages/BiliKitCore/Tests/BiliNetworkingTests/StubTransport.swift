import Foundation

@testable import BiliNetworking

/// BiliNetworkingTests 共用的 HTTPTransport 替身：按顺序回放响应并记录请求；
/// 队列耗尽后要么立即失败，要么挂起到调用方取消（60 秒只作超时）。
actor StubTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private let hangsWhenExhausted: Bool
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [HTTPRequest] = []
    private(set) var wasCancelled = false

    init(responses: [HTTPResponse] = [], hangsWhenExhausted: Bool = false) {
        self.responses = responses
        self.hangsWhenExhausted = hangsWhenExhausted
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        for waiter in requestWaiters { waiter.resume() }
        requestWaiters.removeAll()
        if !responses.isEmpty {
            return responses.removeFirst()
        }
        guard hangsWhenExhausted else { throw StubTransportError.noResponse }
        do {
            try await Task.sleep(for: .seconds(60))
            throw StubTransportError.noResponse
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }

    func waitForFirstRequest() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }
}

enum StubTransportError: Error {
    case noResponse
}
