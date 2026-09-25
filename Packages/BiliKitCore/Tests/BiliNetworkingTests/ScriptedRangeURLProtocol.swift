import Foundation

/// BiliNetworkingTests 唯一的 URLProtocol 替身：按脚本返回状态、响应头与分块正文，并记录请求、
/// 启动与停止。
///
/// 每个 suite 使用自己的子类取得独立 state，避免并行 suite 互相覆盖脚本。
class ScriptedRangeURLProtocol: URLProtocol, @unchecked Sendable {
    class var state: ScriptedRangeURLProtocolState {
        preconditionFailure("子类必须提供独立 state")
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let state = Self.state
        let script = state.begin(request: request)
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: script.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: script.headers
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let deliver: @Sendable () -> Void = { [weak self] in
            guard let self, !state.wasStopped else { return }
            for chunk in script.chunks {
                guard !state.wasStopped else { return }
                state.markDelivered(chunk.count)
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        if script.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + script.delay) {
                deliver()
            }
        } else {
            deliver()
        }
    }

    override func stopLoading() { Self.state.markStopped() }
}

struct RangeURLProtocolScript: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let chunks: [Data]
    /// 响应头之后延迟交付正文，用于证明 client 不等待正文即可拒绝。
    let delay: TimeInterval
}

final class ScriptedRangeURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var script = RangeURLProtocolScript(
        statusCode: 500,
        headers: [:],
        chunks: [],
        delay: 0
    )
    private var stopped = false
    private var delivered = 0
    private var capturedRequest: URLRequest?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

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
            script = RangeURLProtocolScript(
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

    func begin(request: URLRequest) -> RangeURLProtocolScript {
        let (script, waiters) = lock.withLock {
            capturedRequest = request
            defer { startWaiters.removeAll() }
            return (script, startWaiters)
        }
        for waiter in waiters { waiter.resume() }
        return script
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

    func markStopped() {
        let waiters = lock.withLock {
            stopped = true
            defer { stopWaiters.removeAll() }
            return stopWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            let isStopped = lock.withLock {
                guard !stopped else { return true }
                stopWaiters.append(continuation)
                return false
            }
            if isStopped { continuation.resume() }
        }
    }

    func markDelivered(_ count: Int) { lock.withLock { delivered += count } }
}
