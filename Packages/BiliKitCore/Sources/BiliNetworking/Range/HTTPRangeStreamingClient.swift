import Foundation

public struct HTTPRangeStreamResponse: Sendable, Equatable {
    public let contentRange: HTTPContentRange
    public let contentLength: UInt64
    public let contentType: String?

    public init(
        contentRange: HTTPContentRange,
        contentLength: UInt64,
        contentType: String?
    ) {
        self.contentRange = contentRange
        self.contentLength = contentLength
        self.contentType = contentType
    }
}

public struct HTTPRangeStreamResult: Sendable, Equatable {
    public let byteCount: UInt64

    public init(byteCount: UInt64) {
        self.byteCount = byteCount
    }
}

public protocol HTTPRangeStreaming: Sendable {
    /// `allowedContentTypes` 为 nil 时不限制上游 `Content-Type`；`requiresContentLength` 为 false
    /// 时允许上游省略 `Content-Length`（正文长度仍按实际字节精确核对）。其余响应头逐项验证。
    func stream(
        from url: URL,
        rangeHeader: String,
        expectedRange: HTTPByteRange,
        expectedCompleteLength: Int64,
        headers: [String: String],
        allowedContentTypes: Set<String>?,
        requiresContentLength: Bool,
        onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> HTTPRangeStreamResult

    func invalidate()
}

extension HTTPRangeStreaming {
    public func invalidate() {}
}

/// 单来源媒体 Range 流。
///
/// 响应头在正文放行前完成验证，正文按 URLSession
/// chunk 交给下游；下游完成一个 chunk 后才恢复上游 task，避免把完整媒体积压在内存。
public final class HTTPRangeStreamingClient: HTTPRangeStreaming, @unchecked Sendable {
    private let transport: URLSessionRangeTransport
    private let urlPolicy: PublicHTTPSURLPolicy

    public init(
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 7 * 24 * 60 * 60,
        urlPolicy: PublicHTTPSURLPolicy = PublicHTTPSURLPolicy()
    ) {
        let configuration = URLSessionConfiguration.credentialFreeEphemeral()
        configuration.timeoutIntervalForRequest = requestTimeout
        // 保留 URLSession 的七天默认资源期限；不以分钟级绝对时限截断开放末尾 Range。
        configuration.timeoutIntervalForResource = resourceTimeout
        transport = URLSessionRangeTransport(configuration: configuration)
        self.urlPolicy = urlPolicy
    }

    init(
        transport: URLSessionRangeTransport,
        urlPolicy: PublicHTTPSURLPolicy = PublicHTTPSURLPolicy()
    ) {
        self.transport = transport
        self.urlPolicy = urlPolicy
    }

    public func stream(
        from url: URL,
        rangeHeader: String,
        expectedRange: HTTPByteRange,
        expectedCompleteLength: Int64,
        headers: [String: String] = [:],
        allowedContentTypes: Set<String>?,
        requiresContentLength: Bool = true,
        onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> HTTPRangeStreamResult {
        guard urlPolicy.allows(url) else {
            throw HTTPRangeResponseError.disallowedURL
        }
        guard expectedCompleteLength > 0,
            rangeHeader.lowercased().hasPrefix("bytes="),
            !rangeHeader.contains(",")
        else {
            throw HTTPRangeResponseError.invalidRangeHeader
        }
        return try await transport.run(
            .rangeGET(url, rangeHeader: rangeHeader, headers: headers),
            operation: RangeStreamingOperation(
                validator: HTTPRangeResponseValidator(
                    expectedRange: expectedRange,
                    expectedCompleteLength: expectedCompleteLength,
                    requiresContentLength: requiresContentLength,
                    allowedContentTypes: allowedContentTypes.map {
                        Set($0.map { $0.lowercased() })
                    }
                ),
                onResponse: onResponse,
                onChunk: onChunk
            )
        )
    }

    public func invalidate() {
        transport.invalidate()
    }
}

private final class RangeStreamingOperation: URLSessionRangeOperation, @unchecked Sendable {
    private let lock = NSLock()
    private let validator: HTTPRangeResponseValidator
    private let expectedRange: HTTPByteRange
    private let onResponse: @Sendable (HTTPRangeStreamResponse) async throws -> Void
    private let onChunk: @Sendable (Data) async throws -> Void
    private let outcome = OneShotResult<HTTPRangeStreamResult>()
    private var task: URLSessionDataTask?
    private var onFinish: (@Sendable () -> Void)?
    private var received: UInt64 = 0
    private var responseAccepted = false
    private var callbackInFlight = false
    private var pendingChunk: Data?
    private var upstreamCompleted = false
    private var finished = false

    init(
        validator: HTTPRangeResponseValidator,
        onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) {
        self.validator = validator
        expectedRange = validator.expectedRange
        self.onResponse = onResponse
        self.onChunk = onChunk
    }

