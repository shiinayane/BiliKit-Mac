import AVKit
import BiliApplication
import BiliBrowseFeature
import BiliDanmaku
import BiliUI
import SwiftUI

/// 把唯一 `AVPlayer` 宿主与弹幕 overlay 组合为稳定的播放 surface。
///
/// 响应式页面可以重排这个 View，但不应创建第二个 player host；AppKit host 的销毁会
/// 主动断开 player 并释放弹幕 surface ownership。
struct PlayerHostView: View {
    let player: AVPlayer
    let danmakuRenderer: CoreAnimationDanmakuRenderer
    let danmakuController: DanmakuPresentationController
    let videoModel: GuestVideoViewModel?
    let beginMomentaryPlaybackRate: ((Float) -> UUID?)?
    let endMomentaryPlaybackRate: ((UUID) -> Void)?

    init(
        player: AVPlayer,
        danmakuRenderer: CoreAnimationDanmakuRenderer,
        danmakuController: DanmakuPresentationController,
        videoModel: GuestVideoViewModel? = nil,
        beginMomentaryPlaybackRate: ((Float) -> UUID?)? = nil,
        endMomentaryPlaybackRate: ((UUID) -> Void)? = nil
    ) {
        self.player = player
        self.danmakuRenderer = danmakuRenderer
        self.danmakuController = danmakuController
        self.videoModel = videoModel
        self.beginMomentaryPlaybackRate = beginMomentaryPlaybackRate
        self.endMomentaryPlaybackRate = endMomentaryPlaybackRate
    }

    var body: some View {
        AVPlayerContainerView(
            player: player,
            renderer: danmakuRenderer,
            controller: danmakuController,
            blocksNativePlaybackInteraction: blocksNativePlaybackInteraction,
            resumeNotice: videoModel?.resumeNotice,
            restartFromBeginning: { videoModel?.restartFromBeginning() },
            beginMomentaryPlaybackRate: beginMomentaryPlaybackRate,
            endMomentaryPlaybackRate: endMomentaryPlaybackRate
        )
    }

    private var blocksNativePlaybackInteraction: Bool {
        guard let videoModel else { return false }
        return switch videoModel.state {
        case .loading, .loadingPage, .preparingPlayback:
            true
        case .idle, .ready, .failed, .failedPage:
            false
        }
    }
}

private struct AVPlayerContainerView: NSViewRepresentable {
    let player: AVPlayer
    let renderer: CoreAnimationDanmakuRenderer
    let controller: DanmakuPresentationController
    let blocksNativePlaybackInteraction: Bool
    let resumeNotice: PlaybackResumeNotice?
    let restartFromBeginning: () -> Void
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
        view.setPlaybackPreparationBlocked(blocksNativePlaybackInteraction)
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.installWindowScrollWheelShield()
        view.setResumeNotice(
            resumeNotice,
            restartFromBeginning: restartFromBeginning
        )
        return view
    }

    func updateNSView(_ view: DanmakuPlayerView, context: Context) {
        view.installWindowScrollWheelShield()
        view.setPlaybackPreparationBlocked(blocksNativePlaybackInteraction)
        view.requestMomentaryPlaybackRate = beginMomentaryPlaybackRate
        view.finishMomentaryPlaybackRate = endMomentaryPlaybackRate
        view.setResumeNotice(
            resumeNotice,
            restartFromBeginning: restartFromBeginning
        )
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
        view.setResumeNotice(nil, restartFromBeginning: {})
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
        .modifier(PlayerGlassCapsuleBackground())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rate.accessibilityLabel)
    }
}

private struct PlayerGlassCapsuleBackground: ViewModifier {
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

struct PlayerResumeNoticeLayout {
    static let leadingInset: CGFloat = 20
    static let bottomInset: CGFloat = 64
}

enum PlayerResumeNoticePresentation {
    static let title = "从头播放"
}

enum PlayerResumeNoticeDismissalPolicy {
    static let delay: Duration = .seconds(5)
    static let fadeDurationSeconds: TimeInterval = 0.2

