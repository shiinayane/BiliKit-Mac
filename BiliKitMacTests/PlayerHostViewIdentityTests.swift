import AVKit
import AppKit
import BiliApplication
import BiliDanmaku
import BiliModels
import Observation
import SwiftUI
import Testing

@testable import BiliKit

@Suite(.serialized)
struct PlayerHostViewIdentityTests {
    @Test
    @MainActor
    func danmakuSurfaceSurvivesTemporaryWindowReparenting() throws {
        let renderer = CoreAnimationDanmakuRenderer()
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: Self.emptyDanmakuConfiguration
        )
        let overlay = DanmakuOverlayView(
            renderer: renderer,
            controller: controller
        )
        overlay.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let firstWindow = NSWindow(
            contentRect: overlay.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        firstWindow.contentView?.addSubview(overlay)
        overlay.layoutSubtreeIfNeeded()
        #expect(renderer.rootLayer.superlayer === overlay.layer)

        let identity = PlaybackItemIdentity(bvid: "fixture", cid: 1)
        controller.apply(
            danmakuUpdate(
                identity: identity,
                position: 1,
                eventID: "before-reparent",
                mode: .scrolling
            )
        )
        let firstLayer = try #require(renderer.rootLayer.sublayers?.first)
        let epoch = renderer.renderEpoch
        #expect(renderer.activeLayerCount == 1)
        #expect(controller.statistics.active == 1)

        overlay.removeFromSuperview()
        #expect(overlay.window == nil)
        #expect(renderer.rootLayer.superlayer === overlay.layer)
        #expect(renderer.rootLayer.sublayers?.first === firstLayer)
        #expect(renderer.renderEpoch == epoch)
        #expect(renderer.activeLayerCount == 1)

        overlay.frame = .zero
        overlay.layoutSubtreeIfNeeded()
        controller.apply(
            danmakuUpdate(
                identity: identity,
                position: 2,
                eventID: "during-reparent",
                mode: .top
            )
        )
        #expect(renderer.activeLayerCount == 2)
        #expect(controller.statistics.active == 2)

        overlay.frame = secondWindow.contentView?.bounds ?? .zero
        secondWindow.contentView?.addSubview(overlay)
        overlay.layoutSubtreeIfNeeded()
        #expect(renderer.rootLayer.superlayer === overlay.layer)
        #expect(renderer.rootLayer.sublayers?.first === firstLayer)
        #expect(renderer.renderEpoch == epoch)
        #expect(renderer.activeLayerCount == 2)

        overlay.detachSurface()
        #expect(renderer.rootLayer.superlayer == nil)
        #expect(renderer.renderEpoch == epoch + 1)
        #expect(renderer.activeLayerCount == 0)
        #expect(controller.statistics.active == 0)
    }

    private func danmakuUpdate(
        identity: PlaybackItemIdentity,
        position: Double,
        eventID: String,
        mode: DanmakuPresentationMode
    ) -> DanmakuPresentationUpdate {
        let event = DanmakuEvent(
            id: eventID,
            timeSeconds: position,
            mode: mode,
            text: "reparent fixture",
            fontSize: 24,
            colorRGB: 0xFFFFFF,
            weight: 1
        )
        return DanmakuPresentationUpdate(
            snapshot: PlaybackTimelineSnapshot(
                identity: identity,
                positionSeconds: position,
                durationSeconds: 100,
                rate: 1,
                state: .playing,
                discontinuityGeneration: 1
            ),
            batch: DanmakuBatch(
                identity: identity,
                discontinuityGeneration: 1,
                events: [event],
                clearsExisting: false
            )
        )
    }

