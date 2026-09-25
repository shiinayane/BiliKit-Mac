import Foundation

/// 单个 Range data task 的正文消费方；由 `URLSessionRangeTransport` 按 task 分发 delegate 事件。
protocol URLSessionRangeOperation: AnyObject, Sendable {
    associatedtype Output: Sendable

    /// 启动 task 并等待唯一结果；结束时必须调用 `onFinish` 解除 transport 登记。
    func start(
        _ task: URLSessionDataTask,
        onFinish: @escaping @Sendable () -> Void
    ) async throws -> Output
    func cancel()
    func receive(
        _ response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    )
    func receive(_ data: Data)
    func complete(error: (any Error)?)
}

/// Range client 共用的 URLSession delegate 与 task 生命周期。
///
/// 拒绝重定向；session 在首次请求时才于锁内创建，`invalidate` 后取消在途 operation 且不再创建新 task。
final class URLSessionRangeTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var operations: [Int: any URLSessionRangeOperation] = [:]
    private var session: URLSession?
    private var isInvalidated = false

    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
        super.init()
    }

    func run<Operation: URLSessionRangeOperation>(
        _ request: URLRequest,
        operation: Operation
    ) async throws -> Operation.Output {
        let task = try lock.withLock {
            guard !isInvalidated else { throw CancellationError() }
            let task = activeSession().dataTask(with: request)
            operations[task.taskIdentifier] = operation
            return task
        }
        let taskIdentifier = task.taskIdentifier
        return try await withTaskCancellationHandler {
            try await operation.start(task) { [weak self] in
                self?.lock.withLock { self?.operations[taskIdentifier] = nil }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    func invalidate() {
        let (pending, session) = lock.withLock {
            () -> ([any URLSessionRangeOperation], URLSession?) in
            isInvalidated = true
            let pending = Array(operations.values)
            operations.removeAll()
            return (pending, session)
        }
        for operation in pending { operation.cancel() }
        session?.invalidateAndCancel()
    }

    /// 调用方必须持有 `lock`。
    private func activeSession() -> URLSession {
        if let session { return session }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: queue
        )
        self.session = session
        return session
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

    private func operation(for taskIdentifier: Int) -> (any URLSessionRangeOperation)? {
        lock.withLock { operations[taskIdentifier] }
    }
}
