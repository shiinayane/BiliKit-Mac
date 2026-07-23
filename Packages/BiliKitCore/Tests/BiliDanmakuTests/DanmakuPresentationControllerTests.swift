import AppKit
import BiliApplication
@testable import BiliDanmaku
import BiliModels
import QuartzCore
import Testing

@MainActor
@Suite
struct DanmakuPresentationControllerTests {
    @Test
    func controllerRemovesExpiredBeforeRenderingNewAdmission() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 2),
            durations: DanmakuRendererDurations(
                scrollingSeconds: 1,
                fixedSeconds: 1
            )
        )
        let identity = PlaybackItemIdentity(bvid: "BV1OrderFixture", cid: 1)

        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [event(id: "first", mode: .top)]
            )
        )
        backend.operations.removeAll()

        controller.apply(
            update(
                identity: identity,
                position: 3,
                generation: 1,
                events: [event(id: "second", mode: .top)]
            )
        )

        #expect(
            backend.operations == [
                .rate(1),
                .remove("first"),
                .render("second"),
            ]
        )
        #expect(controller.statistics.active == 1)
    }

    @Test
    func capacityDropDoesNotCreateRendererObjectOrQueue() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 1)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1CapacityFixture", cid: 2)

        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [
                    event(id: "first", mode: .scrolling),
                    event(id: "second", mode: .scrolling),
                ]
            )
        )

        #expect(backend.renderedEventIDs == ["first"])
        #expect(controller.statistics.droppedCapacity == 1)
        #expect(controller.statistics.active == 1)
        #expect(controller.statistics.peakActive == 1)
    }

    @Test
    func burstWorkIsBoundedBeforeTextMeasurement() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 1)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1BurstFixture", cid: 20)
        let events = (0..<1_000).map {
            event(id: "event-\($0)", mode: .scrolling)
        }

        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: events
            )
        )

        #expect(
            backend.measureCount
                == DanmakuLaneConfiguration.hardMaximumActiveCount
        )
        #expect(controller.statistics.droppedCapacity >= 360)
        #expect(backend.renderedEventIDs.count == 1)
    }

    @Test
    func pauseRateGenerationAndStopRemainSingleSequenceCommands() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 4)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1LifecycleFixture", cid: 3)

        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 4,
                state: .paused,
                rate: 0
            )
        )
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 4,
                state: .playing,
                rate: 2
            )
        )
        controller.apply(
            update(
                identity: identity,
                position: 8,
                generation: 5,
                state: .playing,
                rate: 1
            )
        )
        controller.stopPresentation()
        controller.stopPresentation()

        #expect(backend.rates == [0, 2, 1])
        #expect(backend.clearCount == 2)
        #expect(backend.stopCount == 2)
        #expect(controller.statistics.active == 0)
    }

    @Test
    func mismatchedClearBatchCannotClearCurrentGeneration() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 4)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1OldClearFixture", cid: 30)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 8,
                events: [event(id: "current", mode: .top)]
            )
        )
        let clearCount = backend.clearCount
        let staleClear = DanmakuBatch(
            identity: identity,
            discontinuityGeneration: 7,
            events: [],
            clearsExisting: true
        )

        controller.apply(
            DanmakuPresentationUpdate(
                snapshot: PlaybackTimelineSnapshot(
                    identity: identity,
                    positionSeconds: 2,
                    durationSeconds: 100,
                    rate: 1,
                    state: .playing,
                    discontinuityGeneration: 8
                ),
                batch: staleClear
            )
        )

        #expect(backend.clearCount == clearCount)
        #expect(controller.statistics.active == 1)
    }

    @Test
    func surfaceLifecycleDrainsAllocatorAndStatistics() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 1)
        )
        let firstOwner = UUID()
        let replacementOwner = UUID()
        #expect(controller.attachSurface(ownerID: firstOwner))
        let identity = PlaybackItemIdentity(bvid: "BV1SurfaceFixture", cid: 31)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [event(id: "before-detach", mode: .top)]
            )
        )
        #expect(controller.statistics.active == 1)
        let clearCount = backend.clearCount

        #expect(controller.attachSurface(ownerID: replacementOwner))

        #expect(backend.clearCount == clearCount + 1)
        #expect(controller.statistics.active == 0)
        #expect(!controller.detachSurface(ownerID: firstOwner))
        #expect(backend.clearCount == clearCount + 1)

        #expect(
            !controller.updateSurface(
                zeroConfiguration(),
                ownerID: firstOwner
            )
        )
        #expect(
            controller.updateSurface(
                zeroConfiguration(),
                ownerID: replacementOwner
            )
        )
        #expect(
            backend.surfaceSizes.last
                == DanmakuTextMetrics(width: 0, height: 0)
        )
        #expect(
            controller.updateSurface(
                configuration(maximumActiveCount: 1),
                ownerID: replacementOwner
            )
        )
        controller.apply(
            update(
                identity: identity,
                position: 2,
                generation: 1,
                events: [event(id: "after-attach", mode: .top)]
            )
        )
        #expect(backend.renderedEventIDs.last == "after-attach")
        #expect(controller.statistics.active == 1)
    }

    @Test
    func coreAnimationStyleUsesHeavyInkWithoutCompositorShadow() throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 200)
        let fixture = event(id: "style", mode: .scrolling)
        let metrics = renderer.measure(fixture)
        renderer.render(
            placement(
                event: fixture,
                metrics: metrics,
                originY: 20
            )
        )

        let layer = try #require(renderer.textLayer(forEventID: fixture.id))
        let attributed = try #require(layer.string as? NSAttributedString)
        let shadow = try #require(
            attributed.attribute(
                .shadow,
                at: 0,
                effectiveRange: nil
            ) as? NSShadow
        )

        #expect(layer.shadowOpacity == 0)
        #expect(shadow.shadowBlurRadius == 1.5)
        #expect(shadow.shadowOffset == .zero)
        #expect(renderer.activeLayerCount == 1)
    }

    @Test
    func staleCompletionCannotRemoveReplacementWithSameEventID() throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        let delegate = RecordingRendererDelegate()
        renderer.delegate = delegate
        renderer.updateSurfaceSize(width: 800, height: 200)
        let fixture = event(id: "reused", mode: .top)
        let metrics = renderer.measure(fixture)
        let fixturePlacement = placement(
            event: fixture,
            metrics: metrics,
            originY: 10
        )
        renderer.render(fixturePlacement)
        let oldIdentity = try #require(
            renderer.objectIdentity(forEventID: fixture.id)
        )
        let oldEpoch = renderer.renderEpoch

        renderer.clearAll()
        renderer.render(fixturePlacement)
        let newIdentity = try #require(
            renderer.objectIdentity(forEventID: fixture.id)
        )
        let newEpoch = renderer.renderEpoch

        renderer.completeAnimation(
            eventID: fixture.id,
            objectIdentity: oldIdentity,
            renderEpoch: oldEpoch
        )
        #expect(renderer.activeLayerCount == 1)
        #expect(delegate.finishedEventIDs.isEmpty)

        renderer.completeAnimation(
            eventID: fixture.id,
            objectIdentity: newIdentity,
            renderEpoch: newEpoch
        )
        #expect(renderer.activeLayerCount == 0)
        #expect(delegate.finishedEventIDs == [fixture.id])
    }

    @Test
    func concreteRendererCoversThreeModesRateAndLifecycleEpochs() throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 300)
        let scrolling = event(id: "scroll", mode: .scrolling)
        let top = event(id: "top", mode: .top)
        let bottom = event(id: "bottom", mode: .bottom)

        for (fixture, originY) in [
            (scrolling, 60.0),
            (top, 0.0),
            (bottom, 240.0),
        ] {
            let metrics = renderer.measure(fixture)
            renderer.render(
                placement(
                    event: fixture,
                    metrics: metrics,
                    originY: originY
                )
            )
        }

        let scrollingAnimation = try #require(
            renderer.textLayer(forEventID: scrolling.id)?
                .animation(forKey: "danmaku") as? CABasicAnimation
        )
        let topAnimation = try #require(
            renderer.textLayer(forEventID: top.id)?
                .animation(forKey: "danmaku") as? CABasicAnimation
        )
        let bottomAnimation = try #require(
            renderer.textLayer(forEventID: bottom.id)?
                .animation(forKey: "danmaku") as? CABasicAnimation
        )
        #expect(scrollingAnimation.keyPath == "position.x")
        #expect(topAnimation.keyPath == "opacity")
        #expect(bottomAnimation.keyPath == "opacity")

        renderer.setPlaybackRate(0)
        #expect(renderer.rootLayer.speed == 0)
        renderer.setPlaybackRate(0.5)
        #expect(renderer.rootLayer.speed == 0.5)
        renderer.setPlaybackRate(2)
        #expect(renderer.rootLayer.speed == 2)

        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: configuration(maximumActiveCount: 640)
        )
        let surfaceOwner = UUID()
        controller.attachSurface(ownerID: surfaceOwner)
        let beforeDetach = renderer.renderEpoch
        controller.detachSurface(ownerID: surfaceOwner)
        #expect(renderer.renderEpoch == beforeDetach + 1)
        #expect(renderer.activeLayerCount == 0)
        #expect(renderer.rootLayer.sublayers?.isEmpty != false)

        controller.attachSurface(ownerID: surfaceOwner)
        let beforeStop = renderer.renderEpoch
        controller.stopPresentation()
        controller.stopPresentation()
        #expect(renderer.renderEpoch == beforeStop + 2)
        #expect(renderer.activeLayerCount == 0)
        #expect(renderer.rootLayer.speed == 0)
    }

    @Test
    func oversizedTextFailsClosedBeforeLayerCreation() {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 300)
        let oversized = DanmakuEvent(
            id: "oversized",
            timeSeconds: 1,
            mode: .scrolling,
            text: String(repeating: "W", count: 4_096),
            fontSize: 24,
            colorRGB: 0xFFFFFF,
            weight: 1
        )

        let metrics = renderer.measure(oversized)

        #expect(metrics == DanmakuTextMetrics(width: 0, height: 0))
        #expect(renderer.activeLayerCount == 0)
    }

    @Test
    func backendHardCapRejectsObjectSixHundredFortyOne() {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 1)
        renderer.updateSurfaceSize(width: 800, height: 300)
        let metrics = DanmakuTextMetrics(width: 40, height: 24)

        for index in 0...DanmakuLaneConfiguration.hardMaximumActiveCount {
            let fixture = DanmakuEvent(
                id: "direct-\(index)",
                timeSeconds: 1,
                mode: .top,
                text: "A",
                fontSize: 24,
                colorRGB: 0xFFFFFF,
                weight: 1
            )
            renderer.render(
                placement(
                    event: fixture,
                    metrics: metrics,
                    originY: 0
                )
            )
        }

        #expect(
            renderer.activeLayerCount
                == DanmakuLaneConfiguration.hardMaximumActiveCount
        )
        renderer.stop()
        #expect(renderer.activeLayerCount == 0)
    }

    @Test
    func stoppedOwnerAndRendererAreReleased() {
        weak var weakRenderer: CoreAnimationDanmakuRenderer?
        weak var weakController: DanmakuPresentationController?

        do {
            let renderer = CoreAnimationDanmakuRenderer(contentsScale: 1)
            let controller = DanmakuPresentationController(
                backend: renderer,
                configuration: configuration(maximumActiveCount: 4)
            )
            weakRenderer = renderer
            weakController = controller
            let fixture = event(id: "active", mode: .scrolling)
            let metrics = renderer.measure(fixture)
            renderer.render(
                placement(
                    event: fixture,
                    metrics: metrics,
                    originY: 60
                )
            )
            #expect(renderer.activeLayerCount == 1)
            controller.stopPresentation()
            #expect(renderer.activeLayerCount == 0)
        }

        #expect(weakController == nil)
        #expect(weakRenderer == nil)
    }

    private func configuration(
        maximumActiveCount: Int
    ) -> DanmakuLaneConfiguration {
        DanmakuLaneConfiguration(
            surfaceWidth: 800,
            surfaceHeight: 300,
            laneHeight: 30,
            minimumHorizontalGap: 12,
            maximumActiveCount: maximumActiveCount,
            displayAreaFraction: 1
        )
    }

    private func zeroConfiguration() -> DanmakuLaneConfiguration {
        DanmakuLaneConfiguration(
            surfaceWidth: 0,
            surfaceHeight: 0,
            laneHeight: 36,
            minimumHorizontalGap: 12,
            maximumActiveCount: 1,
            displayAreaFraction: 1
        )
    }

    private func update(
        identity: PlaybackItemIdentity,
        position: Double,
        generation: UInt64,
        state: PlaybackTimelineState = .playing,
        rate: Double = 1,
        events: [DanmakuEvent] = []
    ) -> DanmakuPresentationUpdate {
        let snapshot = PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 100,
            rate: rate,
            state: state,
            discontinuityGeneration: generation
        )
        let batch = events.isEmpty ? nil : DanmakuBatch(
            identity: identity,
            discontinuityGeneration: generation,
            events: events,
            clearsExisting: false
        )
        return DanmakuPresentationUpdate(snapshot: snapshot, batch: batch)
    }

    private func event(
        id: String,
        mode: DanmakuPresentationMode
    ) -> DanmakuEvent {
        DanmakuEvent(
            id: id,
            timeSeconds: 1,
            mode: mode,
            text: "中文 日本語 한국어 Latin 😀 #",
            fontSize: 24,
            colorRGB: 0xFFFFFF,
            weight: 1
        )
    }

    private func placement(
        event: DanmakuEvent,
        metrics: DanmakuTextMetrics,
        originY: Double
    ) -> DanmakuLanePlacement {
        DanmakuLanePlacement(
            request: DanmakuLaneRequest(
                event: event,
                width: metrics.width,
                height: metrics.height,
                durationSeconds: 4
            ),
            laneIndex: 0,
            originY: originY,
            admittedAtSeconds: 1,
            expiresAtSeconds: 5
        )
    }
}