    @Test
    @MainActor
    func playerSurfaceCaptureRoutesVerticalWheelWithoutLocalMonitor()
        throws
    {
        let scrollView = ScrollWheelRecordingScrollView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let documentView = NSView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 1_200)
        )
        let playerView = AVPlayerView(
            frame: NSRect(x: 0, y: 900, width: 800, height: 300)
        )
        let scrollCaptureView = PlayerScrollWheelCaptureView(
            frame: playerView.bounds
        )
        scrollView.documentView = documentView
        documentView.addSubview(playerView)
        playerView.addSubview(scrollCaptureView)

        let event = try makeScrollWheelEvent(deltaX: 0, deltaY: -80)
        #expect(event.hasPreciseScrollingDeltas)

        scrollCaptureView.scrollWheel(with: event)

        #expect(scrollView.receivedScrollWheelEvents.count == 1)
        #expect(scrollView.receivedScrollWheelEvents.first === event)

        var shieldPlayerEvents: [NSEvent] = []
        let shieldCapture = PlayerScrollWheelSurfaceCapture(
            anchorView: NSView(frame: .zero),
            dispatchToPlayer: { shieldPlayerEvents.append($0) }
        )
        let horizontalEvent = try makeScrollWheelEvent(
            deltaX: -80,
            deltaY: 0
        )
        shieldCapture.handleScrollWheel(
            horizontalEvent,
            playerFallbackPolicy: .consume
        )
        #expect(shieldPlayerEvents.isEmpty)

        var overlayPlayerEvents: [NSEvent] = []
        let overlayCapture = PlayerScrollWheelSurfaceCapture(
            anchorView: NSView(frame: .zero),
            dispatchToPlayer: { overlayPlayerEvents.append($0) }
        )
        overlayCapture.handleScrollWheel(horizontalEvent)
        #expect(overlayPlayerEvents.count == 1)
        #expect(overlayPlayerEvents.first === horizontalEvent)

        var alternatingPlayerEvents: [NSEvent] = []
        let alternatingCapture = PlayerScrollWheelSurfaceCapture(
            anchorView: NSView(frame: .zero),
            dispatchToPlayer: { alternatingPlayerEvents.append($0) }
        )
        let pendingShieldEvent = try makeScrollWheelEvent(
            deltaX: 1,
            deltaY: 1,
            phase: .began
        )
        let resolvingOverlayEvent = try makeScrollWheelEvent(
            deltaX: -80,
            deltaY: 0,
            phase: .changed
        )
        alternatingCapture.handleScrollWheel(
            pendingShieldEvent,
            playerFallbackPolicy: .consume
        )
        alternatingCapture.handleScrollWheel(
            resolvingOverlayEvent,
            playerFallbackPolicy: .dispatchToPlayer
        )
        #expect(alternatingPlayerEvents.isEmpty)

        var crossingPlayerEvents: [NSEvent] = []
        let crossingCapture = PlayerScrollWheelSurfaceCapture(
            anchorView: NSView(frame: .zero),
            dispatchToPlayer: { crossingPlayerEvents.append($0) }
        )
        let mayBeginShieldEvent = try makeScrollWheelEvent(
            deltaX: -80,
            deltaY: 0,
            phase: .mayBegin
        )
        let beganOverlayEvent = try makeScrollWheelEvent(
            deltaX: 1,
            deltaY: 1,
            phase: .began
        )
        let followingOverlayEvent = try makeScrollWheelEvent(
            deltaX: -20,
            deltaY: 0,
            phase: .changed
        )
        crossingCapture.handleScrollWheel(
            mayBeginShieldEvent,
            playerFallbackPolicy: .consume
        )
        crossingCapture.handleScrollWheel(
            beganOverlayEvent,
            playerFallbackPolicy: .dispatchToPlayer
        )
        crossingCapture.handleScrollWheel(
            resolvingOverlayEvent,
            playerFallbackPolicy: .dispatchToPlayer
        )
        crossingCapture.handleScrollWheel(
            followingOverlayEvent,
            playerFallbackPolicy: .dispatchToPlayer
        )
        #expect(crossingPlayerEvents.isEmpty)

        var reversePlayerEvents: [NSEvent] = []
        let reverseCapture = PlayerScrollWheelSurfaceCapture(
            anchorView: NSView(frame: .zero),
            dispatchToPlayer: { reversePlayerEvents.append($0) }
        )
        reverseCapture.handleScrollWheel(
            pendingShieldEvent,
            playerFallbackPolicy: .dispatchToPlayer
        )
        reverseCapture.handleScrollWheel(
            resolvingOverlayEvent,
            playerFallbackPolicy: .consume
        )
        #expect(reversePlayerEvents.count == 2)
        #expect(reversePlayerEvents[0] === pendingShieldEvent)
        #expect(reversePlayerEvents[1] === resolvingOverlayEvent)

        var momentumPlayerEvents: [NSEvent] = []
        let momentumCapture = PlayerScrollWheelSurfaceCapture(
            anchorView: NSView(frame: .zero),
            dispatchToPlayer: { momentumPlayerEvents.append($0) }
        )
        let overlayMomentumEvent = try makeScrollWheelEvent(
            deltaX: -80,
            deltaY: 0,
            momentumPhase: .began
        )
        momentumCapture.handleScrollWheel(
            pendingShieldEvent,
            playerFallbackPolicy: .consume
        )
        momentumCapture.handleScrollWheel(
            overlayMomentumEvent,
            playerFallbackPolicy: .dispatchToPlayer
        )
        #expect(momentumPlayerEvents.isEmpty)

        let pointerExitCapture = PlayerScrollWheelSurfaceCapture(
            anchorView: scrollCaptureView
        )
        pointerExitCapture.handleScrollWheel(
            pendingShieldEvent,
            playerFallbackPolicy: .consume
        )
        pointerExitCapture.resetInputSessionForPointerExit()
        let orphanedVerticalEvent = try makeScrollWheelEvent(
            deltaX: 1,
            deltaY: -12,
            phase: .changed
        )
        pointerExitCapture.handleScrollWheel(
            orphanedVerticalEvent,
            playerFallbackPolicy: .consume
        )
        #expect(scrollView.receivedScrollWheelEvents.count == 2)
        #expect(
            scrollView.receivedScrollWheelEvents.last
                === orphanedVerticalEvent
        )

        let quarantineCapture = PlayerScrollWheelSurfaceCapture(
            anchorView: scrollCaptureView
        )
        quarantineCapture.cancelInputSession()
        quarantineCapture.resetInputSessionForPointerExit()
        quarantineCapture.handleScrollWheel(
            orphanedVerticalEvent,
            playerFallbackPolicy: .consume
        )
        #expect(scrollView.receivedScrollWheelEvents.count == 2)

        let newVerticalGestureEvent = try makeScrollWheelEvent(
            deltaX: 1,
            deltaY: -12,
            phase: .began
        )
        quarantineCapture.handleScrollWheel(
            newVerticalGestureEvent,
            playerFallbackPolicy: .consume
        )
        #expect(scrollView.receivedScrollWheelEvents.count == 3)
        #expect(
            scrollView.receivedScrollWheelEvents.last
                === newVerticalGestureEvent
        )
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func playerHostInstallsSurfaceCaptureInScrollableDetailHierarchy()
        async throws
    {
        let renderer = CoreAnimationDanmakuRenderer()
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: Self.emptyDanmakuConfiguration
        )
        let hostingView = NSHostingView(
            rootView: PlayerHostScrollRoutingHarness(
                player: AVPlayer(),
                renderer: renderer,
                controller: controller
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = NSView()
        }
        hostingView.layoutSubtreeIfNeeded()

        #expect(
            await waitUntil(in: hostingView) {
                self.firstView(
                    ofType: AVPlayerView.self,
                    in: hostingView
                ) != nil
            },
            "AVPlayerView 应在已进入 Window Server 生命周期的测试窗口中完成挂载"
        )
        let playerView = try #require(
            firstView(
                ofType: AVPlayerView.self,
                in: hostingView
            )
        )
        #expect(playerView.showsFullScreenToggleButton)
        #expect(playerView.allowsPictureInPicturePlayback)
        let scrollCaptureView = try #require(
            firstView(
                ofType: PlayerScrollWheelCaptureView.self,
                in: playerView
            )
        )
        #expect(scrollCaptureView.superview === playerView.contentOverlayView)
        let scrollShieldView = try #require(
            firstView(
                ofType: PlayerScrollWheelShieldView.self,
                in: hostingView
            )
        )
        #expect(scrollShieldView.superview === playerView)
        let playerSurfaceSubviews = playerView.subviews
        let shieldIndex = try #require(
            playerSurfaceSubviews.firstIndex { $0 === scrollShieldView }
        )
        #expect(shieldIndex == playerSurfaceSubviews.indices.last)
        #expect(!scrollShieldView.isAccessibilityElement())
        let lateAVKitSibling = NSView(frame: playerView.bounds)
        playerView.addSubview(
            lateAVKitSibling,
            positioned: .above,
            relativeTo: scrollShieldView
        )
        playerView.needsLayout = true
        playerView.layoutSubtreeIfNeeded()
        #expect(playerView.subviews.last === scrollShieldView)

        scrollShieldView.removeFromSuperview()
        playerView.setFrameSize(
            NSSize(
                width: playerView.bounds.width - 80,
                height: playerView.bounds.height - 40
            )
        )
        playerView.needsLayout = true
        playerView.layoutSubtreeIfNeeded()
        #expect(scrollShieldView.superview === playerView)
        #expect(playerView.subviews.last === scrollShieldView)
        #expect(scrollShieldView.frame == playerView.bounds)
        let danmakuOverlay = try #require(
            firstView(
                ofType: DanmakuOverlayView.self,
                in: playerView
            )
        )
        let overlaySubviews = try #require(
            playerView.contentOverlayView?.subviews
        )
        let danmakuIndex = try #require(
            overlaySubviews.firstIndex { $0 === danmakuOverlay }
        )
        let captureIndex = try #require(
            overlaySubviews.firstIndex { $0 === scrollCaptureView }
        )
        #expect(captureIndex > danmakuIndex)
        #expect(!scrollCaptureView.isAccessibilityElement())
        let scrollView = try #require(
            firstAncestor(ofType: NSScrollView.self, from: playerView)
        )
        #expect(
            await waitUntil(in: hostingView) {
                guard let documentView = scrollView.documentView else {
                    return false
                }
                return documentView.bounds.height
                    > scrollView.contentView.bounds.height
            },
            "详情滚动文档应完成布局并大于可见区域"
        )
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func windowShieldForwardsVerticalWheelThroughHostCoordinator()
        async throws
    {
        let renderer = CoreAnimationDanmakuRenderer()
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: Self.emptyDanmakuConfiguration
        )
        let hostingView = NSHostingView(
            rootView: PlayerHostView(
                player: AVPlayer(),
                danmakuRenderer: renderer,
                danmakuController: controller
            )
            .frame(width: 800, height: 300)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let scrollView = ScrollWheelRecordingScrollView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 300)
        )
        scrollView.documentView = hostingView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = NSView()
        }
        hostingView.layoutSubtreeIfNeeded()

        #expect(
            await waitUntil(in: hostingView) {
                self.firstView(
                    ofType: PlayerScrollWheelShieldView.self,
                    in: hostingView
                ) != nil
            },
            "普通窗口 shield 应随真实 PlayerHostView 完成挂载"
        )
        let shield = try #require(
            firstView(
                ofType: PlayerScrollWheelShieldView.self,
                in: hostingView
            )
        )
        let event = try makeScrollWheelEvent(deltaX: 0, deltaY: -80)
        shield.scrollWheel(with: event)

        #expect(scrollView.receivedScrollWheelEvents.count == 1)
        #expect(scrollView.receivedScrollWheelEvents.first === event)

        let lockedHorizontalEvent = try makeScrollWheelEvent(
            deltaX: -12,
            deltaY: 1,
            phase: .began
        )
        shield.scrollWheel(with: lockedHorizontalEvent)
        #expect(scrollView.receivedScrollWheelEvents.count == 1)

        shield.handlePointerExit()

        let orphanedVerticalEvent = try makeScrollWheelEvent(
            deltaX: 1,
            deltaY: -12,
            phase: .changed
        )
        shield.scrollWheel(with: orphanedVerticalEvent)
        #expect(scrollView.receivedScrollWheelEvents.count == 2)
        #expect(
            scrollView.receivedScrollWheelEvents.last
                === orphanedVerticalEvent
        )
    }

    @Test
    @MainActor
    func contentOverlayCaptureOnlyParticipatesInScrollWheelHitTesting() throws {
        #expect(
            PlayerScrollWheelCaptureView.capturesEvent(
                ofType: .scrollWheel
            )
        )
        #expect(
            !PlayerScrollWheelCaptureView.capturesEvent(
                ofType: .leftMouseDown
            )
        )
        #expect(
            !PlayerScrollWheelCaptureView.capturesEvent(
                ofType: .magnify
            )
        )
        #expect(!PlayerScrollWheelCaptureView.capturesEvent(ofType: nil))
        #expect(
            PlayerScrollWheelShieldView.capturesEvent(
                ofType: .scrollWheel,
                isPrecise: true
            )
        )
        #expect(
            !PlayerScrollWheelShieldView.capturesEvent(
                ofType: .scrollWheel,
                isPrecise: false
            )
        )
        let shield = PlayerScrollWheelShieldView(frame: .zero)
        var pointerExitCount = 0
        shield.onPointerExited = { pointerExitCount += 1 }
        shield.handlePointerExit()
        #expect(pointerExitCount == 1)
        #expect(
            !PlayerScrollWheelShieldView.capturesEvent(
                ofType: .leftMouseDown,
                isPrecise: true
            )
        )
        #expect(
            !PlayerScrollWheelShieldView.capturesEvent(
                ofType: .magnify,
                isPrecise: true
            )
        )
        #expect(
            !PlayerScrollWheelShieldView.capturesEvent(
                ofType: nil,
                isPrecise: true
            )
        )
        let mouseMoveEvent = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )
        #expect(
            !PlayerScrollWheelShieldView.capturesEvent(
                try #require(mouseMoveEvent)
            )
        )
    }

    @Test
    @MainActor
    func contentOverlayCaptureOwnsExactlyOneMomentaryRateBadge() {
        let capture = PlayerScrollWheelCaptureView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 450)
        )

        #expect(!capture.hasMomentaryRateBadge)
        capture.showMomentaryRateBadge(.fast)
        #expect(capture.hasMomentaryRateBadge)
        #expect(capture.subviews.count == 1)

        capture.showMomentaryRateBadge(.slow)
        #expect(capture.hasMomentaryRateBadge)
        #expect(capture.subviews.count == 1)

        capture.clearMomentaryRateBadge()
        #expect(!capture.hasMomentaryRateBadge)
        #expect(capture.subviews.isEmpty)
    }

    @Test
    @MainActor
    func scrollWheelRouterLocksDominantAxisThroughMomentum() {
        var verticalRouter = PlayerScrollWheelRouter()
        #expect(
            verticalRouter.route(
                deltaX: 2,
                deltaY: -12,
                phase: .began,
                momentumPhase: []
            ) == .outerScroll
        )

        var boundaryRouter = PlayerScrollWheelRouter()
        #expect(
            boundaryRouter.route(
                deltaX: 1,
                deltaY: -12,
                phase: .changed,
                momentumPhase: [],
                adoptsOrphanedVerticalGesture: true
            ) == .outerScroll
        )
        #expect(
            boundaryRouter.route(
                deltaX: -20,
                deltaY: -1,
                phase: .changed,
                momentumPhase: [],
                adoptsOrphanedVerticalGesture: true
            ) == .outerScroll
        )
        var orphanedHorizontalRouter = PlayerScrollWheelRouter()
        #expect(
            orphanedHorizontalRouter.route(
                deltaX: -12,
                deltaY: 1,
                phase: .changed,
                momentumPhase: [],
                allowsMomentaryRate: true,
                adoptsOrphanedVerticalGesture: true
            ) == .player
        )
        var orphanedNoiseRouter = PlayerScrollWheelRouter()
        #expect(
            orphanedNoiseRouter.route(
                deltaX: 0.1,
                deltaY: 0.2,
                phase: .changed,
                momentumPhase: [],
                adoptsOrphanedVerticalGesture: true
            ) == .player
        )
        #expect(
            orphanedNoiseRouter.route(
                deltaX: 1,
                deltaY: -12,
                phase: .changed,
                momentumPhase: [],
                adoptsOrphanedVerticalGesture: true
            ) == .outerScroll
        )
        #expect(
            verticalRouter.route(
                deltaX: -20,
                deltaY: -1,
                phase: .changed,
                momentumPhase: []
            ) == .outerScroll
        )
        #expect(
            verticalRouter.route(
                deltaX: 0,
                deltaY: 0,
                phase: .ended,
                momentumPhase: []
            ) == .outerScroll
        )
        #expect(
            verticalRouter.route(
                deltaX: -8,
                deltaY: -1,
                phase: [],
                momentumPhase: .began
            ) == .outerScroll
        )
        #expect(
            verticalRouter.route(
                deltaX: 0,
                deltaY: 0,
                phase: [],
                momentumPhase: .ended
            ) == .outerScroll
        )

        var horizontalRouter = PlayerScrollWheelRouter()
        #expect(
            horizontalRouter.route(
                deltaX: -12,
                deltaY: -2,
                phase: .began,
                momentumPhase: []
            ) == .player
        )
        #expect(
            horizontalRouter.route(
                deltaX: -1,
                deltaY: -20,
                phase: .changed,
                momentumPhase: []
            ) == .player
        )
        #expect(
            horizontalRouter.route(
                deltaX: 0,
                deltaY: 0,
                phase: .ended,
                momentumPhase: []
            ) == .player
        )
        #expect(
            horizontalRouter.route(
                deltaX: -1,
                deltaY: -8,
                phase: [],
                momentumPhase: .ended
            ) == .player
        )
    }

    @Test
    @MainActor
    func scrollWheelRouterWaitsPastInitialNoiseBeforeLockingAxis() {
        var verticalRouter = PlayerScrollWheelRouter()
        #expect(
            verticalRouter.route(
                deltaX: 0.2,
                deltaY: 0.1,
                phase: .began,
                momentumPhase: []
            ) == .pending
        )
        #expect(
            verticalRouter.route(
                deltaX: 0.2,
                deltaY: 12,
                phase: .changed,
                momentumPhase: []
            ) == .outerScroll
        )

        var horizontalRouter = PlayerScrollWheelRouter()
        #expect(
            horizontalRouter.route(
                deltaX: 0.1,
                deltaY: 0.2,
                phase: .mayBegin,
                momentumPhase: []
            ) == .pending
        )
        #expect(
            horizontalRouter.route(
                deltaX: 12,
                deltaY: 0.2,
                phase: .changed,
                momentumPhase: []
            ) == .player
        )

        var ambiguousRouter = PlayerScrollWheelRouter()
        #expect(
            ambiguousRouter.route(
                deltaX: 1,
                deltaY: 1,
                phase: .began,
                momentumPhase: []
            ) == .pending
        )
        #expect(
            ambiguousRouter.route(
                deltaX: 0,
                deltaY: 0,
                phase: .cancelled,
                momentumPhase: []
            ) == .player
        )
    }

    @Test
    @MainActor
    func unphasedScrollWheelUsesStrictDominantAxis() {
        var router = PlayerScrollWheelRouter()
        #expect(
            router.route(
                deltaX: 0,
                deltaY: -1,
                phase: [],
                momentumPhase: []
            ) == .outerScroll
        )
        #expect(
            router.route(
                deltaX: -4,
                deltaY: -9,
                phase: [],
                momentumPhase: []
            ) == .outerScroll
        )
        #expect(
            router.route(
                deltaX: -9,
                deltaY: -4,
                phase: [],
                momentumPhase: []
            ) == .player
        )
        #expect(
            router.route(
                deltaX: -5,
                deltaY: -5,
                phase: [],
                momentumPhase: []
            ) == .player
        )
        #expect(
            router.route(
                deltaX: 0,
                deltaY: 0,
                phase: [],
                momentumPhase: []
            ) == .player
        )
        #expect(
            router.route(
                deltaX: 0,
                deltaY: -1,
                phase: .began,
                momentumPhase: [],
                isPrecise: false
            ) == .outerScroll
        )
        #expect(
            router.route(
                deltaX: -20,
                deltaY: -1,
                phase: .changed,
                momentumPhase: [],
                isPrecise: false
            ) == .outerScroll
        )
        #expect(
            router.route(
                deltaX: 0,
                deltaY: 0,
                phase: .ended,
                momentumPhase: [],
                isPrecise: false
            ) == .outerScroll
        )
        #expect(
            router.route(
                deltaX: -8,
                deltaY: -1,
                phase: [],
                momentumPhase: .ended,
                isPrecise: false
            ) == .outerScroll
        )
    }

    @Test
    func momentaryRateBadgeUsesNativeSymbolsAndRequestedLabels() {
        #expect(PlayerMomentaryRate.fast.label == "2X")
        #expect(PlayerMomentaryRate.fast.symbolName == "forward.fill")
        #expect(PlayerMomentaryRate.slow.label == "0.5X")
        #expect(PlayerMomentaryRate.slow.symbolName == "backward.fill")
    }

    @Test
    func ordinaryBufferingDoesNotCancelTheScrollInputSession() {
        #expect(
            !PlayerMomentaryRateSessionPolicy.shouldCancel(
                hasActiveSession: false,
                timeControlStatus: .paused
            )
        )
        #expect(
            PlayerMomentaryRateSessionPolicy.shouldCancel(
                hasActiveSession: true,
                timeControlStatus: .paused
            )
        )
        #expect(
            !PlayerMomentaryRateSessionPolicy.shouldCancel(
                hasActiveSession: true,
                timeControlStatus: .waitingToPlayAtSpecifiedRate
            )
        )
        #expect(
            !PlayerMomentaryRateSessionPolicy.shouldCancel(
                hasActiveSession: true,
                timeControlStatus: .playing
            )
        )
    }

    @Test
    @MainActor
    func preciseHorizontalGestureCanReserveWholeSequenceForMomentaryRate() {
        var router = PlayerScrollWheelRouter()
        #expect(
            router.route(
                deltaX: 0.2,
                deltaY: 0.1,
                phase: .began,
                momentumPhase: [],
                allowsMomentaryRate: true
            ) == .pending
        )
        #expect(
            router.route(
                deltaX: 8,
                deltaY: 0.2,
                phase: .changed,
                momentumPhase: [],
                allowsMomentaryRate: true
            ) == .momentaryRate
        )
        #expect(
            router.route(
                deltaX: 0,
                deltaY: -30,
                phase: .changed,
                momentumPhase: [],
                allowsMomentaryRate: true
            ) == .momentaryRate
        )
        #expect(
            router.route(
                deltaX: 0,
                deltaY: 0,
                phase: .ended,
                momentumPhase: [],
                allowsMomentaryRate: true
            ) == .momentaryRate
        )
        #expect(
            router.route(
                deltaX: 12,
                deltaY: 0,
                phase: [],
                momentumPhase: .began,
                allowsMomentaryRate: true
            ) == .momentaryRate
        )
        #expect(
            router.route(
                deltaX: 0,
                deltaY: 0,
                phase: [],
                momentumPhase: .ended,
                allowsMomentaryRate: true
            ) == .momentaryRate
        )
    }

    @Test
    @MainActor
    func unphasedAndNonPreciseHorizontalWheelRemainNative() {
        var unphasedRouter = PlayerScrollWheelRouter()
        #expect(
            unphasedRouter.route(
                deltaX: 40,
                deltaY: 0,
                phase: [],
                momentumPhase: [],
                allowsMomentaryRate: true
            ) == .player
        )

        var nonPreciseRouter = PlayerScrollWheelRouter()
        #expect(
            nonPreciseRouter.route(
                deltaX: 40,
                deltaY: 0,
                phase: .began,
                momentumPhase: [],
                isPrecise: false,
                allowsMomentaryRate: true
            ) == .player
        )
    }

    @Test
    @MainActor
    func horizontalRateGestureActivatesAfterThresholdAndEndsBeforeMomentum() {
        var gesture = PlayerHorizontalRateGestureState()
        #expect(
            gesture.handle(
                deltaX: -1,
                phase: .began,
                momentumPhase: []
            ) == .none
        )
        #expect(
            gesture.handle(
                deltaX: -20,
                phase: .changed,
                momentumPhase: []
            ) == .none
        )
        #expect(
            gesture.handle(
                deltaX: -10,
                phase: .changed,
                momentumPhase: []
            ) == .begin(.fast)
        )
        #expect(
            gesture.handle(
                deltaX: 12,
                phase: .changed,
                momentumPhase: []
            ) == .none
        )
        #expect(
            gesture.handle(
                deltaX: 0,
                phase: .ended,
                momentumPhase: []
            ) == .end
        )
        #expect(
            gesture.handle(
                deltaX: 18,
                phase: [],
                momentumPhase: .began
            ) == .none
        )
    }

    @Test
    @MainActor
    func horizontalRateGestureUsesOppositeDirectionForSlowRate() {
        var gesture = PlayerHorizontalRateGestureState()
        _ = gesture.handle(
            deltaX: 4,
            phase: .began,
            momentumPhase: []
        )
        #expect(
            gesture.handle(
                deltaX: 26,
                phase: .changed,
                momentumPhase: []
            ) == .begin(.slow)
        )
        #expect(gesture.cancel() == .end)
    }

    @Test
    @MainActor
    func deviceRelativeHorizontalDeltaIgnoresNaturalScrollingPreference() {
        #expect(
            PlayerScrollWheelSurfaceCapture.deviceRelativeDeltaX(
                20,
                isDirectionInverted: true
            ) == -20
        )
        #expect(
            PlayerScrollWheelSurfaceCapture.deviceRelativeDeltaX(
                -20,
                isDirectionInverted: false
            ) == -20
        )
    }

    @Test
    @MainActor
    func horizontalRateGestureEndsWhenMomentumArrivesWithoutDirectEnd() {
        var gesture = PlayerHorizontalRateGestureState()
        _ = gesture.handle(
            deltaX: -30,
            phase: .began,
            momentumPhase: []
        )
        _ = gesture.handle(
            deltaX: -1,
            phase: .changed,
            momentumPhase: []
        )

        #expect(
            gesture.handle(
                deltaX: -12,
                phase: [],
                momentumPhase: .began
            ) == .end
        )
    }

    @Test
    @MainActor
    func scrollWheelRouterQuarantinesCancelledGestureRemainder() {
        var router = PlayerScrollWheelRouter()
        #expect(
            router.route(
                deltaX: -12,
                deltaY: 0,
                phase: .began,
                momentumPhase: [],
                allowsMomentaryRate: true
            ) == .momentaryRate
        )

        router.cancelInputSession()

        #expect(
            router.route(
                deltaX: -40,
                deltaY: 0,
                phase: .changed,
                momentumPhase: [],
                allowsMomentaryRate: true
            ) == .discard
        )
        #expect(
            router.route(
                deltaX: -30,
                deltaY: 0,
                phase: [],
                momentumPhase: .began,
                allowsMomentaryRate: true
            ) == .discard
        )
        #expect(
            router.route(
                deltaX: 0,
                deltaY: 8,
                phase: .began,
                momentumPhase: [],
                allowsMomentaryRate: true
            ) == .outerScroll
        )
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func realAVPlayerViewIdentitySurvivesUpdatesAndDetachesOnRemoval()
        async throws
    {
        let player = AVPlayer()
        let renderer = CoreAnimationDanmakuRenderer()
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: Self.emptyDanmakuConfiguration
        )
        let state = PlayerHostHarnessState()
        let reconciliation = PlayerHostReconciliationRecorder()
        let hostingView = NSHostingView(
            rootView: PlayerHostHarness(
                player: player,
                renderer: renderer,
                controller: controller,
                state: state,
                reconciliation: reconciliation
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        #expect(
            await waitUntil(in: hostingView) {
                self.playerViews(in: hostingView).count == 1
                    && reconciliation.lastMarker == 0
            }
        )
        let playerView = try #require(playerViews(in: hostingView).first)
        let hostIdentity = ObjectIdentifier(playerView)
        #expect(playerView.player === player)

        let firstItem = AVPlayerItem(asset: AVMutableComposition())
        player.replaceCurrentItem(with: firstItem)
        state.updateMarker += 1
        window.setContentSize(NSSize(width: 1_320, height: 820))
        hostingView.layoutSubtreeIfNeeded()

        #expect(
            await waitUntil(in: hostingView) {
                let views = self.playerViews(in: hostingView)
                return views.count == 1
                    && views.first.map(ObjectIdentifier.init) == hostIdentity
                    && reconciliation.lastMarker == 1
            }
        )
        #expect(playerView.player === player)
        #expect(player.currentItem === firstItem)

        let replacementItem = AVPlayerItem(asset: AVMutableComposition())
        player.replaceCurrentItem(with: replacementItem)
        state.updateMarker += 1
        window.setContentSize(NSSize(width: 860, height: 620))
        hostingView.layoutSubtreeIfNeeded()

        #expect(
            await waitUntil(in: hostingView) {
                let views = self.playerViews(in: hostingView)
                return views.count == 1
                    && views.first.map(ObjectIdentifier.init) == hostIdentity
                    && reconciliation.lastMarker == 2
            }
        )
        #expect(playerView.player === player)
        #expect(player.currentItem === replacementItem)

        state.isPresented = false
        hostingView.layoutSubtreeIfNeeded()
        #expect(
            await waitUntil(in: hostingView) {
                self.playerViews(in: hostingView).isEmpty
                    && playerView.player == nil
            }
        )

        player.replaceCurrentItem(with: nil)
        window.contentView = NSView()
    }

    @MainActor
    private func playerViews(in root: NSView) -> [AVPlayerView] {
        var matches: [AVPlayerView] = []
        if let playerView = root as? AVPlayerView {
            matches.append(playerView)
        }
        for child in root.subviews {
            matches.append(contentsOf: playerViews(in: child))
        }
        return matches
    }

    @MainActor
    private func firstView<ViewType: NSView>(
        ofType type: ViewType.Type,
        in root: NSView
    ) -> ViewType? {
        if let match = root as? ViewType {
            return match
        }
        for child in root.subviews {
            if let match = firstView(ofType: type, in: child) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func firstAncestor<ViewType: NSView>(
        ofType type: ViewType.Type,
        from view: NSView
    ) -> ViewType? {
        var ancestor = view.superview
        while let current = ancestor {
            if let match = current as? ViewType {
                return match
            }
            ancestor = current.superview
        }
        return nil
    }

    private func makeScrollWheelEvent(
        deltaX: Int32,
        deltaY: Int32,
        phase: NSEvent.Phase = [],
        momentumPhase: NSEvent.Phase = []
    ) throws -> NSEvent {
        let event = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: deltaY,
                wheel2: deltaX,
                wheel3: 0
            )
        )
        event.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: cgScrollPhaseValue(phase)
        )
        event.setIntegerValueField(
            .scrollWheelEventMomentumPhase,
            value: cgScrollPhaseValue(momentumPhase)
        )
        return try #require(NSEvent(cgEvent: event))
    }

    private func cgScrollPhaseValue(_ phase: NSEvent.Phase) -> Int64 {
        var value: Int64 = 0
        if phase.contains(.began) { value |= 1 }
        if phase.contains(.changed) { value |= 2 }
        if phase.contains(.ended) { value |= 4 }
        if phase.contains(.cancelled) { value |= 8 }
        if phase.contains(.mayBegin) { value |= 128 }
        return value
    }

    @MainActor
    private func waitUntil<Content: View>(
        in hostingView: NSHostingView<Content>,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else { return false }
            hostingView.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private static let emptyDanmakuConfiguration = DanmakuLaneConfiguration(
        surfaceWidth: 0,
        surfaceHeight: 0,
        laneHeight: 36,
        minimumHorizontalGap: 12,
        maximumActiveCount: DanmakuLaneConfiguration.hardMaximumActiveCount,
        displayAreaFraction: 1
    )
}