    static func shouldDismiss(
        displayedToken: PlaybackResumeToken?,
        scheduledToken: PlaybackResumeToken
    ) -> Bool {
        displayedToken == scheduledToken
    }
}

enum PlayerPlaybackPreparationPolicy {
    static func controlsStyle(
        blocksNativePlaybackInteraction: Bool
    ) -> AVPlayerViewControlsStyle {
        blocksNativePlaybackInteraction ? .none : .default
    }
}

private struct PlayerResumeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                PlayerResumeNoticePresentation.title,
                systemImage: "arrow.uturn.backward"
            )
            .fontWeight(.semibold)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .modifier(PlayerResumeButtonStyle())
        .accessibilityLabel(PlayerResumeNoticePresentation.title)
        .accessibilityHint("将当前视频定位到开头并继续播放")
    }
}

private struct PlayerResumeButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.buttonStyle(.glass)
            } else {
                fallback(content)
            }
        #else
            fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .modifier(PlayerGlassCapsuleBackground())
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
final class DanmakuPlayerView: AVPlayerView {
    let danmakuOverlay: DanmakuOverlayView
    private let scrollWheelCaptureView = PlayerScrollWheelCaptureView()
    private let windowScrollWheelShieldView = PlayerScrollWheelShieldView()
    private var installedDanmakuOverlay = false
    private var installedWindowScrollWheelShield = false
    private var momentaryRateSessionID: UUID?
    private var momentaryRateItemIdentity: ObjectIdentifier?
    private weak var observedPlayer: AVPlayer?
    private var playerItemObservation: NSKeyValueObservation?
    private var playerTimeControlObservation: NSKeyValueObservation?
    private var playerItemTimeJumpObserver: NSObjectProtocol?
    private var resumeButtonHostingView: NSHostingView<PlayerResumeButton>?
    private var displayedResumeNotice: PlaybackResumeNotice?
    private var dismissedResumeToken: PlaybackResumeToken?
    private var resumeRestartAction: (() -> Void)?
    private var resumeNoticeDismissTask: Task<Void, Never>?
    private var blocksNativePlaybackInteraction = false
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

    override var acceptsFirstResponder: Bool {
        !blocksNativePlaybackInteraction && super.acceptsFirstResponder
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !blocksNativePlaybackInteraction else { return nil }
        return super.hitTest(point)
    }

    func setPlaybackPreparationBlocked(_ blocked: Bool) {
        guard blocksNativePlaybackInteraction != blocked else { return }
        blocksNativePlaybackInteraction = blocked
        controlsStyle = PlayerPlaybackPreparationPolicy.controlsStyle(
            blocksNativePlaybackInteraction: blocked
        )
        setAccessibilityHidden(blocked)
        guard blocked,
            let window,
            let responderView = window.firstResponder as? NSView,
            responderView === self || responderView.isDescendant(of: self)
        else { return }
        window.makeFirstResponder(nil)
    }

    func setResumeNotice(
        _ notice: PlaybackResumeNotice?,
        restartFromBeginning: @escaping () -> Void
    ) {
        resumeRestartAction = restartFromBeginning
        guard let notice else {
            clearResumeNotice(markDismissed: false)
            dismissedResumeToken = nil
            return
        }
        guard dismissedResumeToken != notice.token else { return }
        if displayedResumeNotice?.token == notice.token,
            let resumeButtonHostingView
        {
            resumeButtonHostingView.rootView = makeResumeButton(
                restartFromBeginning: restartFromBeginning
            )
            return
        }
        clearResumeNotice(markDismissed: false)
        displayedResumeNotice = notice
        installResumeButtonIfPossible(
            notice: notice,
            restartFromBeginning: restartFromBeginning
        )
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
        installWindowScrollWheelShield()
        startObservingFocusLoss()
        if let displayedResumeNotice,
            resumeButtonHostingView == nil,
            let resumeRestartAction
        {
            installResumeButtonIfPossible(
                notice: displayedResumeNotice,
                restartFromBeginning: resumeRestartAction
            )
        }
    }

    override func layout() {
        super.layout()
        installWindowScrollWheelShield()
    }

    func cancelMomentaryPlaybackRate() {
        scrollWheelCaptureView.cancelInputSession()
        if momentaryRateSessionID != nil {
            endMomentaryPlaybackRate()
        }
    }

    func handleWindowSurfaceScrollWheel(_ event: NSEvent) {
        scrollWheelCaptureView.handleScrollWheel(
            event,
            playerFallbackPolicy: .consume
        )
    }