    func start(
        _ task: URLSessionDataTask,
        onFinish: @escaping @Sendable () -> Void
    ) async throws -> HTTPRangeStreamResult {
        let shouldStart = lock.withLock {
            guard !finished else { return false }
            self.task = task
            self.onFinish = onFinish
            return true
        }
        if shouldStart {
            task.resume()
        } else {
            task.cancel()
            onFinish()
        }
        return try await outcome.value()
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func receive(
        _ response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let disposition = ResponseDispositionHandler(completionHandler)
        do {
            let validated = try validator.validate(response)
            guard beginCallback() else {
                disposition.call(.cancel)
                return
            }
            Task {
                do {
                    try await onResponse(validated)
                    let shouldAllow = lock.withLock {
                        callbackInFlight = false
                        responseAccepted = !finished
                        return !finished
                    }
                    disposition.call(shouldAllow ? .allow : .cancel)
                } catch {
                    disposition.call(.cancel)
                    finish(.failure(error))
                }
            }
        } catch {
            disposition.call(.cancel)
            finish(.failure(error))
        }
    }

    func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        enum Action {
            case process(URLSessionDataTask)
            case queued
            case fail(HTTPRangeResponseError)
            case ignore
        }
        let action = lock.withLock { () -> Action in
            guard !finished, responseAccepted else { return .ignore }
            let next = received + UInt64(data.count)
            guard next <= expectedRange.length else {
                return .fail(
                    .bodyLengthMismatch(
                        expected: expectedRange.length,
                        actual: next
                    )
                )
            }
            received = next
            if callbackInFlight {
                guard pendingChunk == nil else {
                    return .fail(
                        .transport(errorType: "BufferedRangeChunkOverflow")
                    )
                }
                pendingChunk = data
                return .queued
            }
            guard let task else { return .ignore }
            callbackInFlight = true
            task.suspend()
            return .process(task)
        }
        switch action {
        case .process(let task):
            Task { await processChunks(startingWith: data, task: task) }
        case .queued, .ignore:
            break
        case .fail(let error):
            finish(.failure(error))
        }
    }

    private func processChunks(startingWith firstChunk: Data, task: URLSessionDataTask) async {
        var chunk = firstChunk
        do {
            while true {
                try await onChunk(chunk)
                let state = lock.withLock {
                    () -> (next: Data?, completion: HTTPRangeStreamResult?, resume: Bool) in
                    guard !finished else { return (nil, nil, false) }
                    if let pendingChunk {
                        self.pendingChunk = nil
                        return (pendingChunk, nil, false)
                    }
                    callbackInFlight = false
                    if upstreamCompleted {
                        return (nil, makeCompletionResult(), false)
                    }
                    return (nil, nil, true)
                }
                if let next = state.next {
                    chunk = next
                    continue
                }
                if let completion = state.completion {
                    finish(.success(completion))
                } else if state.resume {
                    task.resume()
                }
                return
            }
        } catch {
            finish(.failure(error))
        }
    }

    func complete(error: (any Error)?) {
        if let error {
            finish(
                .failure(
                    HTTPRangeResponseError.transport(
                        errorType: String(reflecting: type(of: error))
                    )
                )
            )
            return
        }
        let completion = lock.withLock { () -> HTTPRangeStreamResult? in
            guard !finished else { return nil }
            upstreamCompleted = true
            guard !callbackInFlight else { return nil }
            return makeCompletionResult()
        }
        if let completion {
            finish(.success(completion))
        }
    }

    private func beginCallback() -> Bool {
        lock.withLock {
            guard !finished, !callbackInFlight else { return false }
            callbackInFlight = true
            return true
        }
    }

    private func makeCompletionResult() -> HTTPRangeStreamResult {
        HTTPRangeStreamResult(byteCount: received)
    }

    private func finish(_ result: Result<HTTPRangeStreamResult, any Error>) {
        let resources = lock.withLock {
            guard !finished else {
                return (
                    nil as Result<HTTPRangeStreamResult, any Error>?,
                    nil as URLSessionDataTask?,
                    nil as (@Sendable () -> Void)?
                )
            }
            let finalResult: Result<HTTPRangeStreamResult, any Error>
            switch result {
            case .success where received != expectedRange.length:
                finalResult = .failure(
                    HTTPRangeResponseError.bodyLengthMismatch(
                        expected: expectedRange.length,
                        actual: received
                    )
                )
            default:
                finalResult = result
            }
            finished = true
            let task = self.task
            self.task = nil
            let onFinish = self.onFinish
            self.onFinish = nil
            return (finalResult, task, onFinish)
        }
        guard let finalResult = resources.0 else { return }
        resources.1?.cancel()
        resources.2?()
        outcome.resolve(finalResult)
    }
}

private final class ResponseDispositionHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLSession.ResponseDisposition) -> Void)?

    init(_ handler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.handler = handler
    }

    func call(_ disposition: URLSession.ResponseDisposition) {
        let handler = lock.withLock {
            let handler = self.handler
            self.handler = nil
            return handler
        }
        handler?(disposition)
    }
}
