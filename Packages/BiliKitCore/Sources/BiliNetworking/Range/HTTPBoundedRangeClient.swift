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

/// 单来源、流式且有界的 Range client，供显式媒体测速使用。
///
/// transport 在允许正文前即验证 `206`、`Content-Range` 与 `Content-Length`。因此 `200`、
/// 缺少长度或声明越界的响应会立即取消；正文只计数或按需保留，达到精确上限即停止。
public struct HTTPBoundedRangeClient: HTTPBoundedRangeFetching, Sendable {
    private let transport: URLSessionRangeTransport
    private let urlPolicy: PublicHTTPSURLPolicy

    public init(
        requestTimeout: TimeInterval = 15,
        resourceTimeout: TimeInterval = 30,
        urlPolicy: PublicHTTPSURLPolicy = PublicHTTPSURLPolicy()
    ) {
        let configuration = URLSessionConfiguration.credentialFreeEphemeral()
        configuration.timeoutIntervalForRequest = requestTimeout
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

    public func fetch(
        from url: URL,
        range: HTTPByteRange,
        headers: [String: String] = [:],
        collectBody: Bool = false
    ) async throws -> HTTPBoundedRangeResult {
        guard urlPolicy.allows(url) else {
            throw HTTPRangeResponseError.disallowedURL
        }
        return try await transport.run(
            .rangeGET(url, rangeHeader: range.headerValue, headers: headers),
            operation: BoundedRangeOperation(
                validator: HTTPRangeResponseValidator(
                    expectedRange: range,
                    requiresContentLength: true
                ),
                collectBody: collectBody
            )
        )
    }

    public func invalidate() {
        transport.invalidate()
    }
}

private final class BoundedRangeOperation: URLSessionRangeOperation, @unchecked Sendable {
    private let lock = NSLock()
    private let validator: HTTPRangeResponseValidator
    private let expectedRange: HTTPByteRange
    private let collectBody: Bool
    private let clock = ContinuousClock()
    private let outcome = OneShotResult<HTTPBoundedRangeResult>()
    private var task: URLSessionDataTask?
    private var onFinish: (@Sendable () -> Void)?
    private var startedAt: ContinuousClock.Instant?
    private var contentRange: HTTPContentRange?
    private var received: UInt64 = 0
    private var retained: Data?
    private var pendingResult: HTTPBoundedRangeResult?
    private var finished = false

    init(
        validator: HTTPRangeResponseValidator,
        collectBody: Bool
    ) {
        self.validator = validator
        expectedRange = validator.expectedRange
        self.collectBody = collectBody
        retained = collectBody ? Data() : nil
    }

    func start(
        _ task: URLSessionDataTask,
        onFinish: @escaping @Sendable () -> Void
    ) async throws -> HTTPBoundedRangeResult {
        let shouldStart = lock.withLock {
            guard !finished else { return false }
            self.task = task
            self.onFinish = onFinish
            startedAt = clock.now
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
        do {
            let validated = try validator.validate(response)
            lock.withLock {
                contentRange = validated.contentRange
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
                    HTTPRangeResponseError.bodyLengthMismatch(
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
                    HTTPRangeResponseError.transport(
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
                    HTTPRangeResponseError.bodyLengthMismatch(
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
                    false,
                    nil as URLSessionDataTask?,
                    nil as (@Sendable () -> Void)?
                )
            }
            finished = true
            let task = self.task
            self.task = nil
            let onFinish = self.onFinish
            self.onFinish = nil
            return (true, task, onFinish)
        }
        guard resources.0 else { return }
        resources.1?.cancel()
        resources.2?()
        outcome.resolve(result)
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
