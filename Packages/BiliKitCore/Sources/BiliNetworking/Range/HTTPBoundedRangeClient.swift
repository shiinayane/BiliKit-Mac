import Foundation

public struct HTTPBoundedRangeResult: Sendable, Equatable {
    public let contentRange: HTTPContentRange
    public let body: Data?
    public let byteCount: UInt64
    public let requestDurationSeconds: Double

    public init(
        contentRange: HTTPContentRange,
        body: Data?,
        byteCount: UInt64,
        requestDurationSeconds: Double
    ) {
        self.contentRange = contentRange
        self.body = body
        self.byteCount = byteCount
        self.requestDurationSeconds = requestDurationSeconds
    }
}

public enum HTTPBoundedRangeError: Error, Sendable, Equatable {
    case disallowedURL
    case statusCode(Int)
    case missingContentRange
    case invalidContentRange
    case mismatchedContentRange(expected: HTTPByteRange, actual: HTTPContentRange)
    case missingContentLength
    case invalidContentLength
    case mismatchedContentLength(expected: UInt64, actual: UInt64)
    case bodyLengthMismatch(expected: UInt64, actual: UInt64)
    case transport(errorType: String)
}

public protocol HTTPBoundedRangeFetching: Sendable {
    func fetch(
        from url: URL,
        range: HTTPByteRange,
        headers: [String: String],
        collectBody: Bool
    ) async throws -> HTTPBoundedRangeResult

    func invalidate()
}

extension HTTPBoundedRangeFetching {
    public func invalidate() {}
}

protocol HTTPBoundedRangeTransport: Sendable {
    func fetch(
        _ request: URLRequest,
        expectedRange: HTTPByteRange,
        collectBody: Bool
    ) async throws -> HTTPBoundedRangeResult

    func invalidate()
}

extension HTTPBoundedRangeTransport {
    func invalidate() {}
}

/// 单来源、流式且有界的 Range client，供显式媒体测速使用。
///
/// transport 在允许正文前即验证 `206`、`Content-Range` 与 `Content-Length`。因此 `200`、
/// 缺少长度或声明越界的响应会立即取消；正文只计数或按需保留，达到精确上限即停止。
public struct HTTPBoundedRangeClient: HTTPBoundedRangeFetching, Sendable {
    private let transport: any HTTPBoundedRangeTransport
    private let urlPolicy: PublicHTTPSURLPolicy

    public init(
        requestTimeout: TimeInterval = 15,
        resourceTimeout: TimeInterval = 30,
        urlPolicy: PublicHTTPSURLPolicy = PublicHTTPSURLPolicy()
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        transport = URLSessionBoundedRangeTransport(configuration: configuration)
        self.urlPolicy = urlPolicy
    }

    init(
        transport: any HTTPBoundedRangeTransport,
        urlPolicy: PublicHTTPSURLPolicy = PublicHTTPSURLPolicy()
    ) {
        self.transport = transport
        self.urlPolicy = urlPolicy
    }

