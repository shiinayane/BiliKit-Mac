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
    let beginMomentaryPlaybackRate: ((Float) -> UUID?)?
    let endMomentaryPlaybackRate: ((UUID) -> Void)?

    init(
        player: AVPlayer,
        danmakuRenderer: CoreAnimationDanmakuRenderer,
        danmakuController: DanmakuPresentationController,
        beginMomentaryPlaybackRate: ((Float) -> UUID?)? = nil,
        endMomentaryPlaybackRate: ((UUID) -> Void)? = nil
    ) {
        self.player = player
        self.danmakuRenderer = danmakuRenderer
        self.danmakuController = danmakuController
        self.beginMomentaryPlaybackRate = beginMomentaryPlaybackRate
        self.endMomentaryPlaybackRate = endMomentaryPlaybackRate
    }

    var body: some View {
        AVPlayerContainerView(
            player: player,
            renderer: danmakuRenderer,
            controller: danmakuController,
            beginMomentaryPlaybackRate: beginMomentaryPlaybackRate,
            endMomentaryPlaybackRate: endMomentaryPlaybackRate
        )
    }
}

private struct AVPlayerContainerView: NSViewRepresentable {
    let player: AVPlayer
    let renderer: CoreAnimationDanmakuRenderer
    let controller: DanmakuPresentationController
    let beginMomentaryPlaybackRate: ((Float) -> UUID?)?
    let endMomentaryPlaybackRate: ((UUID) -> Void)?

    func makeNSView(context: Context) -> DanmakuPlayerView {
        let view = DanmakuPlayerView(
            renderer: renderer,
            controller: controller,
            beginMomentaryPlaybackRate: beginMomentaryPlaybackRate,
            endMomentaryPlaybackRate: endMomentaryPlaybackRate
        )
        view.player = player
        view.startObservingPlayerItemChanges()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ view: DanmakuPlayerView, context: Context) {
        view.requestMomentaryPlaybackRate = beginMomentaryPlaybackRate
        view.finishMomentaryPlaybackRate = endMomentaryPlaybackRate
        if view.player !== player {
            view.cancelMomentaryPlaybackRate()
            view.player = player
            view.startObservingPlayerItemChanges()
        }
    }

    /// 在 SwiftUI 销毁宿主时先撤销弹幕 surface，再断开 AVPlayer，避免旧 host 继续呈现。
    static func dismantleNSView(
        _ view: DanmakuPlayerView,
        coordinator: ()
    ) {
        view.danmakuOverlay.detachSurface()
        view.stopObservingFocusLoss()
        view.stopObservingPlayerItemChanges()
        view.cancelMomentaryPlaybackRate()
        view.player = nil
    }
}

enum PlayerMomentaryRate: Float, Equatable, Sendable {
    case slow = 0.5
    case fast = 2

    var label: String {
        switch self {
        case .slow: "0.5X"
        case .fast: "2X"
        }
    }

    var symbolName: String {
        switch self {
        case .slow: "backward.fill"
        case .fast: "forward.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .slow: "临时播放速度 0.5 倍"
        case .fast: "临时播放速度 2 倍"
        }
    }
}

enum PlayerMomentaryRateSessionPolicy {
    static func shouldCancel(
        hasActiveSession: Bool,
        timeControlStatus: AVPlayer.TimeControlStatus
    ) -> Bool {
        hasActiveSession && timeControlStatus == .paused
    }
}

private struct PlayerMomentaryRateBadge: View {
    let rate: PlayerMomentaryRate

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: rate.symbolName)
            Text(rate.label)
                .monospacedDigit()
        }
        .font(.title3.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .modifier(PlayerMomentaryRateBadgeBackground())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rate.accessibilityLabel)
        .accessibilityIdentifier("player.momentary-rate")
    }
}

private struct PlayerMomentaryRateBadgeBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: Capsule())
            } else {
                fallbackBackground(content)
            }
        #else
            fallbackBackground(content)
        #endif
    }

    private func fallbackBackground(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.18), lineWidth: 0.5)
            }
    }
}