@MainActor
private final class RecordingRenderingBackend: DanmakuRenderingBackend {
    enum Operation: Equatable {
        case rate(Double)
        case remove(String)
        case render(String)
    }

    weak var delegate: (any DanmakuRenderingBackendDelegate)?
    var operations: [Operation] = []
    private(set) var renderedEventIDs: [String] = []
    private(set) var rates: [Double] = []
    private(set) var clearCount = 0
    private(set) var stopCount = 0
    private(set) var measureCount = 0
    private(set) var surfaceSizes: [DanmakuTextMetrics] = []

    func measure(_ event: DanmakuEvent) -> DanmakuTextMetrics {
        measureCount += 1
        return DanmakuTextMetrics(width: 120, height: 24)
    }

    func render(_ placement: DanmakuLanePlacement) {
        let eventID = placement.request.event.id
        operations.append(.render(eventID))
        renderedEventIDs.append(eventID)
    }

    func remove(eventID: String) {
        operations.append(.remove(eventID))
    }

    func clearAll() {
        clearCount += 1
    }

    func setPlaybackRate(_ rate: Double) {
        operations.append(.rate(rate))
        rates.append(rate)
    }

    func updateSurfaceSize(width: Double, height: Double) {
        surfaceSizes.append(
            DanmakuTextMetrics(width: width, height: height)
        )
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class RecordingRendererDelegate:
    DanmakuRenderingBackendDelegate
{
    private(set) var finishedEventIDs: [String] = []

    func rendererDidFinish(eventID: String) {
        finishedEventIDs.append(eventID)
    }
}