    func installWindowScrollWheelShield() {
        if !installedWindowScrollWheelShield {
            installedWindowScrollWheelShield = true
            windowScrollWheelShieldView.frame = bounds
            windowScrollWheelShieldView.autoresizingMask = [.width, .height]
            windowScrollWheelShieldView.onScrollWheel = { [weak self] event in
                self?.handleWindowSurfaceScrollWheel(event)
            }
            windowScrollWheelShieldView.onPointerExited = { [weak self] in
                self?.resetScrollInputSessionForPointerExit()
            }
        }
        if windowScrollWheelShieldView.frame != bounds {
            windowScrollWheelShieldView.frame = bounds
        }
        guard
            windowScrollWheelShieldView.superview !== self
                || subviews.last !== windowScrollWheelShieldView
        else {
            return
        }
        windowScrollWheelShieldView.removeFromSuperview()
        addSubview(
            windowScrollWheelShieldView,
            positioned: .above,
            relativeTo: nil
        )
    }

    private func resetScrollInputSessionForPointerExit() {
        scrollWheelCaptureView.resetInputSessionForPointerExit()
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
                self?.clearResumeNotice(markDismissed: true)
                self?.startObservingCurrentItemTimeJumps()
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
        startObservingCurrentItemTimeJumps()
    }

