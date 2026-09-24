import AVKit

/// 普通窗口中位于 AVPlayerView 原生子视图上方的 scroll-only direct child。
///
/// 该视图没有自己的 router 或播放状态；它只把 scroll-wheel 转交给
/// `contentOverlayView` capture 持有的唯一 surface coordinator。其他输入穿透给 AVKit。
@MainActor
final class PlayerScrollWheelShieldView: NSView {
    var onScrollWheel: (NSEvent) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        PlayerScrollWheelCaptureView.capturesEvent(ofType: NSApp.currentEvent?.type)
            ? self : nil
    }

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel(event)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// 安装在 AVKit 公开 content overlay 中、位于原生控制条下方的透明滚轮命中层。
///
/// 只对 scroll-wheel 事件参与 hit testing；点击、拖动、magnify、键盘与辅助功能继续穿透。
/// AVKit detached 全屏会携带 content overlay；横向 wheel 在所有 surface 都不产生播放器动作。
/// 它也是键盘快捷键的窗口锚点：`keyboardShortcuts` 跟随本视图所在窗口（包括 detached 全屏）。
@MainActor
final class PlayerScrollWheelCaptureView: NSView {
    let keyboardShortcuts = PlayerKeyboardShortcutController()
    private var windowResignObservers = NativeVideoNotificationObservers()
    private var scrollWheelRouter = PlayerScrollWheelRouter<NSEvent>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        keyboardShortcuts.anchorView = self
    }

    static func capturesEvent(ofType type: NSEvent.EventType?) -> Bool {
        type == .scrollWheel
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        Self.capturesEvent(ofType: NSApp.currentEvent?.type) ? self : nil
    }

    override func scrollWheel(with event: NSEvent) {
        handleScrollWheel(event)
    }

    func handleScrollWheel(_ event: NSEvent) {
        let released = scrollWheelRouter.route(event)
        guard !released.isEmpty, let scrollView = detailScrollViewAncestor else { return }
        for releasedEvent in released {
            scrollView.scrollWheel(with: releasedEvent)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            stopObservingWindowFocusLoss()
            cancelInputSession()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        keyboardShortcuts.startMonitoring()
        windowResignObservers.removeAll()
        windowResignObservers.observe(
            NSWindow.didResignKeyNotification,
            object: window
        ) { [weak self] in
            self?.cancelInputSession()
        }
    }

    func cancelInputSession() {
        scrollWheelRouter.cancel()
        keyboardShortcuts.cancelInputSession()
    }

    func stopKeyboardMonitoring() {
        cancelInputSession()
        keyboardShortcuts.stopMonitoring()
        stopObservingWindowFocusLoss()
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

    private func stopObservingWindowFocusLoss() {
        windowResignObservers.removeAll()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// 路由器需要的滚轮输入字段；`NSEvent` 原生满足，测试可用假事件。
protocol PlayerScrollWheelInput {
    var scrollingDeltaX: CGFloat { get }
    var scrollingDeltaY: CGFloat { get }
    var phase: NSEvent.Phase { get }
    var momentumPhase: NSEvent.Phase { get }
}

extension NSEvent: PlayerScrollWheelInput {}

/// 播放器表面与详情滚动视图共用的轴向规则：横向严格占优的滚轮不滚动详情页。
///
/// 相等（包括 began／ended 等零位移阶段事件）按纵向处理，外层 `NSScrollView` 才能收到完整阶段。
enum PlayerScrollWheelAxisRule {
    static func scrollsVertically(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        abs(deltaX) <= abs(deltaY)
    }
}

/// 播放器表面滚轮的手势级路由：纵向手势按原顺序交给外层详情滚动，横向手势整体丢弃。
///
/// 触控板手势在轴向确定前暂存事件，确定后一次性投递或丢弃；惯性阶段沿用手势的决定。
/// 无阶段的鼠标滚轮逐个事件判断。`cancel()` 之后直到下一次手势开始前的残余事件都丢弃。
struct PlayerScrollWheelRouter<Event: PlayerScrollWheelInput> {
    private enum Decision {
        case forward
        case discard
    }

    private static var minimumAxisTravel: CGFloat { 1 }
    private static var minimumAxisLead: CGFloat { 0.5 }

    private var pendingEvents: [Event] = []
    private var lockedDecision: Decision?
    private var gestureIsActive = false
    private var accumulatedDeltaX: CGFloat = 0
    private var accumulatedDeltaY: CGFloat = 0
    private var discardsCancelledRemainder = false

    /// 返回应立即按顺序交给外层滚动视图的事件；轴向未定或被丢弃时返回空数组。
    mutating func route(_ event: Event) -> [Event] {
        guard let decision = decide(event) else {
            pendingEvents.append(event)
            return []
        }
        let released = pendingEvents + [event]
        pendingEvents.removeAll(keepingCapacity: true)
        return decision == .forward ? released : []
    }

    mutating func cancel() {
        pendingEvents.removeAll(keepingCapacity: true)
        reset()
        discardsCancelledRemainder = true
    }

    private mutating func decide(_ event: Event) -> Decision? {
        let phase = event.phase
        let momentumPhase = event.momentumPhase
        let startsGesture = phase.contains(.mayBegin) || phase.contains(.began)

        if discardsCancelledRemainder {
            guard startsGesture || (phase.isEmpty && momentumPhase.isEmpty) else {
                return .discard
            }
            discardsCancelledRemainder = false
        }

        if !momentumPhase.isEmpty {
            let decision = lockedDecision ?? Self.dominantDecision(of: event)
            if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) {
                reset()
            }
            return decision
        }

        if phase.isEmpty {
            if !gestureIsActive { lockedDecision = nil }
            return Self.dominantDecision(of: event)
        }

        if startsGesture {
            reset()
            gestureIsActive = true
        } else if !gestureIsActive {
            // 没有见到开始阶段的手势（例如取消后恢复）按首个事件立即决定。
            guard phase.contains(.changed) else { return .discard }
            gestureIsActive = true
            lockedDecision = Self.dominantDecision(of: event)
        }

        if lockedDecision == nil {
            accumulatedDeltaX += event.scrollingDeltaX
            accumulatedDeltaY += event.scrollingDeltaY
            lockedDecision = accumulatedDecision()
        }

        if phase.contains(.ended) || phase.contains(.cancelled) {
            let decision =
                lockedDecision
                ?? Self.decision(deltaX: accumulatedDeltaX, deltaY: accumulatedDeltaY)
            reset()
            if phase.contains(.ended) {
                // 手指抬起后的惯性阶段沿用本次手势的决定。
                lockedDecision = decision
            }
            return decision
        }
        return lockedDecision
    }

    private func accumulatedDecision() -> Decision? {
        let horizontalMagnitude = abs(accumulatedDeltaX)
        let verticalMagnitude = abs(accumulatedDeltaY)
        guard
            max(horizontalMagnitude, verticalMagnitude) >= Self.minimumAxisTravel,
            abs(verticalMagnitude - horizontalMagnitude) >= Self.minimumAxisLead
        else { return nil }
        return Self.decision(deltaX: accumulatedDeltaX, deltaY: accumulatedDeltaY)
    }

    private static func dominantDecision(of event: Event) -> Decision {
        decision(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
    }

    private static func decision(deltaX: CGFloat, deltaY: CGFloat) -> Decision {
        PlayerScrollWheelAxisRule.scrollsVertically(deltaX: deltaX, deltaY: deltaY)
            ? .forward : .discard
    }

    private mutating func reset() {
        lockedDecision = nil
        gestureIsActive = false
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
    }
}
