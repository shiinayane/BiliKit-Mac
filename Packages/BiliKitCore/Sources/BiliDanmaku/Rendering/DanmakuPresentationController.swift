import BiliApplication
import BiliModels
import Foundation

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
public final class DanmakuPresentationController:
    DanmakuPresentationSink,
    DanmakuRenderingBackendDelegate
{
    public private(set) var statistics = DanmakuRendererStatistics()

    private let backend: any DanmakuRenderingBackend
    private let durations: DanmakuRendererDurations
    private var allocator: DanmakuLaneAllocator
    private var identity: PlaybackItemIdentity?
    private var discontinuityGeneration: UInt64?
    private var surfaceOwnerID: UUID?

    public init(
        backend: any DanmakuRenderingBackend,
        configuration: DanmakuLaneConfiguration,
        durations: DanmakuRendererDurations = DanmakuRendererDurations()
    ) {
        self.backend = backend
        self.allocator = DanmakuLaneAllocator(configuration: configuration)
        self.durations = durations
        backend.delegate = self
        backend.updateSurfaceSize(
            width: configuration.surfaceWidth,
            height: configuration.surfaceHeight
        )
    }

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

        let effectiveRate = update.snapshot.state == .playing
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
                durationSeconds: durations.duration(for: event.mode)
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

    public func stopPresentation() {
        _ = allocator.clear()
        backend.stop()
        identity = nil
        discontinuityGeneration = nil
        statistics.updateActive(0)
    }

    func updateConfiguration(
        _ configuration: DanmakuLaneConfiguration
    ) {
        _ = allocator.updateConfiguration(configuration)
        backend.updateSurfaceSize(
            width: configuration.surfaceWidth,
            height: configuration.surfaceHeight
        )
        statistics.updateActive(0)
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
        _ configuration: DanmakuLaneConfiguration,
        ownerID: UUID
    ) -> Bool {
        guard surfaceOwnerID == ownerID else { return false }
        updateConfiguration(configuration)
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
}
