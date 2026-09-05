import BiliModels
import Foundation

@MainActor
final class DanmakuTexturePreparationOwner {
    typealias Rasterize =
        @Sendable (DanmakuTextureCacheKey) -> DanmakuTexturePayload?

    struct Configuration: Sendable, Equatable {
        static let production = Configuration(
            maximumConcurrentOperations: 2,
            maximumOutstandingRequests:
                DanmakuLaneConfiguration.hardMaximumActiveCount,
            cacheLimits: .production
        )

        let maximumConcurrentOperations: Int
        let maximumOutstandingRequests: Int
        let cacheLimits: DanmakuTextureLRUCache.Limits
    }

    typealias Completion =
        @MainActor @Sendable (
            DanmakuPreparationResult
        ) -> Void

    private struct Request {
        let generation: UInt64
        let key: DanmakuTextureCacheKey
        let completion: Completion
    }

    private struct Prepared {
        let generation: UInt64
        let key: DanmakuTextureCacheKey
    }

    private struct Inflight {
        let operation: Operation
        var requestIDs: [UInt64]
    }

    private(set) var rasterizationCount = 0
    private var cache: DanmakuTextureLRUCache
    private var requests: [UInt64: Request] = [:]
    private var prepared: [UInt64: Prepared] = [:]
    private var inflight: [DanmakuTextureCacheKey: Inflight] = [:]
    private let configuration: Configuration
    private let queue: OperationQueue
    private let rasterize: Rasterize
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(
        configuration: Configuration = .production,
        rasterize: @escaping Rasterize = {
            DanmakuTextureRasterizer.rasterize(key: $0)
        }
    ) {
        precondition(configuration.maximumConcurrentOperations > 0)
        precondition(configuration.maximumOutstandingRequests > 0)
        self.configuration = configuration
        self.rasterize = rasterize
        cache = DanmakuTextureLRUCache(limits: configuration.cacheLimits)
        queue = OperationQueue()
        queue.name = "com.shirokyan.BiliKit.danmaku-texture-preparation"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount =
            configuration.maximumConcurrentOperations
        installMemoryPressureSource()
    }

    deinit {
        memoryPressureSource?.setEventHandler {}
        memoryPressureSource?.cancel()
        queue.cancelAllOperations()
    }

    var outstandingRequestCount: Int { requests.count + prepared.count }
    var cachedTextureCount: Int { cache.count }
    var cachedByteCost: Int { cache.totalCost }
    var cacheHitCount: Int { cache.hitCount }
    var cacheMissCount: Int { cache.missCount }
    var cacheEvictionCount: Int { cache.evictionCount }
    var maximumConcurrentOperationCount: Int {
        queue.maxConcurrentOperationCount
    }

    func prepare(
        event: DanmakuEvent,
        style: CoreAnimationDanmakuStyle,
        backingScale: Double,
        preparationID: UInt64,
        generation: UInt64,
        completion: @escaping Completion
    ) {
        guard requests[preparationID] == nil,
            prepared[preparationID] == nil,
            outstandingRequestCount
                < configuration.maximumOutstandingRequests
        else {
            completion(.rejected(.capacity))
            return
        }
        guard
            let key = DanmakuTextureRasterizer.key(
                event: event,
                style: style,
                backingScale: backingScale
            )
        else {
            completion(.rejected(.invalidInput))
            return
        }
        if let payload = cache.value(for: key) {
            prepared[preparationID] = Prepared(
                generation: generation,
                key: key
            )
            completion(.ready(payload.metrics))
            return
        }

        requests[preparationID] = Request(
            generation: generation,
            key: key,
            completion: completion
        )
        if var existing = inflight[key] {
            existing.requestIDs.append(preparationID)
            inflight[key] = existing
            return
        }

        let rasterize = rasterize
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard operation?.isCancelled == false else { return }
            let payload = rasterize(key)
            guard operation?.isCancelled == false else { return }
            let handoff = DispatchSemaphore(value: 0)
            Task { @MainActor [weak self] in
                defer { handoff.signal() }
                self?.finish(key: key, payload: payload)
            }
            // Keep this OperationQueue slot occupied until MainActor either accepts
            // or discards the pixels. Otherwise queued Tasks can retain one full
            // payload per request while the main thread is busy. MainActor teardown
            // must remain cancellation-only and never wait for this queue.
            handoff.wait()
        }
        inflight[key] = Inflight(
            operation: operation,
            requestIDs: [preparationID]
        )
        rasterizationCount += 1
        queue.addOperation(operation)
    }

    func consume(
        preparationID: UInt64,
        generation: UInt64,
        expectedKey: DanmakuTextureCacheKey
    ) -> DanmakuTexturePayload? {
        guard let value = prepared.removeValue(forKey: preparationID),
            value.generation == generation,
            value.key == expectedKey
        else {
            return nil
        }
        return cache.value(for: expectedKey)
    }

    func discard(preparationID: UInt64) {
        requests.removeValue(forKey: preparationID)
        prepared.removeValue(forKey: preparationID)
    }

    func cancelAllPreparations() {
        requests.removeAll(keepingCapacity: false)
        prepared.removeAll(keepingCapacity: false)
        let operations = inflight.values.map(\.operation)
        inflight.removeAll(keepingCapacity: false)
        for operation in operations {
            operation.cancel()
        }
    }

    func handleMemoryPressureForTesting() {
        handleMemoryPressure()
    }

    private func finish(
        key: DanmakuTextureCacheKey,
        payload: DanmakuTexturePayload?
    ) {
        guard let work = inflight.removeValue(forKey: key) else { return }
        let acceptedPayload = payload.flatMap { value in
            cache.insert(value, for: key) ? value : nil
        }
        for preparationID in work.requestIDs {
            guard let request = requests.removeValue(forKey: preparationID)
            else {
                continue
            }
            guard let acceptedPayload else {
                request.completion(.rejected(.oversized))
                continue
            }
            prepared[preparationID] = Prepared(
                generation: request.generation,
                key: request.key
            )
            request.completion(.ready(acceptedPayload.metrics))
        }
    }

    private func installMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.handleMemoryPressure()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func handleMemoryPressure() {
        let completions = requests.values.map(\.completion)
        requests.removeAll(keepingCapacity: false)
        prepared.removeAll(keepingCapacity: false)
        let operations = inflight.values.map(\.operation)
        inflight.removeAll(keepingCapacity: false)
        cache.removeAll()
        for operation in operations {
            operation.cancel()
        }
        for completion in completions {
            completion(.rejected(.capacity))
        }
    }
}
