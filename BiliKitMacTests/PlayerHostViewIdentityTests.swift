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
    func resumeNoticeUsesCompactCopyAndTokenScopedFiveSecondDismissal() {
        let scheduledToken = PlaybackResumeToken()
        let replacementToken = PlaybackResumeToken()

        #expect(PlayerResumeNoticePresentation.title == AppStrings.localized("从头播放"))
        #expect(PlayerResumeNoticeDismissalPolicy.delay == .seconds(5))
        #expect(PlayerResumeNoticeDismissalPolicy.fadeDurationSeconds == 0.2)
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
        #expect(view.controlsStyle == .floating)
        #expect(!view.isAccessibilityHidden())

        view.setPlaybackPreparationBlocked(true)
        #expect(view.controlsStyle == .none)
        #expect(!view.acceptsFirstResponder)
        #expect(view.hitTest(.zero) == nil)
        #expect(view.isAccessibilityHidden())

        view.setPlaybackPreparationBlocked(false)
        #expect(view.controlsStyle == .floating)
        #expect(!view.isAccessibilityHidden())
    }

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
        var routing = PlayerScrollWheelRouting()
        #expect(
            routing.route(
                deltaX: -80,
                deltaY: 2,
                phase: [],
                momentumPhase: []
            ) == .ignore
        )
        #expect(
            routing.route(
                deltaX: 2,
                deltaY: -80,
                phase: [],
                momentumPhase: []
            )
                == .outerScroll
        )
    }

    @Test
    @MainActor
    func verticalWheelSequencePreservesBeginningEndingAndMomentum() throws {
        var routing = PlayerScrollWheelRouting()
        let routes = [
            routing.route(
                deltaX: 0,
                deltaY: 0,
                phase: .began,
                momentumPhase: []
            ),
            routing.route(
                deltaX: 1,
                deltaY: -12,
                phase: .changed,
                momentumPhase: []
            ),
            routing.route(
                deltaX: -20,
                deltaY: -1,
                phase: .changed,
                momentumPhase: []
            ),
            routing.route(
                deltaX: 0,
                deltaY: 0,
                phase: .ended,
                momentumPhase: []
            ),
            routing.route(
                deltaX: -8,
                deltaY: -1,
                phase: [],
                momentumPhase: .began
            ),
            routing.route(
                deltaX: 0,
                deltaY: -6,
                phase: [],
                momentumPhase: .changed
            ),
            routing.route(
                deltaX: 0,
                deltaY: 0,
                phase: [],
                momentumPhase: .ended
            ),
        ]
        #expect(
            routes == [
                .pending,
                .outerScroll,
                .outerScroll,
                .outerScroll,
                .outerScroll,
                .outerScroll,
                .outerScroll,
            ]
        )

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

        let events = try [
            makeScrollWheelEvent(deltaX: 0, deltaY: 0, phase: .began),
            makeScrollWheelEvent(deltaX: 1, deltaY: -12, phase: .changed),
            makeScrollWheelEvent(deltaX: -20, deltaY: -1, phase: .changed),
            makeScrollWheelEvent(deltaX: 0, deltaY: 0, phase: .ended),
            makeScrollWheelEvent(
                deltaX: -8,
                deltaY: -1,
                momentumPhase: .began
            ),
            makeScrollWheelEvent(
                deltaX: 0,
                deltaY: -6,
                momentumPhase: .changed
            ),
        ]
        let expectedForwardedCounts = [0, 2, 3, 4, 5, 6]
        for (index, event) in events.enumerated() {
            capture.scrollWheel(with: event)
            #expect(
                scrollView.receivedScrollWheelEvents.count
                    == expectedForwardedCounts[index]
            )
        }

        #expect(scrollView.receivedScrollWheelEvents == events)
    }

    @Test
    @MainActor
    func horizontalSequenceIsIgnoredAndOrphanedVerticalChangeResumesImmediately()
        throws
    {
        var routing = PlayerScrollWheelRouting()
        #expect(
            routing.route(
                deltaX: 0,
                deltaY: 0,
                phase: .began,
                momentumPhase: []
            ) == .pending
        )
        #expect(
            routing.route(
                deltaX: -12,
                deltaY: 1,
                phase: .changed,
                momentumPhase: []
            ) == .ignore
        )
        #expect(
            routing.route(
                deltaX: 0,
                deltaY: 0,
                phase: .ended,
                momentumPhase: []
            ) == .ignore
        )
        #expect(
            routing.route(
                deltaX: 0,
                deltaY: -10,
                phase: [],
                momentumPhase: .changed
            ) == .ignore
        )

        var orphanedRouting = PlayerScrollWheelRouting()
        #expect(
            orphanedRouting.route(
                deltaX: 1,
                deltaY: -12,
                phase: .changed,
                momentumPhase: []
            ) == .outerScroll
        )
        orphanedRouting.cancel()
        #expect(
            orphanedRouting.route(
                deltaX: 0,
                deltaY: -8,
                phase: [],
                momentumPhase: .changed
            ) == .ignore
        )
    }

    @Test
    @MainActor
    func scrollShieldAndOverlayCaptureOnlyWheelEvents() throws {
        #expect(PlayerScrollWheelCaptureView.capturesEvent(ofType: .scrollWheel))
        #expect(!PlayerScrollWheelCaptureView.capturesEvent(ofType: .leftMouseDown))
        #expect(
            PlayerScrollWheelShieldView.capturesEvent(ofType: .scrollWheel)
        )
        #expect(
            !PlayerScrollWheelShieldView.capturesEvent(ofType: .leftMouseDown)
        )
        let shield = PlayerScrollWheelShieldView(frame: .zero)
        #expect(!shield.isAccessibilityElement())
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
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_080, height: 680)
        let scrollView = ScrollWheelRecordingScrollView(frame: hostingView.frame)
        scrollView.documentView = hostingView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
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
        let windowShield = try #require(
            playerView.subviews.first { $0 is PlayerScrollWheelShieldView }
        )
        #expect(!windowShield.isAccessibilityElement())
        let verticalEvent = try makeScrollWheelEvent(deltaX: 0, deltaY: -80)
        windowShield.scrollWheel(with: verticalEvent)
        #expect(scrollView.receivedScrollWheelEvents == [verticalEvent])

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
