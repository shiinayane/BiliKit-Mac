import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum NativeVideoImageLoadOrigin: Equatable {
    case memoryCache
    case network

    var shouldAnimate: Bool { self == .network }
}

struct NativeVideoImageLoadResult: @unchecked Sendable {
    let image: CGImage
    let origin: NativeVideoImageLoadOrigin
}

enum NativeVideoImageVariant: Hashable, Sendable {
    case cover
    case avatar

    var maximumDecodedPixelSize: Int {
        switch self {
        case .cover:
            640
        case .avatar:
            96
        }
    }
}

struct NativeVideoImageKey: Hashable, Sendable {
    let url: URL
    let variant: NativeVideoImageVariant
}

struct NativeVideoImageResponseAccumulator {
    private(set) var data = Data()
    let maximumBytes: Int

    mutating func append(_ chunk: Data) -> Bool {
        guard chunk.count <= maximumBytes - data.count else { return false }
        data.append(chunk)
        return true
    }
}

private struct NativeVideoImageResponse: @unchecked Sendable {
    let data: Data
}

private enum NativeVideoImageTransferError: Error {
    case invalidResponse
    case responseTooLarge
}

private final class NativeVideoImageTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func store(_ task: URLSessionTask) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task.cancel()
        } else {
            self.task = task
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

final class NativeVideoImageSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isInvalidated = false

    func register(_ operation: () -> Void) -> Bool {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return false
        }
        operation()
        lock.unlock()
        return true
    }

    func invalidate(_ session: URLSession) {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }
        isInvalidated = true
        session.invalidateAndCancel()
        lock.unlock()
    }
}

private final class NativeVideoImageWaiter: @unchecked Sendable {
    private enum State {
        case waiting
        case suspended(CheckedContinuation<NativeVideoImageLoadResult?, Never>)
        case completed(NativeVideoImageLoadResult?)
    }

    private let lock = NSLock()
    private var state: State = .waiting

    func value() async -> NativeVideoImageLoadResult? {
        await withCheckedContinuation { continuation in
            lock.lock()
            switch state {
            case .waiting:
                state = .suspended(continuation)
                lock.unlock()
            case .suspended:
                lock.unlock()
                preconditionFailure("image waiter may only be awaited once")
            case .completed(let result):
                lock.unlock()
                continuation.resume(returning: result)
            }
        }
    }

    func finish(with result: NativeVideoImageLoadResult?) {
        lock.lock()
        switch state {
        case .waiting:
            state = .completed(result)
            lock.unlock()
        case .suspended(let continuation):
            state = .completed(result)
            lock.unlock()
            continuation.resume(returning: result)
        case .completed:
            lock.unlock()
        }
    }
}

