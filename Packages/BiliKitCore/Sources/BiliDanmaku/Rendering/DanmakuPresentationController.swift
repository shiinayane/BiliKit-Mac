import BiliApplication
import BiliModels
import Foundation

struct DanmakuDensityAdmissionPolicy: Sendable, Equatable {
    let minimumHorizontalGap: Double
    let maximumOverlapDepth: Int

    init(_ density: DanmakuDensity) {
        switch density {
        case .normal:
            minimumHorizontalGap = 64
            maximumOverlapDepth = 1
        case .increased:
            minimumHorizontalGap = 32
            maximumOverlapDepth = 1
        case .overlapping:
            minimumHorizontalGap = 0
            maximumOverlapDepth = 3
        }
    }
}

public struct DanmakuRendererStatistics: Sendable, Equatable {
    public private(set) var admitted = 0
    public private(set) var droppedNoLane = 0
    public private(set) var droppedCapacity = 0
    public private(set) var active = 0
    public private(set) var peakActive = 0

    public init() {}

    mutating func record(_ admission: DanmakuLaneAdmission) {
        admitted += admission.admitted.count
        droppedNoLane += admission.dropCounts.noLane
        droppedCapacity += admission.dropCounts.capacity
    }

    mutating func recordCapacityDrops(_ count: Int) {
        droppedCapacity += max(count, 0)
    }

    mutating func recordPreparationDrop(
        _ reason: DanmakuPreparationRejectionReason
    ) {
        switch reason {
        case .capacity:
            droppedCapacity += 1
        case .invalidInput, .oversized:
            droppedNoLane += 1
        case .cancelled:
            break
        }
    }

    mutating func updateActive(_ count: Int) {
        active = count
        peakActive = max(peakActive, count)
    }
}

