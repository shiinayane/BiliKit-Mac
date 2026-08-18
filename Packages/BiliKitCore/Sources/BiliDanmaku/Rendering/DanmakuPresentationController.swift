import BiliApplication
import BiliModels
import Foundation

struct DanmakuDensityAdmissionPolicy: Sendable, Equatable {
    let minimumHorizontalGap: Double
    let maximumOverlapDepth: Int

    init(_ density: DanmakuDensity) {
        switch density {
        case .normal:
            minimumHorizontalGap = 40
            maximumOverlapDepth = 1
        case .increased:
            minimumHorizontalGap = 20
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
            height: configuration.surfaceHeight
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

        let attemptedEvents = batch.events.prefix(
            DanmakuLaneConfiguration.hardMaximumActiveCount
        )
        let requests = attemptedEvents.map { event in
            let metrics = backend.measure(event)
            return DanmakuLaneRequest(
                event: event,
                width: metrics.width,
                height: metrics.height,
                durationSeconds: motionPolicy.duration(
                    for: event.mode,
                    textWidth: metrics.width,
                    surfaceWidth: configuration.surfaceWidth,
                    speedLevel: speedLevel
                )
            )
        }
        statistics.recordCapacityDrops(
            batch.events.count - attemptedEvents.count
        )
        let admission = allocator.admit(
            requests,
            at: update.snapshot.positionSeconds
        )
        for placement in admission.expired {
            backend.remove(eventID: placement.request.event.id)
        }
        for placement in admission.admitted {
            backend.render(placement)
        }
        statistics.record(admission)
        statistics.updateActive(allocator.activeCount)
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
        _ = allocator.clear()
        backend.stop()
        identity = nil
        discontinuityGeneration = nil
        statistics.updateActive(0)
    }

    private func updateSurfaceSize(
        width: Double,
        height: Double
    ) {
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
            height: height
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
        ownerID: UUID
    ) -> Bool {
        guard surfaceOwnerID == ownerID else { return false }
        updateSurfaceSize(width: width, height: height)
        return true
    }

    public func rendererDidFinish(eventID: String) {
        allocator.remove(eventID: eventID)
        statistics.updateActive(allocator.activeCount)
    }

    private func clearBackendAndAllocator() {
        _ = allocator.clear()
        backend.clearAll()
        statistics.updateActive(0)
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