private final class NativeVideoImageSessionDelegate: NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    private struct Pending {
        let expectedHost: String
        let continuation: CheckedContinuation<NativeVideoImageResponse, Error>
        var response: HTTPURLResponse?
        var accumulator: NativeVideoImageResponseAccumulator
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    func response(
        for request: URLRequest,
        using session: URLSession,
        gate: NativeVideoImageSessionGate
    ) async throws -> NativeVideoImageResponse {
        guard let expectedHost = request.url?.host?.lowercased() else {
            throw NativeVideoImageTransferError.invalidResponse
        }
        let taskBox = NativeVideoImageTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var task: URLSessionDataTask?
                let registered = gate.register {
                    let dataTask = session.dataTask(with: request)
                    let transfer = Pending(
                        expectedHost: expectedHost,
                        continuation: continuation,
                        response: nil,
                        accumulator: NativeVideoImageResponseAccumulator(
                            maximumBytes: NativeVideoImagePipeline.maximumResponseBytes
                        )
                    )
                    lock.lock()
                    pending[dataTask.taskIdentifier] = transfer
                    lock.unlock()
                    taskBox.store(dataTask)
                    task = dataTask
                }
                guard registered, let task else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
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
        guard let http = response as? HTTPURLResponse else {
            finish(dataTask, result: .failure(.invalidResponse))
            completionHandler(.cancel)
            return
        }
        lock.lock()
        guard var transfer = pending[dataTask.taskIdentifier] else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        let isAccepted =
            (200..<300).contains(http.statusCode)
            && http.url?.scheme?.lowercased() == "https"
            && http.url?.host?.lowercased() == transfer.expectedHost
            && http.mimeType?.lowercased().hasPrefix("image/") == true
            && NativeVideoImagePipeline.acceptsExpectedLength(http.expectedContentLength)
        if isAccepted {
            transfer.response = http
            pending[dataTask.taskIdentifier] = transfer
        }
        lock.unlock()
        if isAccepted {
            completionHandler(.allow)
        } else {
            finish(dataTask, result: .failure(.invalidResponse))
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard var transfer = pending[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        let accepted = transfer.accumulator.append(data)
        if accepted { pending[dataTask.taskIdentifier] = transfer }
        lock.unlock()
        guard !accepted else { return }
        finish(dataTask, result: .failure(.responseTooLarge))
        dataTask.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard let transfer = pending.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        lock.unlock()
        if let error {
            transfer.continuation.resume(throwing: error)
        } else if transfer.response != nil {
            transfer.continuation.resume(
                returning: NativeVideoImageResponse(
                    data: transfer.accumulator.data
                )
            )
        } else {
            transfer.continuation.resume(
                throwing: NativeVideoImageTransferError.invalidResponse
            )
        }
    }

    private func finish(
        _ task: URLSessionTask,
        result: Result<NativeVideoImageResponse, NativeVideoImageTransferError>
    ) {
        lock.lock()
        let transfer = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let transfer else { return }
        switch result {
        case .success(let response):
            transfer.continuation.resume(returning: response)
        case .failure(let error):
            transfer.continuation.resume(throwing: error)
        }
    }
}

final class NativeVideoImagePipeline: @unchecked Sendable {
    static let maximumResponseBytes = 8 * 1_024 * 1_024
    static let cacheCountLimit = 160
    static let cacheCostLimit = 64 * 1_024 * 1_024

    private struct InFlight {
        let id: UInt64
        var task: Task<Void, Never>?
        var waiters: [UInt64: NativeVideoImageWaiter]
    }

    private enum Lookup {
        case unavailable
        case cached(CGImage)
        case request(requestID: UInt64, waiterID: UInt64, NativeVideoImageWaiter)
    }

    private let lock = NSLock()
    private let sessionGate = NativeVideoImageSessionGate()
    private let sessionDelegate = NativeVideoImageSessionDelegate()
    private let session: URLSession
    private var cache = NativeVideoImageCache(
        countLimit: cacheCountLimit,
        costLimit: cacheCostLimit
    )
    private var inFlight: [NativeVideoImageKey: InFlight] = [:]
    private var nextRequestID: UInt64 = 0
    private var nextWaiterID: UInt64 = 0
    private var isShutdown = false

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(
            configuration: configuration,
            delegate: sessionDelegate,
            delegateQueue: nil
        )
    }

    deinit {
        sessionGate.invalidate(session)
    }

    func cachedImage(
        for url: URL,
        variant: NativeVideoImageVariant
    ) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard !isShutdown else { return nil }
        return cache.image(for: NativeVideoImageKey(url: url, variant: variant))
    }

    func image(
        for url: URL,
        variant: NativeVideoImageVariant
    ) async -> NativeVideoImageLoadResult? {
        guard
            !Task.isCancelled,
            url.scheme?.lowercased() == "https",
            url.user == nil,
            url.password == nil
        else { return nil }

        let key = NativeVideoImageKey(url: url, variant: variant)

        switch lookup(for: key) {
        case .unavailable:
            return nil
        case .cached(let image):
            return NativeVideoImageLoadResult(image: image, origin: .memoryCache)
        case .request(let requestID, let waiterID, let waiter):
            let result = await withTaskCancellationHandler {
                await waiter.value()
            } onCancel: {
                self.cancelWaiter(
                    key: key,
                    requestID: requestID,
                    waiterID: waiterID
                )
            }
            guard isActive, !Task.isCancelled else {
                return nil
            }
            return result
        }
    }

    func shutdown() {
        lock.lock()
        guard !isShutdown else {
            lock.unlock()
            return
        }
        isShutdown = true
        cache.removeAll()
        let tasks = inFlight.values.compactMap(\.task)
        let waiters = inFlight.values.flatMap { $0.waiters.values }
        inFlight.removeAll()
        lock.unlock()
        for task in tasks { task.cancel() }
        for waiter in waiters { waiter.finish(with: nil) }
        sessionGate.invalidate(session)
    }

    nonisolated static func acceptsExpectedLength(_ length: Int64) -> Bool {
        length < 0 || length <= maximumResponseBytes
    }

