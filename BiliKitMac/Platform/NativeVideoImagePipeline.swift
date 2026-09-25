import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Synchronization

enum NativeVideoImageLoadOrigin: Equatable {
    case memoryCache
    case network

    var shouldAnimate: Bool { self == .network }
}

struct NativeVideoImageLoadResult: Sendable {
    let image: CGImage
    let origin: NativeVideoImageLoadOrigin
}

enum NativeVideoImageVariant: Hashable, Sendable {
    case cover
    case avatar
    case commentEmote
    case commentPicture
    case commentPicturePreview

    var maximumDecodedPixelSize: Int {
        switch self {
        case .cover:
            640
        case .avatar:
            96
        case .commentEmote:
            128
        case .commentPicture:
            1_024
        case .commentPicturePreview:
            3_840
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

private struct NativeVideoImageResponse: Sendable {
    let data: Data
}

private enum NativeVideoImageTransferError: Error {
    case invalidResponse
    case responseTooLarge
}

private final class NativeVideoImageTaskBox: Sendable {
    private struct State {
        var task: URLSessionTask?
        var isCancelled = false
    }

    private let state = Mutex(State())

    func store(_ task: URLSessionTask) {
        let isCancelled = state.withLock { state in
            if !state.isCancelled { state.task = task }
            return state.isCancelled
        }
        if isCancelled { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { state in
            state.isCancelled = true
            return state.task
        }
        task?.cancel()
    }
}

final class NativeVideoImageSessionGate: Sendable {
    private let isInvalidated = Mutex(false)

    func register(_ operation: () -> Void) -> Bool {
        isInvalidated.withLock { isInvalidated in
            guard !isInvalidated else { return false }
            operation()
            return true
        }
    }

    func invalidate(_ session: URLSession) {
        isInvalidated.withLock { isInvalidated in
            guard !isInvalidated else { return }
            isInvalidated = true
            session.invalidateAndCancel()
        }
    }
}

/// 一个等待者只 resume 一次：先完成则缓存结果，先挂起则由 `finish` 恢复；两边都在锁外 resume。
final class NativeVideoImageWaiter: Sendable {
    private enum State {
        case waiting
        case suspended(CheckedContinuation<NativeVideoImageLoadResult?, Never>)
        case completed(NativeVideoImageLoadResult?)
    }

    private let state = Mutex(State.waiting)

    func value() async -> NativeVideoImageLoadResult? {
        await withCheckedContinuation { continuation in
            let completed: NativeVideoImageLoadResult?? = state.withLock { state in
                switch state {
                case .waiting:
                    state = .suspended(continuation)
                    return nil
                case .suspended:
                    preconditionFailure("image waiter may only be awaited once")
                case .completed(let result):
                    return .some(result)
                }
            }
            if let completed { continuation.resume(returning: completed) }
        }
    }

    func finish(with result: NativeVideoImageLoadResult?) {
        let continuation: CheckedContinuation<NativeVideoImageLoadResult?, Never>? =
            state.withLock { state in
                switch state {
                case .waiting:
                    state = .completed(result)
                    return nil
                case .suspended(let continuation):
                    state = .completed(result)
                    return continuation
                case .completed:
                    return nil
                }
            }
        continuation?.resume(returning: result)
    }
}

private final class NativeVideoImageSessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct Pending {
        let expectedHost: String
        let continuation: CheckedContinuation<NativeVideoImageResponse, Error>
        var isAccepted = false
        var accumulator = NativeVideoImageResponseAccumulator(
            maximumBytes: NativeVideoImagePipeline.maximumResponseBytes
        )
    }

    private let pending = Mutex<[Int: Pending]>([:])

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
                    pending.withLock {
                        $0[dataTask.taskIdentifier] = Pending(
                            expectedHost: expectedHost,
                            continuation: continuation
                        )
                    }
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
        let http = response as? HTTPURLResponse
        let isAccepted = pending.withLock { pending in
            guard let http, var transfer = pending[dataTask.taskIdentifier] else {
                return false
            }
            transfer.isAccepted =
                (200..<300).contains(http.statusCode)
                && http.url?.scheme?.lowercased() == "https"
                && http.url?.host?.lowercased() == transfer.expectedHost
                && http.mimeType?.lowercased().hasPrefix("image/") == true
                && NativeVideoImagePipeline.acceptsExpectedLength(http.expectedContentLength)
            pending[dataTask.taskIdentifier] = transfer
            return transfer.isAccepted
        }
        if isAccepted {
            completionHandler(.allow)
        } else {
            fail(dataTask, with: .invalidResponse)
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let accepted = pending.withLock { pending in
            guard var transfer = pending[dataTask.taskIdentifier] else { return true }
            guard transfer.accumulator.append(data) else { return false }
            pending[dataTask.taskIdentifier] = transfer
            return true
        }
        guard !accepted else { return }
        fail(dataTask, with: .responseTooLarge)
        dataTask.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let transfer = pending.withLock({ $0.removeValue(forKey: task.taskIdentifier) })
        else { return }
        if let error {
            transfer.continuation.resume(throwing: error)
        } else if transfer.isAccepted {
            transfer.continuation.resume(
                returning: NativeVideoImageResponse(data: transfer.accumulator.data)
            )
        } else {
            transfer.continuation.resume(
                throwing: NativeVideoImageTransferError.invalidResponse
            )
        }
    }

    private func fail(_ task: URLSessionTask, with error: NativeVideoImageTransferError) {
        pending.withLock { $0.removeValue(forKey: task.taskIdentifier) }?
            .continuation.resume(throwing: error)
    }
}

final class NativeVideoImagePipeline: Sendable {
    static let maximumResponseBytes = 8 * 1_024 * 1_024
    static let cacheCountLimit = 160
    static let cacheCostLimit = 64 * 1_024 * 1_024

    private struct InFlight {
        let id: UInt64
        var task: Task<Void, Never>?
        var waiters: [UInt64: NativeVideoImageWaiter]
    }

    private struct State {
        var cache = NativeVideoImageCache(
            countLimit: NativeVideoImagePipeline.cacheCountLimit,
            costLimit: NativeVideoImagePipeline.cacheCostLimit
        )
        var inFlight: [NativeVideoImageKey: InFlight] = [:]
        var nextRequestID: UInt64 = 0
        var nextWaiterID: UInt64 = 0
        var isShutdown = false
    }

    private enum Lookup {
        case unavailable
        case cached(CGImage)
        case request(
            requestID: UInt64,
            waiterID: UInt64,
            NativeVideoImageWaiter,
            startsNetwork: Bool
        )
    }

    private let state = Mutex(State())
    private let sessionGate = NativeVideoImageSessionGate()
    private let sessionDelegate = NativeVideoImageSessionDelegate()
    private let session: URLSession

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
        state.withLock { state in
            guard !state.isShutdown else { return nil }
            return state.cache.image(for: NativeVideoImageKey(url: url, variant: variant))
        }
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
        case .request(let requestID, let waiterID, let waiter, let startsNetwork):
            if startsNetwork {
                startRequest(key: key, requestID: requestID)
            }
            let result = await withTaskCancellationHandler {
                await waiter.value()
            } onCancel: {
                self.cancelWaiter(key: key, requestID: requestID, waiterID: waiterID)
            }
            guard isActive, !Task.isCancelled else {
                return nil
            }
            return result
        }
    }

    func shutdown() {
        let inFlight: [InFlight]? = state.withLock { state in
            guard !state.isShutdown else { return nil }
            state.isShutdown = true
            state.cache.removeAll()
            let requests = Array(state.inFlight.values)
            state.inFlight.removeAll()
            return requests
        }
        guard let inFlight else { return }
        for request in inFlight { request.task?.cancel() }
        for waiter in inFlight.flatMap({ $0.waiters.values }) { waiter.finish(with: nil) }
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
                kCGImageSourceShouldCacheImmediately: true
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
        state.withLock { state in
            guard !state.isShutdown else { return .unavailable }
            if let image = state.cache.image(for: key) {
                return .cached(image)
            }
            state.nextWaiterID &+= 1
            let waiterID = state.nextWaiterID
            let waiter = NativeVideoImageWaiter()
            if var existing = state.inFlight[key] {
                existing.waiters[waiterID] = waiter
                state.inFlight[key] = existing
                return .request(
                    requestID: existing.id,
                    waiterID: waiterID,
                    waiter,
                    startsNetwork: false
                )
            }
            state.nextRequestID &+= 1
            let requestID = state.nextRequestID
            state.inFlight[key] = InFlight(
                id: requestID,
                task: nil,
                waiters: [waiterID: waiter]
            )
            return .request(
                requestID: requestID,
                waiterID: waiterID,
                waiter,
                startsNetwork: true
            )
        }
    }

    /// 在锁外创建网络 Task；请求已被取消或关闭时立即取消刚创建的 Task。
    private func startRequest(key: NativeVideoImageKey, requestID: UInt64) {
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await loadNetworkImage(for: key)
            finishRequest(key: key, requestID: requestID, result: result)
        }
        let isAttached = state.withLock { state in
            guard var active = state.inFlight[key], active.id == requestID else {
                return false
            }
            active.task = task
            state.inFlight[key] = active
            return true
        }
        if !isAttached { task.cancel() }
    }

