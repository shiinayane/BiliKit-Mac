import Foundation

public struct HTTPRangeStreamResponse: Sendable, Equatable {
    public let contentRange: HTTPContentRange
    public let contentLength: UInt64
    public let contentType: String

    public init(
        contentRange: HTTPContentRange,
        contentLength: UInt64,
        contentType: String
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

public enum HTTPRangeStreamingError: Error, Sendable, Equatable {
    case disallowedURL
    case invalidRangeHeader
    case statusCode(Int)
    case missingContentRange
    case invalidContentRange
    case mismatchedContentRange(expected: HTTPByteRange, actual: HTTPContentRange)
    case missingCompleteLength
    case mismatchedCompleteLength(expected: Int64, actual: Int64)
    case missingContentLength
    case invalidContentLength
    case mismatchedContentLength(expected: UInt64, actual: UInt64)
    case missingContentType
    case unsupportedContentType(String)
    case bodyLengthMismatch(expected: UInt64, actual: UInt64)
    case transport(errorType: String)
}

public protocol HTTPRangeStreaming: Sendable {
    func stream(
        from url: URL,
        rangeHeader: String,
        expectedRange: HTTPByteRange,
        expectedCompleteLength: Int64,
        headers: [String: String],
        allowedContentTypes: Set<String>,
        onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> HTTPRangeStreamResult

    func invalidate()
}

extension HTTPRangeStreaming {
    public func invalidate() {}
}

/// 单来源 progressive 媒体 Range 流。
///
/// 响应头在正文放行前完成验证，正文按 URLSession
/// chunk 交给下游；下游完成一个 chunk 后才恢复上游 task，避免把完整媒体积压在内存。
public final class HTTPRangeStreamingClient: HTTPRangeStreaming, @unchecked Sendable {
    private let transport: URLSessionRangeStreamingTransport
    private let urlPolicy: PublicHTTPSURLPolicy

    public init(
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 7 * 24 * 60 * 60,
        urlPolicy: PublicHTTPSURLPolicy = PublicHTTPSURLPolicy()
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        // 保留 URLSession 的七天默认资源期限；不以分钟级绝对时限截断开放末尾 Range。
        configuration.timeoutIntervalForResource = resourceTimeout
        transport = URLSessionRangeStreamingTransport(configuration: configuration)
        self.urlPolicy = urlPolicy
    }

    init(
        transport: URLSessionRangeStreamingTransport,
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
        allowedContentTypes: Set<String>,
        onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> HTTPRangeStreamResult {
        guard urlPolicy.allows(url) else {
            throw HTTPRangeStreamingError.disallowedURL
        }
        guard expectedCompleteLength > 0,
            rangeHeader.lowercased().hasPrefix("bytes="),
            !rangeHeader.contains(",")
        else {
            throw HTTPRangeStreamingError.invalidRangeHeader
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers
        where name.caseInsensitiveCompare("Cookie") != .orderedSame
            && name.caseInsensitiveCompare("Authorization") != .orderedSame
            && name.caseInsensitiveCompare("Range") != .orderedSame
        {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        return try await transport.stream(
            request,
            expectedRange: expectedRange,
            expectedCompleteLength: expectedCompleteLength,
            allowedContentTypes: Set(allowedContentTypes.map { $0.lowercased() }),
            onResponse: onResponse,
            onChunk: onChunk
        )
    }

    public func invalidate() {
        transport.invalidate()
    }
}

final class URLSessionRangeStreamingTransport: NSObject, URLSessionDataDelegate,
    @unchecked Sendable
{
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var operations: [Int: RangeStreamingOperation] = [:]
    private lazy var session: URLSession = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
        super.init()
    }

    func stream(
        _ request: URLRequest,
        expectedRange: HTTPByteRange,
        expectedCompleteLength: Int64,
        allowedContentTypes: Set<String>,
        onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> HTTPRangeStreamResult {
        let operation = RangeStreamingOperation(
            expectedRange: expectedRange,
            expectedCompleteLength: expectedCompleteLength,
            allowedContentTypes: allowedContentTypes,
            onResponse: onResponse,
            onChunk: onChunk
        )
        let task = session.dataTask(with: request)
        lock.withLock { operations[task.taskIdentifier] = operation }
        return try await withTaskCancellationHandler {
            try await operation.start(task) { [weak self] in
                self?.lock.withLock { self?.operations[task.taskIdentifier] = nil }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    func invalidate() {
        let pending = lock.withLock {
            let pending = Array(operations.values)
            operations.removeAll()
            return pending
        }
        for operation in pending { operation.cancel() }
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let operation = operation(for: dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        operation.receive(response, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        operation(for: dataTask.taskIdentifier)?.receive(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        operation(for: task.taskIdentifier)?.complete(error: error)
    }

    private func operation(for taskIdentifier: Int) -> RangeStreamingOperation? {
        lock.withLock { operations[taskIdentifier] }
    }
}

private final class RangeStreamingOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedRange: HTTPByteRange
    private let expectedCompleteLength: Int64
    private let allowedContentTypes: Set<String>
    private let onResponse: @Sendable (HTTPRangeStreamResponse) async throws -> Void
    private let onChunk: @Sendable (Data) async throws -> Void
    private var continuation: CheckedContinuation<HTTPRangeStreamResult, any Error>?
    private var task: URLSessionDataTask?
    private var onFinish: (@Sendable () -> Void)?
    private var received: UInt64 = 0
    private var responseAccepted = false
    private var callbackInFlight = false
    private var pendingChunk: Data?
    private var upstreamCompleted = false
    private var finished = false

    init(
        expectedRange: HTTPByteRange,
        expectedCompleteLength: Int64,
        allowedContentTypes: Set<String>,
        onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) {
        self.expectedRange = expectedRange
        self.expectedCompleteLength = expectedCompleteLength
        self.allowedContentTypes = allowedContentTypes
        self.onResponse = onResponse
        self.onChunk = onChunk
    }

    func start(
        _ task: URLSessionDataTask,
        onFinish: @escaping @Sendable () -> Void
    ) async throws -> HTTPRangeStreamResult {
        try await withCheckedThrowingContinuation { continuation in
            let shouldStart = lock.withLock {
                guard !finished else { return false }
                self.continuation = continuation
                self.task = task
                self.onFinish = onFinish
                return true
            }
            if shouldStart {
                task.resume()
            } else {
                task.cancel()
                continuation.resume(throwing: CancellationError())
                onFinish()
            }
        }
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
            let validated = try validate(response)
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
            case fail(HTTPRangeStreamingError)
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
                    HTTPRangeStreamingError.transport(
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
                    nil as CheckedContinuation<HTTPRangeStreamResult, any Error>?,
                    nil as Result<HTTPRangeStreamResult, any Error>?,
                    nil as URLSessionDataTask?,
                    nil as (@Sendable () -> Void)?
                )
            }
            let finalResult: Result<HTTPRangeStreamResult, any Error>
            switch result {
            case .success where received != expectedRange.length:
                finalResult = .failure(
                    HTTPRangeStreamingError.bodyLengthMismatch(
                        expected: expectedRange.length,
                        actual: received
                    )
                )
            default:
                finalResult = result
            }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            let task = self.task
            self.task = nil
            let onFinish = self.onFinish
            self.onFinish = nil
            return (continuation, finalResult, task, onFinish)
        }
        resources.2?.cancel()
        resources.3?()
        if let continuation = resources.0, let result = resources.1 {
            continuation.resume(with: result)
        }
    }

    private func validate(_ response: URLResponse) throws -> HTTPRangeStreamResponse {
        guard let response = response as? HTTPURLResponse else {
            throw HTTPRangeStreamingError.transport(
                errorType: String(reflecting: HTTPClientError.nonHTTPResponse)
            )
        }
        guard response.statusCode == 206 else {
            throw HTTPRangeStreamingError.statusCode(response.statusCode)
        }
        guard let rawRange = response.value(forHTTPHeaderField: "Content-Range") else {
            throw HTTPRangeStreamingError.missingContentRange
        }
        let contentRange: HTTPContentRange
        do {
            contentRange = try HTTPContentRange.parse(rawRange)
        } catch {
            throw HTTPRangeStreamingError.invalidContentRange
        }
        guard contentRange.start == expectedRange.start,
            contentRange.endInclusive == expectedRange.endInclusive
        else {
            throw HTTPRangeStreamingError.mismatchedContentRange(
                expected: expectedRange,
                actual: contentRange
            )
        }
        guard let completeLength = contentRange.completeLength else {
            throw HTTPRangeStreamingError.missingCompleteLength
        }
        guard completeLength == expectedCompleteLength else {
            throw HTTPRangeStreamingError.mismatchedCompleteLength(
                expected: expectedCompleteLength,
                actual: completeLength
            )
        }
        guard let rawLength = response.value(forHTTPHeaderField: "Content-Length") else {
            throw HTTPRangeStreamingError.missingContentLength
        }
        guard let contentLength = UInt64(rawLength) else {
            throw HTTPRangeStreamingError.invalidContentLength
        }
        guard contentLength == expectedRange.length else {
            throw HTTPRangeStreamingError.mismatchedContentLength(
                expected: expectedRange.length,
                actual: contentLength
            )
        }
        guard let rawType = response.value(forHTTPHeaderField: "Content-Type") else {
            throw HTTPRangeStreamingError.missingContentType
        }
        let contentType = rawType.split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard allowedContentTypes.contains(contentType) else {
            throw HTTPRangeStreamingError.unsupportedContentType(contentType)
        }
        return HTTPRangeStreamResponse(
            contentRange: contentRange,
            contentLength: contentLength,
            contentType: contentType
        )
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