    nonisolated static func decodeImage(
        _ data: Data,
        variant: NativeVideoImageVariant
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: variant.maximumDecodedPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        )
    }

    private func loadNetworkImage(
        for key: NativeVideoImageKey
    ) async -> NativeVideoImageLoadResult? {
        do {
            var request = URLRequest(url: key.url)
            request.httpShouldHandleCookies = false
            let transfer = try await sessionDelegate.response(
                for: request,
                using: session,
                gate: sessionGate
            )
            guard
                !Task.isCancelled,
                let image = Self.decodeImage(transfer.data, variant: key.variant)
            else { return nil }
            guard store(image, for: key) else { return nil }
            return NativeVideoImageLoadResult(image: image, origin: .network)
        } catch {
            return nil
        }
    }

    private func lookup(for key: NativeVideoImageKey) -> Lookup {
        lock.lock()
        guard !isShutdown else {
            lock.unlock()
            return .unavailable
        }
        if let image = cache.image(for: key) {
            lock.unlock()
            return .cached(image)
        }
        nextWaiterID &+= 1
        let waiterID = nextWaiterID
        let waiter = NativeVideoImageWaiter()
        if var existing = inFlight[key] {
            existing.waiters[waiterID] = waiter
            inFlight[key] = existing
            lock.unlock()
            return .request(
                requestID: existing.id,
                waiterID: waiterID,
                waiter
            )
        }
        nextRequestID &+= 1
        let requestID = nextRequestID
        let request = InFlight(
            id: requestID,
            task: nil,
            waiters: [waiterID: waiter]
        )
        inFlight[key] = request
        lock.unlock()

        let task = Task { [weak self] in
            guard let self else { return }
            let result = await loadNetworkImage(for: key)
            finishRequest(key: key, requestID: requestID, result: result)
        }
        lock.lock()
        if var active = inFlight[key], active.id == requestID {
            active.task = task
            inFlight[key] = active
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
        return .request(
            requestID: requestID,
            waiterID: waiterID,
            waiter
        )
    }

    private var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isShutdown
    }

    private func cancelWaiter(
        key: NativeVideoImageKey,
        requestID: UInt64,
        waiterID: UInt64
    ) {
        lock.lock()
        guard var request = inFlight[key], request.id == requestID,
            let waiter = request.waiters.removeValue(forKey: waiterID)
        else {
            lock.unlock()
            return
        }
        let task: Task<Void, Never>?
        if request.waiters.isEmpty {
            inFlight[key] = nil
            task = request.task
        } else {
            inFlight[key] = request
            task = nil
        }
        lock.unlock()
        waiter.finish(with: nil)
        task?.cancel()
    }

    private func finishRequest(
        key: NativeVideoImageKey,
        requestID: UInt64,
        result: NativeVideoImageLoadResult?
    ) {
        lock.lock()
        guard let request = inFlight[key], request.id == requestID else {
            lock.unlock()
            return
        }
        inFlight[key] = nil
        let waiters = request.waiters.values
        lock.unlock()
        for waiter in waiters { waiter.finish(with: result) }
    }

    private func store(_ image: CGImage, for key: NativeVideoImageKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isShutdown else { return false }
        cache.insert(image, for: key)
        return true
    }
}

final class NativeVideoImagePipelineOwner {
    let pipeline = NativeVideoImagePipeline()

    func shutdown() {
        pipeline.shutdown()
    }

    deinit {
        shutdown()
    }
}

struct NativeVideoImageCache {
    private struct Entry {
        let image: CGImage
        let cost: Int
        var recency: UInt64
    }

    let countLimit: Int
    let costLimit: Int
    private(set) var totalCost = 0
    private(set) var count = 0
    private var clock: UInt64 = 0
    private var entries: [NativeVideoImageKey: Entry] = [:]

    init(countLimit: Int, costLimit: Int) {
        self.countLimit = countLimit
        self.costLimit = costLimit
    }

    mutating func image(for key: NativeVideoImageKey) -> CGImage? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.recency = clock
        entries[key] = entry
        return entry.image
    }

    mutating func insert(_ image: CGImage, for key: NativeVideoImageKey) {
        let cost = image.bytesPerRow * image.height
        guard cost <= costLimit, countLimit > 0, costLimit > 0 else { return }
        if let old = entries.removeValue(forKey: key) {
            totalCost -= old.cost
        }
        clock &+= 1
        entries[key] = Entry(image: image, cost: cost, recency: clock)
        totalCost += cost
        trimToLimits()
        count = entries.count
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
        count = 0
    }

    private mutating func trimToLimits() {
        while entries.count > countLimit || totalCost > costLimit {
            guard let oldest = entries.min(by: { $0.value.recency < $1.value.recency }) else {
                break
            }
            totalCost -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }
    }
}