    public func fetch(
        from url: URL,
        range: HTTPByteRange,
        headers: [String: String] = [:],
        collectBody: Bool = false
    ) async throws -> HTTPBoundedRangeResult {
        guard urlPolicy.allows(url) else {
            throw HTTPBoundedRangeError.disallowedURL
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
        request.setValue(range.headerValue, forHTTPHeaderField: "Range")
        return try await transport.fetch(
            request,
            expectedRange: range,
            collectBody: collectBody
        )
    }

    public func invalidate() {
        transport.invalidate()
    }
}

final class URLSessionBoundedRangeTransport: NSObject, HTTPBoundedRangeTransport,
    URLSessionDataDelegate, @unchecked Sendable
{
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var operations: [Int: BoundedRangeOperation] = [:]
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

    func fetch(
        _ request: URLRequest,
        expectedRange: HTTPByteRange,
        collectBody: Bool
    ) async throws -> HTTPBoundedRangeResult {
        let operation = BoundedRangeOperation(
            expectedRange: expectedRange,
            collectBody: collectBody
        )
        let task = session.dataTask(with: request)
        lock.withLock { operations[task.taskIdentifier] = operation }
        return try await withTaskCancellationHandler {
            try await operation.start(task) { [weak self] in
                self?.removeOperation(for: task.taskIdentifier)
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
        for operation in pending {
            operation.cancel()
        }
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

    private func operation(for taskIdentifier: Int) -> BoundedRangeOperation? {
        lock.withLock { operations[taskIdentifier] }
    }

    private func removeOperation(for taskIdentifier: Int) {
        lock.withLock { operations[taskIdentifier] = nil }
    }
}

private final class BoundedRangeOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedRange: HTTPByteRange
    private let collectBody: Bool
    private let clock = ContinuousClock()
    private var continuation: CheckedContinuation<HTTPBoundedRangeResult, any Error>?
    private var task: URLSessionDataTask?
    private var onFinish: (@Sendable () -> Void)?
    private var startedAt: ContinuousClock.Instant?
    private var contentRange: HTTPContentRange?
    private var received: UInt64 = 0
    private var retained: Data?
    private var pendingResult: HTTPBoundedRangeResult?
    private var finished = false

    init(
        expectedRange: HTTPByteRange,
        collectBody: Bool
    ) {
        self.expectedRange = expectedRange
        self.collectBody = collectBody
        retained = collectBody ? Data() : nil
    }

    func start(
        _ task: URLSessionDataTask,
        onFinish: @escaping @Sendable () -> Void
    ) async throws -> HTTPBoundedRangeResult {
        try await withCheckedThrowingContinuation { continuation in
            let shouldStart = lock.withLock {
                guard !finished else { return false }
                self.continuation = continuation
                self.task = task
                self.onFinish = onFinish
                startedAt = clock.now
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
        do {
            guard let response = response as? HTTPURLResponse else {
                throw HTTPBoundedRangeError.transport(
                    errorType: String(reflecting: HTTPClientError.nonHTTPResponse)
                )
            }
            let validated = try validate(response, expectedRange: expectedRange)
            lock.withLock {
                contentRange = validated
            }
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func receive(_ data: Data) {
        var outcome: Result<HTTPBoundedRangeResult, any Error>?
        lock.withLock {
            guard !finished else { return }
            let next = received + UInt64(data.count)
            guard next <= expectedRange.length, pendingResult == nil else {
                outcome = .failure(
                    HTTPBoundedRangeError.bodyLengthMismatch(
                        expected: expectedRange.length,
                        actual: next
                    )
                )
                return
            }
            retained?.append(data)
            received = next
            guard received == expectedRange.length,
                let contentRange,
                let startedAt
            else { return }
            let completedAt = clock.now
            pendingResult =
                HTTPBoundedRangeResult(
                    contentRange: contentRange,
                    body: retained,
                    byteCount: received,
                    requestDurationSeconds: max(
                        durationSeconds(startedAt.duration(to: completedAt)),
                        .leastNonzeroMagnitude
                    )
                )
        }
        if let outcome { finish(outcome) }
    }

    func complete(error: (any Error)?) {
        if let error {
            finish(
                .failure(
                    HTTPBoundedRangeError.transport(
                        errorType: String(reflecting: type(of: error))
                    )
                )
            )
        } else {
            let completion = lock.withLock {
                if let pendingResult {
                    return Result<HTTPBoundedRangeResult, any Error>.success(pendingResult)
                }
                return .failure(
                    HTTPBoundedRangeError.bodyLengthMismatch(
                        expected: expectedRange.length,
                        actual: received
                    )
                )
            }
            finish(completion)
        }
    }

    private func finish(_ result: Result<HTTPBoundedRangeResult, any Error>) {
        let resources = lock.withLock {
            guard !finished else {
                return (
                    nil as CheckedContinuation<HTTPBoundedRangeResult, any Error>?,
                    nil as URLSessionDataTask?,
                    nil as (@Sendable () -> Void)?
                )
            }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            let task = self.task
            self.task = nil
            let onFinish = self.onFinish
            self.onFinish = nil
            return (continuation, task, onFinish)
        }
        resources.1?.cancel()
        resources.2?()
        resources.0?.resume(with: result)
    }

    private func validate(
        _ response: HTTPURLResponse,
        expectedRange: HTTPByteRange
    ) throws -> HTTPContentRange {
        guard response.statusCode == 206 else {
            throw HTTPBoundedRangeError.statusCode(response.statusCode)
        }
        guard let raw = response.value(forHTTPHeaderField: "Content-Range") else {
            throw HTTPBoundedRangeError.missingContentRange
        }
        let parsed: HTTPContentRange
        do {
            parsed = try HTTPContentRange.parse(raw)
        } catch {
            throw HTTPBoundedRangeError.invalidContentRange
        }
        guard parsed.start == expectedRange.start,
            parsed.endInclusive == expectedRange.endInclusive
        else {
            throw HTTPBoundedRangeError.mismatchedContentRange(
                expected: expectedRange,
                actual: parsed
            )
        }
        guard let rawLength = response.value(forHTTPHeaderField: "Content-Length") else {
            throw HTTPBoundedRangeError.missingContentLength
        }
        guard let length = UInt64(rawLength) else {
            throw HTTPBoundedRangeError.invalidContentLength
        }
        guard length == expectedRange.length else {
            throw HTTPBoundedRangeError.mismatchedContentLength(
                expected: expectedRange.length,
                actual: length
            )
        }
        return parsed
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
