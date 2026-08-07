import AVKit
import AppKit
import BiliDanmaku
import Observation
import SwiftUI
import Testing

@testable import BiliKit

@Suite(.serialized)
struct PlayerHostViewIdentityTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func contentOverlayCaptureRoutesVerticalWheelToEnclosingSwiftUIScrollView()
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
        hostingView.layoutSubtreeIfNeeded()

        #expect(
            await waitUntil(in: hostingView) {
                self.firstView(
                    ofType: AVPlayerView.self,
                    in: hostingView
                ) != nil
            }
        )
        let playerView = try #require(
            firstView(
                ofType: AVPlayerView.self,
                in: hostingView
            )
        )
        let scrollCaptureView = try #require(
            firstView(
                ofType: PlayerScrollCaptureView.self,
                in: playerView
            )
        )
        #expect(scrollCaptureView.superview === playerView.contentOverlayView)
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
            }
        )
        let initialOrigin = scrollView.contentView.bounds.origin
        let event = try makeScrollWheelEvent(deltaX: 0, deltaY: -80)
        #expect(event.hasPreciseScrollingDeltas)

        let videoPoint = NSPoint(
            x: playerView.bounds.midX,
            y: playerView.bounds.height * 0.75
        )
        let eventTarget = try #require(
            playerView.hitTest(
                playerView.convert(videoPoint, to: playerView.superview)
            )
        )
        #expect(eventTarget === scrollCaptureView)
        eventTarget.scrollWheel(with: event)

        #expect(
            await waitUntil(in: hostingView) {
                scrollView.contentView.bounds.origin.y > initialOrigin.y
            }
        )

        let scrolledOrigin = scrollView.contentView.bounds.origin
        let horizontalEvent = try makeScrollWheelEvent(deltaX: -80, deltaY: 0)
        eventTarget.scrollWheel(with: horizontalEvent)
        hostingView.layoutSubtreeIfNeeded()
        #expect(scrollView.contentView.bounds.origin == scrolledOrigin)

        window.contentView = NSView()
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
                ) {
                    EmptyView()
                }
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