@MainActor
private final class ScrollWheelRecordingScrollView: NSScrollView {
    private(set) var receivedScrollWheelEvents: [NSEvent] = []

    override func scrollWheel(with event: NSEvent) {
        receivedScrollWheelEvents.append(event)
    }
}

private struct PlayerHostScrollRoutingHarness: View {
    let player: AVPlayer
    let renderer: CoreAnimationDanmakuRenderer
    let controller: DanmakuPresentationController

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PlayerHostView(
                    player: player,
                    danmakuRenderer: renderer,
                    danmakuController: controller
                )
                .frame(height: 300)
                Color.clear.frame(height: 900)
            }
        }
    }
}

@MainActor
@Observable
private final class PlayerHostHarnessState {
    var updateMarker = 0
    var isPresented = true
}

@MainActor
private final class PlayerHostReconciliationRecorder {
    private(set) var lastMarker: Int?

    func record(_ marker: Int) {
        lastMarker = marker
    }
}

private struct PlayerHostReconciliationProbe: NSViewRepresentable {
    let marker: Int
    let recorder: PlayerHostReconciliationRecorder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        recorder.record(marker)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        recorder.record(marker)
    }
}

private struct PlayerHostHarness: View {
    let player: AVPlayer
    let renderer: CoreAnimationDanmakuRenderer
    let controller: DanmakuPresentationController
    let state: PlayerHostHarnessState
    let reconciliation: PlayerHostReconciliationRecorder

    var body: some View {
        if state.isPresented {
            ZStack {
                PlayerHostView(
                    player: player,
                    danmakuRenderer: renderer,
                    danmakuController: controller
                )
                PlayerHostReconciliationProbe(
                    marker: state.updateMarker,
                    recorder: reconciliation
                )
            }
        }
    }
}
