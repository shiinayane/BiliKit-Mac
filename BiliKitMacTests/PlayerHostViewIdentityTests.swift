import AVKit
import AppKit
import BiliApplication
import BiliDanmaku
import BiliModels
import Testing

@testable import BiliKit

@Suite(.serialized)
struct PlayerHostViewIdentityTests {
    @Test
    func resumeNoticeDismissalOnlyAppliesToTheScheduledToken() {
        let scheduledToken = PlaybackResumeToken()
        let replacementToken = PlaybackResumeToken()

        #expect(
            PlayerResumeNoticeDismissalPolicy.shouldDismiss(
                displayedToken: scheduledToken,
                scheduledToken: scheduledToken
            )
        )
        #expect(
            !PlayerResumeNoticeDismissalPolicy.shouldDismiss(
                displayedToken: replacementToken,
                scheduledToken: scheduledToken
            )
        )
    }

    @Test
    @MainActor
    func nativePlayerViewLeavesNowPlayingOwnershipToProcessController() {
        let renderer = CoreAnimationDanmakuRenderer()
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: Self.emptyDanmakuConfiguration
        )
        let view = DanmakuPlayerView(
            renderer: renderer,
            controller: controller,
            beginMomentaryPlaybackRate: nil,
            endMomentaryPlaybackRate: nil
        )

        #expect(!view.updatesNowPlayingInfoCenter)
    }

    @Test
    @MainActor
    func playbackPreparationBlocksNativePlayerInputAndAccessibility() {
        let renderer = CoreAnimationDanmakuRenderer()
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: Self.emptyDanmakuConfiguration
        )
        let view = DanmakuPlayerView(
            renderer: renderer,
            controller: controller,
            beginMomentaryPlaybackRate: nil,
            endMomentaryPlaybackRate: nil
        )

        view.setPlaybackPreparationBlocked(false)
        #expect(view.controlsStyle == .default)
        #expect(!view.isAccessibilityHidden())

        view.setPlaybackPreparationBlocked(true)
        #expect(view.controlsStyle == .none)
        #expect(!view.acceptsFirstResponder)
        #expect(view.hitTest(.zero) == nil)
        #expect(view.isAccessibilityHidden())

        view.setPlaybackPreparationBlocked(false)
        #expect(view.controlsStyle == .default)
        #expect(!view.isAccessibilityHidden())
    }

    @Test
    @MainActor
    func danmakuSurfaceSurvivesTemporaryWindowReparenting() async throws {
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
        #expect(await waitUntil { controller.statistics.active == 1 })
        let firstLayer = try #require(renderer.rootLayer.sublayers?.first)

        overlay.removeFromSuperview()
        #expect(overlay.window == nil)
        #expect(renderer.rootLayer.superlayer === overlay.layer)
        #expect(renderer.rootLayer.sublayers?.first === firstLayer)
        #expect(controller.statistics.active == 1)

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
        #expect(await waitUntil { controller.statistics.active == 2 })

        overlay.frame = secondWindow.contentView?.bounds ?? .zero
        secondWindow.contentView?.addSubview(overlay)
        overlay.layoutSubtreeIfNeeded()
        #expect(renderer.rootLayer.superlayer === overlay.layer)
        #expect(renderer.rootLayer.sublayers?.first === firstLayer)
        #expect(controller.statistics.active == 2)

        overlay.detachSurface()
        #expect(renderer.rootLayer.superlayer == nil)
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
    func playerSurfaceForwardsOnlyVerticalWheelToDetailScroll() throws {
        let scrollView = ScrollWheelRecordingScrollView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let documentView = NSView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 1_200)
        )
        let playerView = AVPlayerView(
            frame: NSRect(x: 0, y: 900, width: 800, height: 300)
        )
        let capture = PlayerScrollWheelCaptureView(frame: playerView.bounds)
        scrollView.documentView = documentView
        documentView.addSubview(playerView)
        playerView.addSubview(capture)

        let vertical = try makeScrollWheelEvent(deltaX: 2, deltaY: -80)
        let horizontal = try makeScrollWheelEvent(deltaX: -80, deltaY: 2)
        capture.scrollWheel(with: vertical)
        capture.scrollWheel(with: horizontal)

        #expect(scrollView.receivedScrollWheelEvents == [vertical])
    }

    private func makeScrollWheelEvent(
        deltaX: Int32,
        deltaY: Int32
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
        return try #require(NSEvent(cgEvent: event))
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