    private var isActive: Bool {
        state.withLock { !$0.isShutdown }
    }

    private func cancelWaiter(
        key: NativeVideoImageKey,
        requestID: UInt64,
        waiterID: UInt64
    ) {
        let removed: (NativeVideoImageWaiter, Task<Void, Never>?)? = state.withLock { state in
            guard var request = state.inFlight[key], request.id == requestID,
                let waiter = request.waiters.removeValue(forKey: waiterID)
            else { return nil }
            guard request.waiters.isEmpty else {
                state.inFlight[key] = request
                return (waiter, nil)
            }
            state.inFlight[key] = nil
            return (waiter, request.task)
        }
        guard let (waiter, task) = removed else { return }
        waiter.finish(with: nil)
        task?.cancel()
    }

    private func finishRequest(
        key: NativeVideoImageKey,
        requestID: UInt64,
        result: NativeVideoImageLoadResult?
    ) {
        let waiters: [NativeVideoImageWaiter] = state.withLock { state in
            guard let request = state.inFlight[key], request.id == requestID else {
                return []
            }
            state.inFlight[key] = nil
            return Array(request.waiters.values)
        }
        for waiter in waiters { waiter.finish(with: result) }
    }

    private func store(_ image: CGImage, for key: NativeVideoImageKey) -> Bool {
        state.withLock { state in
            guard !state.isShutdown else { return false }
            state.cache.insert(image, for: key)
            return true
        }
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
