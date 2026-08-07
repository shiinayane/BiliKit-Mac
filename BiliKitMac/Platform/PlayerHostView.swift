import AVKit
import BiliDanmaku
import SwiftUI

/// 把唯一 `AVPlayer` 宿主与弹幕 overlay 组合为稳定的播放 surface。
///
/// 响应式页面可以重排这个 View，但不应创建第二个 player host；AppKit host 的销毁会
/// 主动断开 player 并释放弹幕 surface ownership。
struct PlayerHostView: View {
    let player: AVPlayer
    let danmakuRenderer: CoreAnimationDanmakuRenderer
    let danmakuController: DanmakuPresentationController

    var body: some View {
        AVPlayerContainerView(
            player: player,
            renderer: danmakuRenderer,
            controller: danmakuController
        )
    }
}

private struct AVPlayerContainerView: NSViewRepresentable {
    let player: AVPlayer
    let renderer: CoreAnimationDanmakuRenderer
    let controller: DanmakuPresentationController

    func makeNSView(context: Context) -> DanmakuPlayerView {
        let view = DanmakuPlayerView(
            renderer: renderer,
            controller: controller
        )
        view.player = player
        view.controlsStyle = .floating
        return view
    }

    func updateNSView(_ view: DanmakuPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    /// 在 SwiftUI 销毁宿主时先撤销弹幕 surface，再断开 AVPlayer，避免旧 host 继续呈现。
    static func dismantleNSView(
        _ view: DanmakuPlayerView,
        coordinator: ()
    ) {
        view.danmakuOverlay.detachSurface()
        view.player = nil
    }
}

@MainActor
private final class DanmakuPlayerView: AVPlayerView {
    let danmakuOverlay: DanmakuOverlayView
    private let scrollCaptureView = PlayerScrollCaptureView()
    private var installedDanmakuOverlay = false

    init(
        renderer: CoreAnimationDanmakuRenderer,
        controller: DanmakuPresentationController
    ) {
        danmakuOverlay = DanmakuOverlayView(
            renderer: renderer,
            controller: controller
        )
        super.init(frame: .zero)
        installDanmakuOverlayIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installDanmakuOverlayIfNeeded()
    }

