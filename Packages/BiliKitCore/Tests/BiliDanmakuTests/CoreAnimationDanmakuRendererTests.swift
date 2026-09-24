import BiliApplication
import BiliModels
import Foundation
import Synchronization
import Testing

@testable import BiliDanmaku

@MainActor
@Suite
struct CoreAnimationDanmakuRendererTests {
    @Test
    func rendererAppliesUserOpacityAtRootAndReleasesTextureBytes() async throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 240)
        let fixture = fixtureEvent(
            id: "one-layer",
            mode: .scrolling,
            colorRGB: 0xD0E0F0
        )
        _ = try await prepareAndRender(
            renderer: renderer,
            event: fixture,
            preparationID: 1,
            originY: 20
        )
        let layer = try #require(renderer.rootLayer.sublayers?.first)
        let identity = try #require(
            renderer.objectIdentity(forEventID: fixture.id)
        )

        let opacity = try #require(DanmakuOpacity(0.35))
        renderer.setOpacity(opacity)
        #expect(abs(Double(renderer.rootLayer.opacity) - 0.35) < 0.001)
        #expect(layer.opacity == 1)
        #expect(
            renderer.objectIdentity(forEventID: fixture.id) == identity
        )
        #expect(renderer.activeTextureByteCost > 0)
        #expect(
            renderer.activeTextureByteCost
                <= CoreAnimationDanmakuRenderer.maximumActiveTextureByteCost
        )
        renderer.remove(eventID: fixture.id)
        #expect(renderer.activeTextureByteCost == 0)
    }

    @Test
    func preparationOwnerReusesCachedTextureUntilMemoryPressure() async throws {
        let counter = RasterizationCounter()
        let owner = DanmakuTexturePreparationOwner(
            rasterize: { counter.rasterize($0) }
        )
        let fixture = fixtureEvent(id: "cache", mode: .top)
        let key = try #require(
            DanmakuTextureRasterizer.key(
                event: fixture,
                backingScale: 2
            )
        )
        let ready = DanmakuPreparationResult.ready(
            DanmakuTextMetrics(width: 16, height: 1)
        )

        #expect(await prepare(owner: owner, event: fixture, preparationID: 1) == ready)
        #expect(owner.consume(preparationID: 1, generation: 0, expectedKey: key) != nil)
        #expect(await prepare(owner: owner, event: fixture, preparationID: 2) == ready)
        #expect(counter.count == 1)

        owner.handleMemoryPressure()
        #expect(owner.outstandingRequestCount == 0)
        #expect(owner.consume(preparationID: 2, generation: 0, expectedKey: key) == nil)
        #expect(await prepare(owner: owner, event: fixture, preparationID: 3) == ready)
        #expect(counter.count == 2)
    }

    @Test
    func preparationOwnerRejectsWorkBeyondItsHardOutstandingLimit() {
        let owner = DanmakuTexturePreparationOwner(
            configuration: .init(
                maximumConcurrentOperations: 1,
                maximumOutstandingRequests: 1,
                cacheLimits: .production
            ),
            rasterize: { _ in fixtureTexturePayload(byteCost: 64) }
        )
        var secondResult: DanmakuPreparationResult?
        owner.prepare(
            event: fixtureEvent(id: "bounded-first", mode: .scrolling),
            backingScale: 2,
            preparationID: 1,
            generation: 0
        ) { _ in }
        owner.prepare(
            event: fixtureEvent(id: "bounded-second", mode: .scrolling),
            backingScale: 2,
            preparationID: 2,
            generation: 0
        ) { result in
            secondResult = result
        }

        #expect(secondResult == .rejected(.capacity))
        #expect(owner.outstandingRequestCount == 1)
        owner.cancelAllPreparations()
        #expect(owner.outstandingRequestCount == 0)
    }

    @Test
    func staleAnimationCompletionCannotRemoveReplacement() async throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        let delegate = RecordingRendererDelegate()
        renderer.delegate = delegate
        renderer.updateSurfaceSize(width: 800, height: 200)
        let fixture = fixtureEvent(id: "reused", mode: .top)
        _ = try await prepareAndRender(
            renderer: renderer,
            event: fixture,
            preparationID: 1,
            originY: 10
        )
        let oldIdentity = try #require(
            renderer.objectIdentity(forEventID: fixture.id)
        )
        let oldEpoch = renderer.renderEpoch

        renderer.clearAll()
        _ = try await prepareAndRender(
            renderer: renderer,
            event: fixture,
            preparationID: 2,
            generation: 1,
            originY: 10
        )
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
    func stoppedPreparationOwnerAndRendererAreReleased() async throws {
        weak var weakRenderer: CoreAnimationDanmakuRenderer?
        do {
            let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
            weakRenderer = renderer
            renderer.updateSurfaceSize(width: 800, height: 300)
            _ = try await prepareAndRender(
                renderer: renderer,
                event: fixtureEvent(id: "release", mode: .scrolling),
                preparationID: 1,
                originY: 20
            )
            renderer.stop()
        }
        #expect(weakRenderer == nil)
    }

    @Test
    func invalidAndOversizedTextFailClosedBeforeLaneAdmission() async {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 300)
        let invalid = DanmakuEvent(
            id: "invalid",
            timeSeconds: 1,
            mode: .scrolling,
            text: "invalid",
            fontSize: .nan,
            colorRGB: 0xFFFFFF,
            weight: 1
        )
        let oversized = DanmakuEvent(
            id: "oversized",
            timeSeconds: 1,
            mode: .scrolling,
            text: String(repeating: "W", count: 512),
            fontSize: 36,
            colorRGB: 0xFFFFFF,
            weight: 1
        )

        #expect(
            await prepare(
                renderer: renderer,
                event: invalid,
                preparationID: 1
            ) == .rejected(.invalidInput)
        )
        #expect(
            await prepare(
                renderer: renderer,
                event: oversized,
                preparationID: 2
            ) == .rejected(.oversized)
        )
        #expect(renderer.activeLayerCount == 0)
        #expect(renderer.outstandingPreparationCount == 0)
    }

    private func prepareAndRender(
        renderer: CoreAnimationDanmakuRenderer,
        event: DanmakuEvent,
        preparationID: UInt64,
        generation: UInt64 = 0,
        originY: Double
    ) async throws -> DanmakuTextMetrics {
        let result = await prepare(
            renderer: renderer,
            event: event,
            preparationID: preparationID,
            generation: generation
        )
        guard case .ready(let metrics) = result else {
            Issue.record("texture preparation was rejected")
            return DanmakuTextMetrics(width: 0, height: 0)
        }
        let didRender = renderer.renderPrepared(
            placement(event: event, metrics: metrics, originY: originY),
            preparationID: preparationID,
            generation: generation
        )
        #expect(didRender)
        return metrics
    }

    private func prepare(
        renderer: CoreAnimationDanmakuRenderer,
        event: DanmakuEvent,
        preparationID: UInt64,
        generation: UInt64 = 0
    ) async -> DanmakuPreparationResult {
        await withCheckedContinuation { continuation in
            renderer.prepare(
                event,
                preparationID: preparationID,
                generation: generation,
                backingScale: 2
            ) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func prepare(
        owner: DanmakuTexturePreparationOwner,
        event: DanmakuEvent,
        preparationID: UInt64
    ) async -> DanmakuPreparationResult {
        await withCheckedContinuation { continuation in
            owner.prepare(
                event: event,
                backingScale: 2,
                preparationID: preparationID,
                generation: 0
            ) { result in
                continuation.resume(returning: result)
            }
        }
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
            surfaceWidthAtAdmission: 800,
            admittedAtSeconds: 1,
            expiresAtSeconds: 5
        )
    }
}

private final class RasterizationCounter: Sendable {
    private let value = Mutex(0)

    var count: Int { value.withLock { $0 } }

    func rasterize(_ key: DanmakuTextureCacheKey) -> DanmakuTexturePayload? {
        value.withLock { $0 += 1 }
        return fixtureTexturePayload(byteCost: 64)
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