@MainActor
private final class PlayerMomentaryRateBadgeHostingView:
    NSHostingView<PlayerMomentaryRateBadge>
{
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class DanmakuPlayerView: AVPlayerView {
    let danmakuOverlay: DanmakuOverlayView
    private let scrollWheelCaptureView = PlayerScrollWheelCaptureView()
    private var installedDanmakuOverlay = false
    private var momentaryRateSessionID: UUID?
    private var momentaryRateItemIdentity: ObjectIdentifier?
    private weak var observedPlayer: AVPlayer?
    private var playerItemObservation: NSKeyValueObservation?
    private var playerTimeControlObservation: NSKeyValueObservation?
    private var appResignObserver: NSObjectProtocol?
    private var windowResignObserver: NSObjectProtocol?
    var requestMomentaryPlaybackRate: ((Float) -> UUID?)?
    var finishMomentaryPlaybackRate: ((UUID) -> Void)?

    init(
        renderer: CoreAnimationDanmakuRenderer,
        controller: DanmakuPresentationController,
        beginMomentaryPlaybackRate: ((Float) -> UUID?)?,
        endMomentaryPlaybackRate: ((UUID) -> Void)?
    ) {
        danmakuOverlay = DanmakuOverlayView(
            renderer: renderer,
            controller: controller
        )
        requestMomentaryPlaybackRate = beginMomentaryPlaybackRate
        finishMomentaryPlaybackRate = endMomentaryPlaybackRate
        super.init(frame: .zero)
        scrollWheelCaptureView.isMomentaryRateAvailable = { [weak self] in
            self?.canBeginMomentaryPlaybackRate == true
        }
        scrollWheelCaptureView.onMomentaryRateBegan = { [weak self] rate in
            self?.beginMomentaryPlaybackRate(rate)
        }
        scrollWheelCaptureView.onMomentaryRateEnded = { [weak self] in
            self?.endMomentaryPlaybackRate()
        }
        installDanmakuOverlayIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            stopObservingFocusLoss()
            cancelMomentaryPlaybackRate()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installDanmakuOverlayIfNeeded()
        startObservingFocusLoss()
    }

    func cancelMomentaryPlaybackRate() {
        scrollWheelCaptureView.cancelInputSession()
        if momentaryRateSessionID != nil {
            endMomentaryPlaybackRate()
        }
    }

    func cancelMomentaryPlaybackRateIfItemChanged() {
        guard let momentaryRateItemIdentity else { return }
        guard let currentItem = player?.currentItem,
            ObjectIdentifier(currentItem) == momentaryRateItemIdentity
        else {
            cancelMomentaryPlaybackRate()
            return
        }
    }

    func startObservingPlayerItemChanges() {
        guard observedPlayer !== player else { return }
        stopObservingPlayerItemChanges()
        guard let player else { return }
        observedPlayer = player
        playerItemObservation = player.observe(\.currentItem, options: [.new]) {
            [weak self] _, _ in
            Task { @MainActor in
                self?.cancelMomentaryPlaybackRateIfItemChanged()
            }
        }
        playerTimeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.new]
        ) {
            [weak self] _, change in
            guard change.newValue == .paused else { return }
            Task { @MainActor in
                guard let self,
                    PlayerMomentaryRateSessionPolicy.shouldCancel(
                        hasActiveSession: self.momentaryRateSessionID != nil,
                        timeControlStatus: self.player?.timeControlStatus
                            ?? .paused
                    )
                else {
                    return
                }
                self.cancelMomentaryPlaybackRate()
            }
        }
    }

    func stopObservingPlayerItemChanges() {
        playerItemObservation?.invalidate()
        playerItemObservation = nil
        playerTimeControlObservation?.invalidate()
        playerTimeControlObservation = nil
        observedPlayer = nil
    }

    private func installDanmakuOverlayIfNeeded() {
        guard !installedDanmakuOverlay,
            let contentOverlayView
        else {
            return
        }
        installedDanmakuOverlay = true
        scrollWheelCaptureView.translatesAutoresizingMaskIntoConstraints = false
        danmakuOverlay.translatesAutoresizingMaskIntoConstraints = false
        contentOverlayView.addSubview(danmakuOverlay)
        contentOverlayView.addSubview(
            scrollWheelCaptureView,
            positioned: .above,
            relativeTo: danmakuOverlay
        )
        NSLayoutConstraint.activate([
            scrollWheelCaptureView.leadingAnchor.constraint(
                equalTo: contentOverlayView.leadingAnchor
            ),
            scrollWheelCaptureView.trailingAnchor.constraint(
                equalTo: contentOverlayView.trailingAnchor
            ),
            scrollWheelCaptureView.topAnchor.constraint(
                equalTo: contentOverlayView.topAnchor
            ),
            scrollWheelCaptureView.bottomAnchor.constraint(
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

    private var canBeginMomentaryPlaybackRate: Bool {
        guard requestMomentaryPlaybackRate != nil,
            finishMomentaryPlaybackRate != nil,
            let player,
            let item = player.currentItem
        else {
            return false
        }
        return item.status == .readyToPlay && player.rate > 0
    }

    private func beginMomentaryPlaybackRate(_ rate: PlayerMomentaryRate) {
        guard let player,
            let item = player.currentItem,
            item.status == .readyToPlay,
            player.rate > 0,
            let sessionID = requestMomentaryPlaybackRate?(rate.rawValue)
        else {
            clearMomentaryPlaybackRate()
            return
        }
        momentaryRateSessionID = sessionID
        momentaryRateItemIdentity = ObjectIdentifier(item)
        scrollWheelCaptureView.showMomentaryRateBadge(rate)
    }

    private func endMomentaryPlaybackRate() {
        if let momentaryRateSessionID {
            finishMomentaryPlaybackRate?(momentaryRateSessionID)
        }
        clearMomentaryPlaybackRate()
    }

    private func clearMomentaryPlaybackRate() {
        momentaryRateSessionID = nil
        momentaryRateItemIdentity = nil
        scrollWheelCaptureView.clearMomentaryRateBadge()
    }

    private func startObservingFocusLoss() {
        guard requestMomentaryPlaybackRate != nil,
            finishMomentaryPlaybackRate != nil,
            let window,
            appResignObserver == nil,
            windowResignObserver == nil
        else {
            return
        }
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelMomentaryPlaybackRate()
            }
        }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelMomentaryPlaybackRate()
            }
        }
    }

    func stopObservingFocusLoss() {
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// 安装在 AVKit 公开 content overlay 中、位于原生控制条下方的透明滚轮命中层。
///
/// 只对 scroll-wheel 事件参与 hit testing；点击、拖动、magnify、键盘与辅助功能继续穿透。
/// AVKit detached 全屏会携带 content overlay，因此同一 capture 可继续处理全屏横向倍速。
@MainActor
final class PlayerScrollWheelCaptureView: NSView {
    private lazy var surfaceCapture = PlayerScrollWheelSurfaceCapture(
        anchorView: self,
        dispatchToPlayer: { [weak self] event in
            self?.dispatchScrollWheelToResponderChain(event)
        }
    )
    private var windowResignObserver: NSObjectProtocol?
    private var momentaryRateBadge: NSView?

    var isMomentaryRateAvailable: () -> Bool {
        get { surfaceCapture.isMomentaryRateAvailable }
        set { surfaceCapture.isMomentaryRateAvailable = newValue }
    }

    var onMomentaryRateBegan: (PlayerMomentaryRate) -> Void {
        get { surfaceCapture.onMomentaryRateBegan }
        set { surfaceCapture.onMomentaryRateBegan = newValue }
    }

    var onMomentaryRateEnded: () -> Void {
        get { surfaceCapture.onMomentaryRateEnded }
        set { surfaceCapture.onMomentaryRateEnded = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    static func capturesEvent(ofType type: NSEvent.EventType?) -> Bool {
        type == .scrollWheel
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        Self.capturesEvent(ofType: NSApp.currentEvent?.type) ? self : nil
    }

    override func scrollWheel(with event: NSEvent) {
        surfaceCapture.handleScrollWheel(event)
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
        guard let window, windowResignObserver == nil else { return }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelInputSession()
            }
        }
    }

    func cancelInputSession() {
        surfaceCapture.cancelInputSession()
    }

    var hasMomentaryRateBadge: Bool {
        momentaryRateBadge != nil
    }

    func showMomentaryRateBadge(_ rate: PlayerMomentaryRate) {
        clearMomentaryRateBadge()
        let badge = PlayerMomentaryRateBadgeHostingView(
            rootView: PlayerMomentaryRateBadge(rate: rate)
        )
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 20),
        ])
        momentaryRateBadge = badge
    }

    func clearMomentaryRateBadge() {
        momentaryRateBadge?.removeFromSuperview()
        momentaryRateBadge = nil
    }

    private func dispatchScrollWheelToResponderChain(_ event: NSEvent) {
        super.scrollWheel(with: event)
    }

    private func stopObservingWindowFocusLoss() {
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// 由唯一 AVPlayerView content overlay surface 拥有的滚轮序列处理器。
///
/// 本类型不安装 event monitor，也不向 AVKit 私有子视图重放事件。
@MainActor
final class PlayerScrollWheelSurfaceCapture {
    private weak var anchorView: NSView?
    private let dispatchToPlayer: (NSEvent) -> Void
    private var scrollWheelRouter = PlayerScrollWheelRouter()
    private var horizontalRateGesture = PlayerHorizontalRateGestureState()
    private var pendingScrollWheelEvents: [NSEvent] = []
    var isMomentaryRateAvailable: () -> Bool = { false }
    var onMomentaryRateBegan: (PlayerMomentaryRate) -> Void = { _ in }
    var onMomentaryRateEnded: () -> Void = {}

    init(
        anchorView: NSView,
        dispatchToPlayer: @escaping (NSEvent) -> Void = { _ in }
    ) {
        self.anchorView = anchorView
        self.dispatchToPlayer = dispatchToPlayer
    }

    var hasDetailScrollViewAncestor: Bool {
        detailScrollViewAncestor != nil
    }

    /// 纵向滚动交给详情页；播放中的精确横向手势用于临时倍速。
    func handleScrollWheel(_ event: NSEvent) {
        cancelAbandonedMomentaryRate(before: event)
        flushAbandonedPendingEvents(before: event)
        let route = scrollWheelRouter.route(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            isPrecise: event.hasPreciseScrollingDeltas,
            allowsMomentaryRate: isMomentaryRateAvailable()
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
                dispatchToAVKit(events)
                return
            }
            for event in events {
                scrollView.scrollWheel(with: event)
            }
        case .player:
            dispatchToAVKit(events)
        case .momentaryRate:
            for event in events {
                applyHorizontalRateAction(
                    horizontalRateGesture.handle(
                        deltaX: Self.deviceRelativeDeltaX(
                            event.scrollingDeltaX,
                            isDirectionInverted:
                                event.isDirectionInvertedFromDevice
                        ),
                        phase: event.phase,
                        momentumPhase: event.momentumPhase
                    )
                )
            }
        case .discard:
            return
        case .pending:
            assertionFailure("Pending scroll events must return before dispatch")
        }
    }

    func cancelInputSession() {
        let action = horizontalRateGesture.cancel()
        pendingScrollWheelEvents.removeAll(keepingCapacity: true)
        scrollWheelRouter.cancelInputSession()
        applyHorizontalRateAction(action)
    }

    static func deviceRelativeDeltaX(
        _ deltaX: CGFloat,
        isDirectionInverted: Bool
    ) -> CGFloat {
        isDirectionInverted ? -deltaX : deltaX
    }

    private func applyHorizontalRateAction(
        _ action: PlayerHorizontalRateGestureState.Action
    ) {
        switch action {
        case .none:
            return
        case .begin(let rate):
            onMomentaryRateBegan(rate)
        case .end:
            onMomentaryRateEnded()
        }
    }

    /// 忽略 AVPlayerView 内部可能存在的滚动视图，只找播放器之外的详情容器。
    private var detailScrollViewAncestor: NSScrollView? {
        var ancestor = anchorView?.superview
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

    private func dispatchToAVKit<Events: Sequence>(_ events: Events)
    where Events.Element == NSEvent {
        for event in events {
            dispatchToPlayer(event)
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
        dispatchToAVKit(pendingScrollWheelEvents)
        pendingScrollWheelEvents.removeAll(keepingCapacity: true)
        applyHorizontalRateAction(horizontalRateGesture.cancel())
        scrollWheelRouter.reset()
    }

    private func cancelAbandonedMomentaryRate(before event: NSEvent) {
        let previousPhase = pendingScrollWheelEvents.last?.phase ?? []
        let startsNewGesture =
            event.phase.contains(.mayBegin)
            || (event.phase.contains(.began)
                && !previousPhase.contains(.mayBegin))
        let startsUnphasedInput =
            event.phase.isEmpty && event.momentumPhase.isEmpty
        guard startsNewGesture || startsUnphasedInput else { return }
        applyHorizontalRateAction(horizontalRateGesture.cancel())
    }
}

struct PlayerHorizontalRateGestureState {
    enum Action: Equatable {
        case none
        case begin(PlayerMomentaryRate)
        case end
    }

    static let activationThreshold: CGFloat = 30

    private var accumulatedDeltaX: CGFloat = 0
    private var activeRate: PlayerMomentaryRate?

    mutating func handle(
        deltaX: CGFloat,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase
    ) -> Action {
        if phase.contains(.ended) || phase.contains(.cancelled) {
            return cancel()
        }

        if !momentumPhase.isEmpty {
            return cancel()
        }

        if phase.contains(.mayBegin) || phase.contains(.began) {
            let action = cancel()
            accumulatedDeltaX = deltaX
            return action
        }

        accumulatedDeltaX += deltaX
        guard activeRate == nil,
            abs(accumulatedDeltaX) >= Self.activationThreshold
        else {
            return .none
        }

        let rate: PlayerMomentaryRate =
            accumulatedDeltaX < 0 ? .fast : .slow
        activeRate = rate
        return .begin(rate)
    }

    mutating func cancel() -> Action {
        let action: Action = activeRate == nil ? .none : .end
        accumulatedDeltaX = 0
        activeRate = nil
        return action
    }
}

struct PlayerScrollWheelRouter {
    enum Route: Equatable {
        case outerScroll
        case player
        case momentaryRate
        case discard
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
    private var directGestureHasBegun = false
    private var discardsCancelledGestureRemainder = false

    mutating func route(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        isPrecise: Bool = true,
        allowsMomentaryRate: Bool = false
    ) -> Route {
        if discardsCancelledGestureRemainder {
            let startsNewDirectGesture =
                phase.contains(.mayBegin) || phase.contains(.began)
            let startsUnphasedInput = phase.isEmpty && momentumPhase.isEmpty
            guard startsNewDirectGesture || startsUnphasedInput else {
                return .discard
            }
            discardsCancelledGestureRemainder = false
        }

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
            directGestureHasBegun = true
        } else if !directGestureHasBegun {
            return .player
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
            gestureRoute = accumulatedRoute(
                allowsMomentaryRate: allowsMomentaryRate
            )
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
        directGestureHasBegun = false
        discardsCancelledGestureRemainder = false
    }

    mutating func cancelInputSession() {
        reset()
        discardsCancelledGestureRemainder = true
    }

    private func accumulatedRoute(
        allowsMomentaryRate: Bool
    ) -> Route? {
        let horizontalMagnitude = abs(accumulatedDeltaX)
        let verticalMagnitude = abs(accumulatedDeltaY)
        let dominantMagnitude = max(horizontalMagnitude, verticalMagnitude)
        let axisLead = abs(horizontalMagnitude - verticalMagnitude)
        guard dominantMagnitude >= Self.minimumAxisTravel,
            axisLead >= Self.minimumAxisLead
        else {
            return nil
        }
        if verticalMagnitude > horizontalMagnitude {
            return .outerScroll
        }
        return allowsMomentaryRate ? .momentaryRate : .player
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