    private func installDanmakuOverlayIfNeeded() {
        guard !installedDanmakuOverlay,
            let contentOverlayView
        else {
            return
        }
        installedDanmakuOverlay = true
        scrollCaptureView.translatesAutoresizingMaskIntoConstraints = false
        danmakuOverlay.translatesAutoresizingMaskIntoConstraints = false
        contentOverlayView.addSubview(scrollCaptureView)
        contentOverlayView.addSubview(danmakuOverlay)
        NSLayoutConstraint.activate([
            scrollCaptureView.leadingAnchor.constraint(
                equalTo: contentOverlayView.leadingAnchor
            ),
            scrollCaptureView.trailingAnchor.constraint(
                equalTo: contentOverlayView.trailingAnchor
            ),
            scrollCaptureView.topAnchor.constraint(
                equalTo: contentOverlayView.topAnchor
            ),
            scrollCaptureView.bottomAnchor.constraint(
                equalTo: contentOverlayView.bottomAnchor
            ),
            danmakuOverlay.leadingAnchor.constraint(
                equalTo: contentOverlayView.leadingAnchor
            ),
            danmakuOverlay.trailingAnchor.constraint(
                equalTo: contentOverlayView.trailingAnchor
            ),
            danmakuOverlay.topAnchor.constraint(
                equalTo: contentOverlayView.topAnchor
            ),
            danmakuOverlay.bottomAnchor.constraint(
                equalTo: contentOverlayView.bottomAnchor
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// 安装在 AVKit 公开的 content overlay 中、位于原生控制条下方的透明滚轮命中层。
///
/// 它不覆写点击、拖动、magnify、键盘或辅助功能方法；弹幕层仍保持 hitTest 为 nil。
@MainActor
final class PlayerScrollCaptureView: NSView {
    private var scrollWheelRouter = PlayerScrollWheelRouter()
    private var pendingScrollWheelEvents: [NSEvent] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    /// 只把纵向滚轮序列交给 AVPlayerView 之外的详情 ScrollView。
    override func scrollWheel(with event: NSEvent) {
        flushAbandonedPendingEvents(before: event)
        let route = scrollWheelRouter.route(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            isPrecise: event.hasPreciseScrollingDeltas
        )
        if route == .pending {
            pendingScrollWheelEvents.append(event)
            return
        }

        let events = pendingScrollWheelEvents + [event]
        pendingScrollWheelEvents.removeAll(keepingCapacity: true)
        switch route {
        case .outerScroll:
            guard let scrollView = detailScrollViewAncestor else {
                dispatchToPlayer(events)
                return
            }
            for event in events {
                scrollView.scrollWheel(with: event)
            }
        case .player:
            dispatchToPlayer(events)
        case .pending:
            assertionFailure("Pending scroll events must return before dispatch")
        }
    }

    /// 忽略 AVPlayerView 内部可能存在的滚动视图，只找播放器之外的详情容器。
    private var detailScrollViewAncestor: NSScrollView? {
        var ancestor = superview
        var passedPlayerView = false
        while let current = ancestor {
            if current is AVPlayerView {
                passedPlayerView = true
            } else if passedPlayerView,
                let scrollView = current as? NSScrollView
            {
                return scrollView
            }
            ancestor = current.superview
        }
        return nil
    }

    private func dispatchToPlayer(_ events: [NSEvent]) {
        for event in events {
            super.scrollWheel(with: event)
        }
    }

    private func flushAbandonedPendingEvents(before event: NSEvent) {
        guard !pendingScrollWheelEvents.isEmpty else { return }
        let previousPhase = pendingScrollWheelEvents.last?.phase ?? []
        let startsNewGesture =
            event.phase.contains(.mayBegin)
            || (event.phase.contains(.began)
                && !previousPhase.contains(.mayBegin))
        let leavesDirectGesture = event.phase.isEmpty
        guard startsNewGesture || leavesDirectGesture else { return }
        dispatchToPlayer(pendingScrollWheelEvents)
        pendingScrollWheelEvents.removeAll(keepingCapacity: true)
        scrollWheelRouter.reset()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

struct PlayerScrollWheelRouter {
    enum Route: Equatable {
        case outerScroll
        case player
        case pending
    }

    private static let minimumAxisTravel: CGFloat = 4
    private static let minimumAxisLead: CGFloat = 2
    private static let maximumPendingSampleCount = 16

    private var gestureRoute: Route?
    private var completedGestureRoute: Route?
    private var accumulatedDeltaX: CGFloat = 0
    private var accumulatedDeltaY: CGFloat = 0
    private var pendingSampleCount = 0

    mutating func route(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        isPrecise: Bool = true
    ) -> Route {
        if !momentumPhase.isEmpty {
            let route =
                gestureRoute
                ?? completedGestureRoute
                ?? dominantRoute(deltaX: deltaX, deltaY: deltaY)
            if momentumPhase.contains(.ended)
                || momentumPhase.contains(.cancelled)
            {
                gestureRoute = nil
                completedGestureRoute = nil
            }
            return route
        }

        if phase.isEmpty {
            return dominantRoute(deltaX: deltaX, deltaY: deltaY)
        }

        if phase.contains(.began) || phase.contains(.mayBegin) {
            reset()
        }

        if !isPrecise {
            if gestureRoute == nil {
                gestureRoute = unambiguousRoute(
                    deltaX: deltaX,
                    deltaY: deltaY
                )
            }
            if gestureRoute == nil,
                phase.contains(.ended) || phase.contains(.cancelled)
            {
                gestureRoute = .player
            }
            let route = gestureRoute ?? .pending
            if phase.contains(.ended) {
                completedGestureRoute = route
                resetDirectGesture()
            } else if phase.contains(.cancelled) {
                completedGestureRoute = nil
                resetDirectGesture()
            }
            return route
        }

        if gestureRoute == nil {
            accumulatedDeltaX += deltaX
            accumulatedDeltaY += deltaY
            pendingSampleCount += 1
            gestureRoute = accumulatedRoute()
            if gestureRoute == nil,
                phase.contains(.ended)
                    || phase.contains(.cancelled)
                    || pendingSampleCount >= Self.maximumPendingSampleCount
            {
                gestureRoute = .player
            }
        }

        let route = gestureRoute ?? .pending
        if phase.contains(.ended) {
            completedGestureRoute = gestureRoute
            resetDirectGesture()
        } else if phase.contains(.cancelled) {
            completedGestureRoute = nil
            resetDirectGesture()
        }
        return route
    }

    mutating func reset() {
        gestureRoute = nil
        completedGestureRoute = nil
        resetDirectGesture()
    }

    private mutating func resetDirectGesture() {
        gestureRoute = nil
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        pendingSampleCount = 0
    }

    private func accumulatedRoute() -> Route? {
        let horizontalMagnitude = abs(accumulatedDeltaX)
        let verticalMagnitude = abs(accumulatedDeltaY)
        let dominantMagnitude = max(horizontalMagnitude, verticalMagnitude)
        let axisLead = abs(horizontalMagnitude - verticalMagnitude)
        guard dominantMagnitude >= Self.minimumAxisTravel,
            axisLead >= Self.minimumAxisLead
        else {
            return nil
        }
        return verticalMagnitude > horizontalMagnitude ? .outerScroll : .player
    }

    private func dominantRoute(deltaX: CGFloat, deltaY: CGFloat) -> Route {
        unambiguousRoute(deltaX: deltaX, deltaY: deltaY) ?? .player
    }

    private func unambiguousRoute(
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> Route? {
        let horizontalMagnitude = abs(deltaX)
        let verticalMagnitude = abs(deltaY)
        guard horizontalMagnitude != verticalMagnitude else { return nil }
        return verticalMagnitude > horizontalMagnitude ? .outerScroll : .player
    }
}