    private func startObservingCurrentItemTimeJumps() {
        if let playerItemTimeJumpObserver {
            NotificationCenter.default.removeObserver(playerItemTimeJumpObserver)
            self.playerItemTimeJumpObserver = nil
        }
        guard let item = player?.currentItem else { return }
        playerItemTimeJumpObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                    self.player?.currentItem != nil,
                    let notice = self.displayedResumeNotice
                else { return }
                let currentSeconds = self.player?.currentTime().seconds ?? .nan
                guard
                    !currentSeconds.isFinite
                        || abs(currentSeconds - notice.positionSeconds) > 0.5
                else { return }
                self.clearResumeNotice(markDismissed: true)
            }
        }
    }

    func stopObservingPlayerItemChanges() {
        playerItemObservation?.invalidate()
        playerItemObservation = nil
        playerTimeControlObservation?.invalidate()
        playerTimeControlObservation = nil
        if let playerItemTimeJumpObserver {
            NotificationCenter.default.removeObserver(playerItemTimeJumpObserver)
            self.playerItemTimeJumpObserver = nil
        }
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

    private func installResumeButtonIfPossible(
        notice: PlaybackResumeNotice,
        restartFromBeginning: @escaping () -> Void
    ) {
        guard let contentOverlayView else { return }
        let hostingView = NSHostingView(
            rootView: makeResumeButton(
                restartFromBeginning: restartFromBeginning
            )
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentOverlayView.addSubview(
            hostingView,
            positioned: .above,
            relativeTo: nil
        )
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(
                equalTo: contentOverlayView.leadingAnchor,
                constant: PlayerResumeNoticeLayout.leadingInset
            ),
            hostingView.bottomAnchor.constraint(
                equalTo: contentOverlayView.bottomAnchor,
                constant: -PlayerResumeNoticeLayout.bottomInset
            ),
        ])
        resumeButtonHostingView = hostingView
        scheduleResumeNoticeDismissal(for: notice.token)
    }

    private func makeResumeButton(
        restartFromBeginning: @escaping () -> Void
    ) -> PlayerResumeButton {
        PlayerResumeButton {
            restartFromBeginning()
        }
    }

    private func scheduleResumeNoticeDismissal(
        for token: PlaybackResumeToken
    ) {
        resumeNoticeDismissTask?.cancel()
        resumeNoticeDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: PlayerResumeNoticeDismissalPolicy.delay
                )
            } catch {
                return
            }
            guard let self,
                PlayerResumeNoticeDismissalPolicy.shouldDismiss(
                    displayedToken: self.displayedResumeNotice?.token,
                    scheduledToken: token
                )
            else { return }
            guard let hostingView = self.resumeButtonHostingView else {
                self.resumeNoticeDismissTask = nil
                self.clearResumeNotice(markDismissed: true)
                return
            }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration =
                    PlayerResumeNoticeDismissalPolicy.fadeDurationSeconds
                hostingView.animator().alphaValue = 0
            }
            guard
                !Task.isCancelled,
                PlayerResumeNoticeDismissalPolicy.shouldDismiss(
                    displayedToken: self.displayedResumeNotice?.token,
                    scheduledToken: token
                ),
                self.resumeButtonHostingView === hostingView
            else { return }
            self.resumeNoticeDismissTask = nil
            self.clearResumeNotice(markDismissed: true)
        }
    }

    private func clearResumeNotice(markDismissed: Bool) {
        resumeNoticeDismissTask?.cancel()
        resumeNoticeDismissTask = nil
        if markDismissed {
            dismissedResumeToken = displayedResumeNotice?.token
        }
        displayedResumeNotice = nil
        resumeButtonHostingView?.removeFromSuperview()
        resumeButtonHostingView = nil
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

/// 普通窗口中位于 AVPlayerView 原生子视图上方的 scroll-only direct child。
///
/// 该视图没有自己的 router 或播放状态；它只把 precise scroll-wheel 转交给
/// `contentOverlayView` capture 持有的唯一 surface coordinator。其他输入穿透给 AVKit。
@MainActor
final class PlayerScrollWheelShieldView: NSView {
    var onScrollWheel: (NSEvent) -> Void = { _ in }
    var onPointerExited: () -> Void = {}
    private var pointerTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    static func capturesEvent(
        ofType type: NSEvent.EventType?,
        isPrecise: Bool
    ) -> Bool {
        type == .scrollWheel && isPrecise
    }

    static func capturesEvent(_ event: NSEvent) -> Bool {
        guard event.type == .scrollWheel else { return false }
        return event.hasPreciseScrollingDeltas
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        return Self.capturesEvent(event) ? self : nil
    }

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel(event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .activeInKeyWindow,
                .inVisibleRect,
            ],
            owner: self
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func mouseExited(with event: NSEvent) {
        handlePointerExit()
    }

    func handlePointerExit() {
        onPointerExited()
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
        handleScrollWheel(event, playerFallbackPolicy: .dispatchToPlayer)
    }

    func handleScrollWheel(
        _ event: NSEvent,
        playerFallbackPolicy: PlayerScrollWheelPlayerFallbackPolicy
    ) {
        surfaceCapture.handleScrollWheel(
            event,
            playerFallbackPolicy: playerFallbackPolicy
        )
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

    func resetInputSessionForPointerExit() {
        surfaceCapture.resetInputSessionForPointerExit()
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
    private var pendingPlayerFallbackPolicy: PlayerScrollWheelPlayerFallbackPolicy?
    private var activePlayerFallbackPolicy: PlayerScrollWheelPlayerFallbackPolicy?
    private var previousEventPhase: NSEvent.Phase = []
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
    func handleScrollWheel(
        _ event: NSEvent,
        playerFallbackPolicy: PlayerScrollWheelPlayerFallbackPolicy =
            .dispatchToPlayer
    ) {
        defer { previousEventPhase = event.phase }
        cancelAbandonedMomentaryRate(before: event)
        flushAbandonedPendingEvents(before: event)
        let sequenceFallbackPolicy = fallbackPolicy(
            for: event,
            requested: playerFallbackPolicy
        )
        let route = scrollWheelRouter.route(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            isPrecise: event.hasPreciseScrollingDeltas,
            allowsMomentaryRate: isMomentaryRateAvailable(),
            adoptsOrphanedVerticalGesture:
                sequenceFallbackPolicy == .consume
        )
        if route == .pending {
            if pendingPlayerFallbackPolicy == nil {
                pendingPlayerFallbackPolicy = sequenceFallbackPolicy
            }
            pendingScrollWheelEvents.append(event)
            return
        }

        let events = pendingScrollWheelEvents + [event]
        pendingScrollWheelEvents.removeAll(keepingCapacity: true)
        let resolvedFallbackPolicy =
            pendingPlayerFallbackPolicy ?? sequenceFallbackPolicy
        pendingPlayerFallbackPolicy = nil
        switch route {
        case .outerScroll:
            guard let scrollView = detailScrollViewAncestor else {
                handlePlayerFallback(
                    events,
                    policy: resolvedFallbackPolicy
                )
                finishFallbackPolicyIfNeeded(after: event)
                return
            }
            for event in events {
                scrollView.scrollWheel(with: event)
            }
        case .player:
            handlePlayerFallback(events, policy: resolvedFallbackPolicy)
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
            break
        case .pending:
            assertionFailure("Pending scroll events must return before dispatch")
        }
        finishFallbackPolicyIfNeeded(after: event)
    }

    func cancelInputSession() {
        resetInputSession(quarantinesRemainder: true)
    }

    func resetInputSessionForPointerExit() {
        resetInputSession(quarantinesRemainder: false)
    }

    private func resetInputSession(quarantinesRemainder: Bool) {
        let action = horizontalRateGesture.cancel()
        pendingScrollWheelEvents.removeAll(keepingCapacity: true)
        pendingPlayerFallbackPolicy = nil
        activePlayerFallbackPolicy = nil
        if quarantinesRemainder {
            scrollWheelRouter.cancelInputSession()
        } else {
            scrollWheelRouter.resetPreservingCancellationQuarantine()
        }
        previousEventPhase = []
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

    private func handlePlayerFallback<Events: Sequence>(
        _ events: Events,
        policy: PlayerScrollWheelPlayerFallbackPolicy
    ) where Events.Element == NSEvent {
        guard policy == .dispatchToPlayer else { return }
        dispatchToAVKit(events)
    }

    private func flushAbandonedPendingEvents(
        before event: NSEvent
    ) {
        guard !pendingScrollWheelEvents.isEmpty else { return }
        let leavesDirectGesture =
            event.phase.isEmpty && event.momentumPhase.isEmpty
        guard startsNewDirectGesture(event) || leavesDirectGesture else {
            return
        }
        handlePlayerFallback(
            pendingScrollWheelEvents,
            policy: pendingPlayerFallbackPolicy ?? .dispatchToPlayer
        )
        pendingScrollWheelEvents.removeAll(keepingCapacity: true)
        pendingPlayerFallbackPolicy = nil
        activePlayerFallbackPolicy = nil
        applyHorizontalRateAction(horizontalRateGesture.cancel())
        scrollWheelRouter.reset()
        previousEventPhase = []
    }

    private func fallbackPolicy(
        for event: NSEvent,
        requested: PlayerScrollWheelPlayerFallbackPolicy
    ) -> PlayerScrollWheelPlayerFallbackPolicy {
        let startsUnphasedInput =
            event.phase.isEmpty && event.momentumPhase.isEmpty
        if startsNewDirectGesture(event) || startsUnphasedInput {
            activePlayerFallbackPolicy = requested
        } else if activePlayerFallbackPolicy == nil {
            activePlayerFallbackPolicy = requested
        }
        return activePlayerFallbackPolicy ?? requested
    }

    private func finishFallbackPolicyIfNeeded(after event: NSEvent) {
        if event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended)
            || event.momentumPhase.contains(.cancelled)
            || (event.phase.isEmpty && event.momentumPhase.isEmpty)
        {
            activePlayerFallbackPolicy = nil
        }
    }

    private func cancelAbandonedMomentaryRate(before event: NSEvent) {
        let startsUnphasedInput =
            event.phase.isEmpty && event.momentumPhase.isEmpty
        guard startsNewDirectGesture(event) || startsUnphasedInput else {
            return
        }
        applyHorizontalRateAction(horizontalRateGesture.cancel())
    }

    private func startsNewDirectGesture(_ event: NSEvent) -> Bool {
        event.phase.contains(.mayBegin)
            || (event.phase.contains(.began)
                && !previousEventPhase.contains(.mayBegin))
    }
}

enum PlayerScrollWheelPlayerFallbackPolicy: Equatable {
    case dispatchToPlayer
    case consume
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
        allowsMomentaryRate: Bool = false,
        adoptsOrphanedVerticalGesture: Bool = false
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
            guard adoptsOrphanedVerticalGesture,
                isPrecise,
                phase.contains(.changed),
                isClearlyVertical(deltaX: deltaX, deltaY: deltaY)
            else {
                return .player
            }
            reset()
            directGestureHasBegun = true
            gestureRoute = .outerScroll
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

    mutating func resetPreservingCancellationQuarantine() {
        let preservesCancellationQuarantine =
            discardsCancelledGestureRemainder
        reset()
        discardsCancelledGestureRemainder =
            preservesCancellationQuarantine
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

    private func isClearlyVertical(
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> Bool {
        let horizontalMagnitude = abs(deltaX)
        let verticalMagnitude = abs(deltaY)
        return verticalMagnitude >= Self.minimumAxisTravel
            && verticalMagnitude - horizontalMagnitude
                >= Self.minimumAxisLead
    }
}