@MainActor
/// 在调度 batch 与具体 renderer 之间执行 identity/generation 检查、lane 分配与容量治理。
///
/// surface owner ID 防止旧 `AVPlayerView` 的迟到 resize/detach 操作清空新宿主；换 identity、
/// seek generation 或显式清屏都会同步清空 allocator 与 backend。
public final class DanmakuPresentationController:
    DanmakuPresentationSink,
    DanmakuRenderingBackendDelegate
{
    private struct PendingPreparation {
        let event: DanmakuEvent
        let speedLevel: DanmakuSpeedLevel
        let identity: PlaybackItemIdentity
        let discontinuityGeneration: UInt64
        let preparationGeneration: UInt64
    }

    public private(set) var statistics = DanmakuRendererStatistics()

    private let backend: any DanmakuRenderingBackend
    private let motionPolicy: DanmakuMotionPolicy
    private var allocator: DanmakuLaneAllocator
    private var configuration: DanmakuLaneConfiguration
    private var speedLevel = DanmakuSpeedLevel.three
    private var displayArea = DanmakuDisplayArea.full
    private var density = DanmakuDensity.normal
    private var identity: PlaybackItemIdentity?
    private var discontinuityGeneration: UInt64?
    private var surfaceOwnerID: UUID?
    private var backingScale = 2.0
    private var preparationGeneration: UInt64 = 0
    private var nextPreparationID: UInt64 = 0
    private var pendingPreparations: [UInt64: PendingPreparation] = [:]
    private var pendingOrder: [UInt64] = []
    private var completedPreparations: [UInt64: DanmakuPreparationResult] = [:]
    private var latestSnapshot: PlaybackTimelineSnapshot?

    public init(
        backend: any DanmakuRenderingBackend,
        configuration: DanmakuLaneConfiguration,
        motionPolicy: DanmakuMotionPolicy = DanmakuMotionPolicy()
    ) {
        self.backend = backend
        self.allocator = DanmakuLaneAllocator(configuration: configuration)
        self.configuration = configuration
        self.motionPolicy = motionPolicy
        backend.delegate = self
        backend.updateSurfaceSize(
            width: configuration.surfaceWidth,
            height: configuration.surfaceHeight,
            backingScale: backingScale
        )
    }

    public convenience init(
        backend: any DanmakuRenderingBackend,
        configuration: DanmakuLaneConfiguration,
        durations: DanmakuRendererDurations
    ) {
        self.init(
            backend: backend,
            configuration: configuration,
            motionPolicy: DanmakuMotionPolicy(fixedDurations: durations)
        )
    }

    /// 只呈现与快照 identity 和 discontinuity generation 完全匹配的 batch。
    public func apply(_ update: DanmakuPresentationUpdate) {
        guard let updateIdentity = update.snapshot.identity else {
            stopPresentation()
            return
        }
        let matchingBatch = update.batch.flatMap { batch in
            batch.identity == updateIdentity
                && batch.discontinuityGeneration
                    == update.snapshot.discontinuityGeneration
                ? batch
                : nil
        }

        let changesIdentity = identity != updateIdentity
        let changesGeneration =
            discontinuityGeneration
            != update.snapshot.discontinuityGeneration
        if changesIdentity
            || changesGeneration
            || matchingBatch?.clearsExisting == true
        {
            clearBackendAndAllocator()
        }
        identity = updateIdentity
        discontinuityGeneration =
            update.snapshot.discontinuityGeneration
        latestSnapshot = update.snapshot

        let effectiveRate =
            update.snapshot.state == .playing
            ? update.snapshot.rate
            : 0
        backend.setPlaybackRate(effectiveRate)

        guard let batch = matchingBatch,
            !batch.clearsExisting
        else {
            return
        }

        let availablePreparationSlots = max(
            DanmakuLaneConfiguration.hardMaximumActiveCount
                - pendingPreparations.count,
            0
        )
        let attemptedEvents = batch.events.prefix(availablePreparationSlots)
        statistics.recordCapacityDrops(
            batch.events.count - attemptedEvents.count
        )
        for event in attemptedEvents {
            enqueuePreparation(
                event,
                identity: updateIdentity,
                discontinuityGeneration:
                    update.snapshot.discontinuityGeneration
            )
        }
    }

    public func clearPresentation() {
        clearBackendAndAllocator()
    }

    public func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {
        self.speedLevel = speedLevel
    }

    public func setOpacity(_ opacity: DanmakuOpacity) {
        backend.setOpacity(opacity)
    }

    public func setDisplayArea(_ displayArea: DanmakuDisplayArea) {
        self.displayArea = displayArea
        updateAdmissionPolicy()
    }

    public func setDensity(_ density: DanmakuDensity) {
        self.density = density
        updateAdmissionPolicy()
    }

    public func stopPresentation() {
        cancelPendingPreparations()
        _ = allocator.clear()
        backend.stop()
        identity = nil
        discontinuityGeneration = nil
        latestSnapshot = nil
        statistics.updateActive(0)
    }

    private func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    ) {
        let normalizedScale = Self.normalizedBackingScale(backingScale)
        if normalizedScale != self.backingScale {
            self.backingScale = normalizedScale
            cancelPendingPreparations()
        }
        configuration = DanmakuLaneConfiguration(
            surfaceWidth: width,
            surfaceHeight: height,
            laneHeight: configuration.laneHeight,
            minimumHorizontalGap: configuration.minimumHorizontalGap,
            maximumActiveCount: configuration.maximumActiveCount,
            displayAreaFraction: configuration.displayAreaFraction,
            maximumOverlapDepth: configuration.maximumOverlapDepth
        )
        allocator.updateConfiguration(configuration)
        backend.updateSurfaceSize(
            width: width,
            height: height,
            backingScale: normalizedScale
        )
    }

    @discardableResult
    public func attachSurface(ownerID: UUID) -> Bool {
        guard surfaceOwnerID != ownerID else { return true }
        surfaceOwnerID = ownerID
        clearBackendAndAllocator()
        return true
    }

    @discardableResult
    public func detachSurface(ownerID: UUID) -> Bool {
        guard surfaceOwnerID == ownerID else { return false }
        surfaceOwnerID = nil
        clearBackendAndAllocator()
        return true
    }

    @discardableResult
    public func updateSurface(
        width: Double,
        height: Double,
        backingScale: Double = 2,
        ownerID: UUID
    ) -> Bool {
        guard surfaceOwnerID == ownerID else { return false }
        updateSurfaceSize(
            width: width,
            height: height,
            backingScale: backingScale
        )
        return true
    }

    public func rendererDidFinish(eventID: String) {
        allocator.remove(eventID: eventID)
        statistics.updateActive(allocator.activeCount)
    }

    private func clearBackendAndAllocator() {
        cancelPendingPreparations()
        _ = allocator.clear()
        backend.clearAll()
        statistics.updateActive(0)
    }

    private func enqueuePreparation(
        _ event: DanmakuEvent,
        identity: PlaybackItemIdentity,
        discontinuityGeneration: UInt64
    ) {
        nextPreparationID &+= 1
        let preparationID = nextPreparationID
        let generation = preparationGeneration
        pendingPreparations[preparationID] = PendingPreparation(
            event: event,
            speedLevel: speedLevel,
            identity: identity,
            discontinuityGeneration: discontinuityGeneration,
            preparationGeneration: generation
        )
        pendingOrder.append(preparationID)
        backend.prepare(
            event,
            preparationID: preparationID,
            generation: generation,
            backingScale: backingScale
        ) { [weak self] result in
            self?.completePreparation(
                preparationID: preparationID,
                generation: generation,
                result: result
            )
        }
    }

    private func completePreparation(
        preparationID: UInt64,
        generation: UInt64,
        result: DanmakuPreparationResult
    ) {
        guard generation == preparationGeneration,
            pendingPreparations[preparationID]?.preparationGeneration
                == generation
        else {
            backend.discardPreparation(preparationID: preparationID)
            return
        }
        completedPreparations[preparationID] = result
        drainCompletedPreparations()
    }

    private func drainCompletedPreparations() {
        while let preparationID = pendingOrder.first,
            let result = completedPreparations.removeValue(
                forKey: preparationID
            )
        {
            pendingOrder.removeFirst()
            guard
                let pending = pendingPreparations.removeValue(
                    forKey: preparationID
                )
            else {
                backend.discardPreparation(preparationID: preparationID)
                continue
            }
            processPreparation(
                result,
                preparationID: preparationID,
                pending: pending
            )
        }
    }

    private func processPreparation(
        _ result: DanmakuPreparationResult,
        preparationID: UInt64,
        pending: PendingPreparation
    ) {
        guard pending.preparationGeneration == preparationGeneration,
            identity == pending.identity,
            discontinuityGeneration == pending.discontinuityGeneration,
            let snapshot = latestSnapshot,
            snapshot.identity == pending.identity,
            snapshot.discontinuityGeneration
                == pending.discontinuityGeneration
        else {
            backend.discardPreparation(preparationID: preparationID)
            return
        }
        guard case .ready(let metrics) = result else {
            if case .rejected(let reason) = result {
                statistics.recordPreparationDrop(reason)
            }
            backend.discardPreparation(preparationID: preparationID)
            return
        }

        let request = DanmakuLaneRequest(
            event: pending.event,
            width: metrics.width,
            height: metrics.height,
            durationSeconds: motionPolicy.duration(
                for: pending.event.mode,
                textWidth: metrics.width,
                surfaceWidth: configuration.surfaceWidth,
                speedLevel: pending.speedLevel
            )
        )
        let admission = allocator.admit(
            [request],
            at: snapshot.positionSeconds
        )
        for expired in admission.expired {
            backend.remove(eventID: expired.request.event.id)
        }
        var installed: [DanmakuLanePlacement] = []
        for placement in admission.admitted {
            if backend.renderPrepared(
                placement,
                preparationID: preparationID,
                generation: preparationGeneration
            ) {
                installed.append(placement)
            } else {
                allocator.remove(eventID: placement.request.event.id)
            }
        }
        if installed.isEmpty {
            backend.discardPreparation(preparationID: preparationID)
        }
        statistics.recordCapacityDrops(
            admission.admitted.count - installed.count
        )
        statistics.record(
            DanmakuLaneAdmission(
                expired: admission.expired,
                admitted: installed,
                dropCounts: admission.dropCounts
            )
        )
        statistics.updateActive(allocator.activeCount)
    }

    private func cancelPendingPreparations() {
        preparationGeneration &+= 1
        pendingPreparations.removeAll(keepingCapacity: false)
        pendingOrder.removeAll(keepingCapacity: false)
        completedPreparations.removeAll(keepingCapacity: false)
        backend.cancelPendingPreparations()
    }

    private static func normalizedBackingScale(_ scale: Double) -> Double {
        scale.isFinite
            ? min(max(scale, 1), DanmakuTextureRasterizer.maximumBackingScale)
            : 2
    }

    private func updateAdmissionPolicy() {
        let effectiveDensity: DanmakuDensity =
            displayArea == .full ? density : .normal
        let policy = DanmakuDensityAdmissionPolicy(effectiveDensity)
        configuration = DanmakuLaneConfiguration(
            surfaceWidth: configuration.surfaceWidth,
            surfaceHeight: configuration.surfaceHeight,
            laneHeight: configuration.laneHeight,
            minimumHorizontalGap: policy.minimumHorizontalGap,
            maximumActiveCount: configuration.maximumActiveCount,
            displayAreaFraction: displayArea.fraction,
            maximumOverlapDepth: policy.maximumOverlapDepth
        )
        allocator.updateConfiguration(configuration)
    }
}
