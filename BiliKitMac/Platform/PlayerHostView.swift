import AVKit
import BiliApplication
import BiliBrowseFeature
import BiliDanmaku
import BiliModels
import BiliPlayback
import BiliUI
import SwiftUI

/// 把唯一 `AVPlayer` 宿主与弹幕 overlay 组合为稳定的播放 surface。
///
/// 响应式页面可以重排这个 View，但不应创建第二个 player host；AppKit host 的销毁会
/// 主动断开 player 并释放弹幕 surface ownership。
struct PlayerHostView: View {
    @State private var previewEndedNotice: String?
    let player: AVPlayer
    let danmakuRenderer: CoreAnimationDanmakuRenderer
    let danmakuController: DanmakuPresentationController
    let videoModel: GuestVideoViewModel?
    let beginMomentaryPlaybackRate: ((Float) -> UUID?)?
    let endMomentaryPlaybackRate: ((UUID) -> Void)?
    let seekByTransportOffset: ((Double) -> Bool)?
    let adjustVolume: ((Float) -> Float)?
    let togglePlayback: (() -> Bool?)?
    let toggleDanmaku: (() -> Bool)?
    let toggleSubtitles: (() async -> NativeSubtitleToggleResult)?
    let timelineUpdates: (() -> AsyncStream<PlaybackTimelineSnapshot>)?

    init(
        player: AVPlayer,
        danmakuRenderer: CoreAnimationDanmakuRenderer,
        danmakuController: DanmakuPresentationController,
        videoModel: GuestVideoViewModel? = nil,
        beginMomentaryPlaybackRate: ((Float) -> UUID?)? = nil,
        endMomentaryPlaybackRate: ((UUID) -> Void)? = nil,
        seekByTransportOffset: ((Double) -> Bool)? = nil,
        adjustVolume: ((Float) -> Float)? = nil,
        togglePlayback: (() -> Bool?)? = nil,
        toggleDanmaku: (() -> Bool)? = nil,
        toggleSubtitles: (() async -> NativeSubtitleToggleResult)? = nil,
        timelineUpdates: (() -> AsyncStream<PlaybackTimelineSnapshot>)? = nil
    ) {
        self.player = player
        self.danmakuRenderer = danmakuRenderer
        self.danmakuController = danmakuController
        self.videoModel = videoModel
        self.beginMomentaryPlaybackRate = beginMomentaryPlaybackRate
        self.endMomentaryPlaybackRate = endMomentaryPlaybackRate
        self.seekByTransportOffset = seekByTransportOffset
        self.adjustVolume = adjustVolume
        self.togglePlayback = togglePlayback
        self.toggleDanmaku = toggleDanmaku
        self.toggleSubtitles = toggleSubtitles
        self.timelineUpdates = timelineUpdates
    }

    var body: some View {
        AVPlayerContainerView(
            player: player,
            renderer: danmakuRenderer,
            controller: danmakuController,
            blocksNativePlaybackInteraction: blocksNativePlaybackInteraction,
            resumeNotice: videoModel?.resumeNotice,
            previewEndedNotice: previewEndedNotice,
            restartFromBeginning: { videoModel?.restartFromBeginning() },
            beginMomentaryPlaybackRate: beginMomentaryPlaybackRate,
            endMomentaryPlaybackRate: endMomentaryPlaybackRate,
            seekByTransportOffset: seekByTransportOffset,
            adjustVolume: adjustVolume,
            togglePlayback: togglePlayback,
            toggleDanmaku: toggleDanmaku,
            toggleSubtitles: toggleSubtitles,
            focusIdentity: videoModel?.presentedBVID
        )
        .task(id: previewProjectionIdentity) {
            previewEndedNotice = nil
            guard let timelineUpdates,
                let context = videoModel?.presentedContext
            else { return }
            let identity = PlaybackItemIdentity(
                bvid: context.detail.bvid,
                cid: context.selectedPage.cid
            )
            for await snapshot in timelineUpdates() {
                guard !Task.isCancelled else { return }
                previewEndedNotice =
                    PlaybackPreviewEndPolicy.shouldPresentNotice(
                        accessNotice: context.accessNotice,
                        expectedIdentity: identity,
                        timeline: snapshot
                    )
                    ? AppStrings.localized(
                        "试看已结束，此视频为充电专属，BiliKit 暂不提供充电操作。"
                    ) : nil
            }
        }
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

    private var previewProjectionIdentity: String? {
        guard let context = videoModel?.presentedContext else { return nil }
        return
            "\(context.detail.bvid):\(context.selectedPage.cid):\(String(describing: context.accessNotice))"
    }
}

private struct AVPlayerContainerView: NSViewRepresentable {
    let player: AVPlayer
    let renderer: CoreAnimationDanmakuRenderer
    let controller: DanmakuPresentationController
    let blocksNativePlaybackInteraction: Bool
    let resumeNotice: PlaybackResumeNotice?
    let previewEndedNotice: String?
    let restartFromBeginning: () -> Void
    let beginMomentaryPlaybackRate: ((Float) -> UUID?)?
    let endMomentaryPlaybackRate: ((UUID) -> Void)?
    let seekByTransportOffset: ((Double) -> Bool)?
    let adjustVolume: ((Float) -> Float)?
    let togglePlayback: (() -> Bool?)?
    let toggleDanmaku: (() -> Bool)?
    let toggleSubtitles: (() async -> NativeSubtitleToggleResult)?
    let focusIdentity: String?

    func makeNSView(context: Context) -> DanmakuPlayerView {
        let view = DanmakuPlayerView(
            renderer: renderer,
            controller: controller,
            beginMomentaryPlaybackRate: beginMomentaryPlaybackRate,
            endMomentaryPlaybackRate: endMomentaryPlaybackRate,
            seekByTransportOffset: seekByTransportOffset,
            adjustVolume: adjustVolume,
            togglePlayback: togglePlayback,
            toggleDanmaku: toggleDanmaku,
            toggleSubtitles: toggleSubtitles
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
        view.setPreviewEndedNotice(previewEndedNotice)
        view.requestInitialKeyboardFocus(for: focusIdentity)
        return view
    }

    func updateNSView(_ view: DanmakuPlayerView, context: Context) {
        view.installWindowScrollWheelShield()
        view.setPlaybackPreparationBlocked(blocksNativePlaybackInteraction)
        view.requestMomentaryPlaybackRate = beginMomentaryPlaybackRate
        view.finishMomentaryPlaybackRate = endMomentaryPlaybackRate
        view.seekByTransportOffset = seekByTransportOffset
        view.adjustVolume = adjustVolume
        view.togglePlayback = togglePlayback
        view.toggleDanmaku = toggleDanmaku
        view.toggleSubtitles = toggleSubtitles
        view.setResumeNotice(
            resumeNotice,
            restartFromBeginning: restartFromBeginning
        )
        view.setPreviewEndedNotice(previewEndedNotice)
        view.requestInitialKeyboardFocus(for: focusIdentity)
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
        view.setPreviewEndedNotice(nil)
        view.danmakuOverlay.detachSurface()
        view.stopObservingFocusLoss()
        view.stopObservingPlayerItemChanges()
        view.stopKeyboardMonitoring()
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
        case .slow: AppStrings.localized("临时播放速度 0.5 倍")
        case .fast: AppStrings.localized("临时播放速度 2 倍")
        }
    }
}

enum PlayerShortcutFeedback: Equatable {
    case momentaryRate(PlayerMomentaryRate)
    case relativeSeek(Int)
    case volume(Int)
    case playback(Bool)
    case danmaku(Bool)
    case subtitles(NativeSubtitleToggleResult)

    var label: String {
        switch self {
        case .momentaryRate(let rate): rate.label
        case .relativeSeek(let seconds):
            seconds < 0
                ? AppStrings.localized("后退 \(-seconds) 秒")
                : AppStrings.localized("前进 \(seconds) 秒")
        case .volume(let percent): "\(percent)%"
        case .playback(let isPlaying):
            isPlaying ? AppStrings.localized("播放") : AppStrings.localized("暂停")
        case .danmaku(let enabled):
            enabled ? AppStrings.localized("弹幕 开") : AppStrings.localized("弹幕 关")
        case .subtitles(.enabled(let label)): AppStrings.localized("字幕 \(label)")
        case .subtitles(.disabled): AppStrings.localized("字幕 关")
        case .subtitles(.unavailable): AppStrings.localized("无可用字幕")
        }
    }

    var symbolName: String {
        switch self {
        case .momentaryRate(let rate): rate.symbolName
        case .relativeSeek(let seconds):
            seconds < 0 ? "gobackward.5" : "goforward.5"
        case .volume(let percent):
            percent == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .playback(let isPlaying):
            isPlaying ? "play.fill" : "pause.fill"
        case .danmaku(let enabled):
            enabled ? "text.bubble.fill" : "text.bubble"
        case .subtitles(.enabled): "captions.bubble.fill"
        case .subtitles(.disabled), .subtitles(.unavailable):
            "captions.bubble"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .momentaryRate(let rate): rate.accessibilityLabel
        case .relativeSeek(let seconds):
            seconds < 0
                ? AppStrings.localized("已后退 \(-seconds) 秒")
                : AppStrings.localized("已前进 \(seconds) 秒")
        case .volume(let percent): AppStrings.localized("播放器音量 \(percent)%")
        case .playback(let isPlaying):
            isPlaying ? AppStrings.localized("已开始播放") : AppStrings.localized("已暂停播放")
        case .danmaku(let enabled):
            enabled ? AppStrings.localized("弹幕已开启") : AppStrings.localized("弹幕已关闭")
        case .subtitles(.enabled(let label)): AppStrings.localized("字幕已开启，\(label)")
        case .subtitles(.disabled): AppStrings.localized("字幕已关闭")
        case .subtitles(.unavailable): AppStrings.localized("当前视频没有可用字幕")
        }
    }
}

enum PlayerShortcutFeedbackDismissalPolicy {
    static let delay: Duration = .milliseconds(800)
    static let fadeDuration: TimeInterval = 0.16

    static func shouldDismiss(displayedID: UUID?, scheduledID: UUID) -> Bool {
        displayedID == scheduledID
    }

    static func shouldAnimate(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }
}

private struct PlayerShortcutFeedbackBadge: View {
    let feedback: PlayerShortcutFeedback

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: feedback.symbolName)
            Text(feedback.label)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.title3.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .modifier(PlayerGlassCapsuleBackground())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(feedback.accessibilityLabel)
    }
}

private struct PlayerGlassCapsuleBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            fallbackBackground(content)
        }
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
    static var title: String { AppStrings.localized("从头播放") }
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
        blocksNativePlaybackInteraction ? .none : .floating
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
        .accessibilityHint(AppStrings.localized("将当前视频定位到开头并继续播放"))
    }
}

private struct PlayerResumeButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            fallback(content)
        }
    }

    private func fallback(_ content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .modifier(PlayerGlassCapsuleBackground())
    }
}

private struct PlayerPreviewEndedBadge: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "hourglass.bottomhalf.filled")
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.leading)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .modifier(PlayerGlassCapsuleBackground())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message)
    }
}

@MainActor
private final class PlayerPreviewEndedBadgeHostingView:
    NSHostingView<PlayerPreviewEndedBadge>
{
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class PlayerShortcutFeedbackBadgeHostingView:
    NSHostingView<PlayerShortcutFeedbackBadge>
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
    private var momentaryRatePressID: UUID?
    private weak var observedPlayer: AVPlayer?
    private var playerItemObservation: NSKeyValueObservation?
    private var playerTimeControlObservation: NSKeyValueObservation?
    private var playerItemTimeJumpObserver: NSObjectProtocol?
    private var resumeButtonHostingView: NSHostingView<PlayerResumeButton>?
    private var previewEndedHostingView: PlayerPreviewEndedBadgeHostingView?
    private var displayedPreviewEndedNotice: String?
    private var displayedResumeNotice: PlaybackResumeNotice?
    private var dismissedResumeToken: PlaybackResumeToken?
    private var resumeRestartAction: (() -> Void)?
    private var resumeNoticeDismissTask: Task<Void, Never>?
    private var blocksNativePlaybackInteraction = false
    private var lastInitialFocusIdentity: String?
    private var pendingInitialFocusIdentity: String?
    private var appResignObserver: NSObjectProtocol?
    private var windowResignObserver: NSObjectProtocol?
    var requestMomentaryPlaybackRate: ((Float) -> UUID?)?
    var finishMomentaryPlaybackRate: ((UUID) -> Void)?
    var seekByTransportOffset: ((Double) -> Bool)?
    var adjustVolume: ((Float) -> Float)?
    var togglePlayback: (() -> Bool?)?
    var toggleDanmaku: (() -> Bool)?
    var toggleSubtitles: (() async -> NativeSubtitleToggleResult)?

    init(
        renderer: CoreAnimationDanmakuRenderer,
        controller: DanmakuPresentationController,
        beginMomentaryPlaybackRate: ((Float) -> UUID?)?,
        endMomentaryPlaybackRate: ((UUID) -> Void)?,
        seekByTransportOffset: ((Double) -> Bool)? = nil,
        adjustVolume: ((Float) -> Float)? = nil,
        togglePlayback: (() -> Bool?)? = nil,
        toggleDanmaku: (() -> Bool)? = nil,
        toggleSubtitles: (() async -> NativeSubtitleToggleResult)? = nil
    ) {
        danmakuOverlay = DanmakuOverlayView(
            renderer: renderer,
            controller: controller
        )
        requestMomentaryPlaybackRate = beginMomentaryPlaybackRate
        finishMomentaryPlaybackRate = endMomentaryPlaybackRate
        self.seekByTransportOffset = seekByTransportOffset
        self.adjustVolume = adjustVolume
        self.togglePlayback = togglePlayback
        self.toggleDanmaku = toggleDanmaku
        self.toggleSubtitles = toggleSubtitles
        super.init(frame: .zero)
        updatesNowPlayingInfoCenter = false
        scrollWheelCaptureView.onKeyboardMomentaryRateBegan = {
            [weak self] rate, pressID in
            self?.beginMomentaryPlaybackRate(rate, pressID: pressID)
        }
        scrollWheelCaptureView.onKeyboardMomentaryRateEnded = {
            [weak self] pressID in
            self?.endMomentaryPlaybackRate(ifPressID: pressID)
        }
        scrollWheelCaptureView.onRelativeSeek = { [weak self] offset in
            self?.seekByTransportOffset?(offset) ?? false
        }
        scrollWheelCaptureView.onVolumeStep = { [weak self] offset in
            self?.adjustVolume?(offset)
        }
        scrollWheelCaptureView.onTogglePlayback = { [weak self] in
            guard let togglePlayback = self?.togglePlayback else { return nil }
            return togglePlayback()
        }
        scrollWheelCaptureView.onToggleDanmaku = { [weak self] in
            self?.toggleDanmaku?()
        }
        scrollWheelCaptureView.onToggleSubtitles = { [weak self] in
            guard let toggleSubtitles = self?.toggleSubtitles else {
                return .unavailable
            }
            return await toggleSubtitles()
        }
        installDanmakuOverlayIfNeeded()
    }

    override var acceptsFirstResponder: Bool {
        !blocksNativePlaybackInteraction
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !blocksNativePlaybackInteraction else { return nil }
        return super.hitTest(point)
    }

    func setPlaybackPreparationBlocked(_ blocked: Bool) {
        let stateChanged = blocksNativePlaybackInteraction != blocked
        blocksNativePlaybackInteraction = blocked
        controlsStyle = PlayerPlaybackPreparationPolicy.controlsStyle(
            blocksNativePlaybackInteraction: blocked
        )
        setAccessibilityHidden(blocked)
        scrollWheelCaptureView.setKeyboardInputEnabled(!blocked)
        guard stateChanged else {
            if !blocked {
                applyPendingInitialKeyboardFocus()
            }
            return
        }
        if blocked {
            cancelMomentaryPlaybackRate()
        }
        if !blocked {
            applyPendingInitialKeyboardFocus()
        }
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

    func setPreviewEndedNotice(_ message: String?) {
        displayedPreviewEndedNotice = message
        guard let message else {
            previewEndedHostingView?.removeFromSuperview()
            previewEndedHostingView = nil
            return
        }
        if let previewEndedHostingView {
            previewEndedHostingView.rootView = PlayerPreviewEndedBadge(message: message)
            return
        }
        guard let contentOverlayView else { return }
        let hostingView = PlayerPreviewEndedBadgeHostingView(
            rootView: PlayerPreviewEndedBadge(message: message)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentOverlayView.addSubview(hostingView, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            hostingView.centerXAnchor.constraint(equalTo: contentOverlayView.centerXAnchor),
            hostingView.bottomAnchor.constraint(
                equalTo: contentOverlayView.bottomAnchor,
                constant: -64
            ),
            hostingView.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentOverlayView.leadingAnchor,
                constant: 20
            ),
            hostingView.trailingAnchor.constraint(
                lessThanOrEqualTo: contentOverlayView.trailingAnchor,
                constant: -20
            ),
        ])
        previewEndedHostingView = hostingView
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
        applyPendingInitialKeyboardFocus()
        if let displayedResumeNotice,
            resumeButtonHostingView == nil,
            let resumeRestartAction
        {
            installResumeButtonIfPossible(
                notice: displayedResumeNotice,
                restartFromBeginning: resumeRestartAction
            )
        }
        if previewEndedHostingView == nil,
            let message = displayedPreviewEndedNotice
        {
            setPreviewEndedNotice(message)
        }
    }

    override func layout() {
        super.layout()
        installWindowScrollWheelShield()
    }

    func requestInitialKeyboardFocus(for identity: String?) {
        guard let identity, identity != lastInitialFocusIdentity else { return }
        pendingInitialFocusIdentity = identity
        applyPendingInitialKeyboardFocus()
    }

    private func applyPendingInitialKeyboardFocus() {
        guard !blocksNativePlaybackInteraction,
            let identity = pendingInitialFocusIdentity,
            let window
        else { return }
        pendingInitialFocusIdentity = nil
        lastInitialFocusIdentity = identity
        window.makeFirstResponder(self)
    }

    func cancelMomentaryPlaybackRate() {
        scrollWheelCaptureView.cancelInputSession()
        if momentaryRateSessionID != nil {
            endMomentaryPlaybackRate()
        }
    }

    func handleWindowSurfaceScrollWheel(_ event: NSEvent) {
        scrollWheelCaptureView.handleScrollWheel(event)
    }

    func installWindowScrollWheelShield() {
        if !installedWindowScrollWheelShield {
            installedWindowScrollWheelShield = true
            windowScrollWheelShieldView.frame = bounds
            windowScrollWheelShieldView.autoresizingMask = [.width, .height]
            windowScrollWheelShieldView.onScrollWheel = { [weak self] event in
                self?.handleWindowSurfaceScrollWheel(event)
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

    func startObservingPlayerItemChanges() {
        guard observedPlayer !== player else { return }
        stopObservingPlayerItemChanges()
        guard let player else { return }
        observedPlayer = player
        playerItemObservation = player.observe(\.currentItem, options: [.new]) {
            [weak self] _, _ in
            Task { @MainActor in
                self?.cancelMomentaryPlaybackRate()
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
                self?.cancelMomentaryPlaybackRate()
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

    private func beginMomentaryPlaybackRate(
        _ rate: PlayerMomentaryRate,
        pressID: UUID
    ) {
        if momentaryRatePressID != pressID {
            endMomentaryPlaybackRate()
        }
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
        momentaryRatePressID = pressID
        scrollWheelCaptureView.showMomentaryRateBadge(rate)
    }

    private func endMomentaryPlaybackRate(ifPressID pressID: UUID) {
        guard momentaryRatePressID == pressID else { return }
        endMomentaryPlaybackRate()
    }

    private func endMomentaryPlaybackRate() {
        if let momentaryRateSessionID {
            finishMomentaryPlaybackRate?(momentaryRateSessionID)
        }
        clearMomentaryPlaybackRate()
    }

    private func clearMomentaryPlaybackRate() {
        momentaryRateSessionID = nil
        momentaryRatePressID = nil
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

    func stopKeyboardMonitoring() {
        scrollWheelCaptureView.stopKeyboardMonitoring()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

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

    static func capturesEvent(
        ofType type: NSEvent.EventType?
    ) -> Bool {
        type == .scrollWheel
    }

    static func capturesEvent(_ event: NSEvent) -> Bool {
        capturesEvent(ofType: event.type)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        return Self.capturesEvent(event) ? self : nil
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
@MainActor
final class PlayerScrollWheelCaptureView: NSView {
    private enum KeyboardKey: Sendable {
        case direction(PlayerKeyboardDirection)
        case shortcut(PlayerKeyboardShortcut)
    }

    private struct KeyboardEventSnapshot: Sendable {
        let type: NSEvent.EventType
        let key: KeyboardKey
        let hasDisallowedModifier: Bool
        let isRepeat: Bool
        let timestamp: TimeInterval
        let windowNumber: Int
    }

    private var windowResignObserver: NSObjectProtocol?
    private var keyboardMonitor: Any?
    private var keyboardInputEnabled = true
    private var keyboardState = PlayerKeyboardInputState()
    private var scrollWheelRouting = PlayerScrollWheelRouting()
    private var pendingScrollWheelEvents: [NSEvent] = []
    private var keyboardLongPressTask: Task<Void, Never>?
    private var keyboardLongPressID: UUID?
    private var subtitleToggleTask: Task<Void, Never>?
    private var feedbackBadge: NSView?
    private var displayedFeedback: PlayerShortcutFeedback?
    private var feedbackDismissTask: Task<Void, Never>?
    private var feedbackFadeTask: Task<Void, Never>?
    private var feedbackID: UUID?
    var onKeyboardMomentaryRateBegan: (PlayerMomentaryRate, UUID) -> Void = {
        _,
        _ in
    }
    var onKeyboardMomentaryRateEnded: (UUID) -> Void = { _ in }
    var onRelativeSeek: (Double) -> Bool = { _ in false }
    var onVolumeStep: (Float) -> Float? = { _ in nil }
    var onTogglePlayback: () -> Bool? = { nil }
    var onToggleDanmaku: () -> Bool? = { nil }
    var onToggleSubtitles: () async -> NativeSubtitleToggleResult = {
        .unavailable
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
        handleScrollWheel(event)
    }

    func handleScrollWheel(_ event: NSEvent) {
        let route = scrollWheelRouting.route(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            phase: event.phase,
            momentumPhase: event.momentumPhase
        )
        switch route {
        case .pending:
            pendingScrollWheelEvents.append(event)
        case .ignore:
            pendingScrollWheelEvents.removeAll(keepingCapacity: true)
        case .outerScroll:
            guard let scrollView = detailScrollViewAncestor else {
                pendingScrollWheelEvents.removeAll(keepingCapacity: true)
                return
            }
            for pendingEvent in pendingScrollWheelEvents {
                scrollView.scrollWheel(with: pendingEvent)
            }
            pendingScrollWheelEvents.removeAll(keepingCapacity: true)
            scrollView.scrollWheel(with: event)
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
        startKeyboardMonitoring()
        guard windowResignObserver == nil else { return }
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
        scrollWheelRouting.cancel()
        pendingScrollWheelEvents.removeAll(keepingCapacity: true)
        cancelKeyboardInputSession()
    }

    func setKeyboardInputEnabled(_ enabled: Bool) {
        guard keyboardInputEnabled != enabled else { return }
        keyboardInputEnabled = enabled
        if !enabled {
            cancelKeyboardInputSession()
        }
    }

    private func cancelKeyboardInputSession() {
        applyKeyboardActions(keyboardState.cancel())
        keyboardLongPressTask?.cancel()
        keyboardLongPressTask = nil
        keyboardLongPressID = nil
        subtitleToggleTask?.cancel()
        subtitleToggleTask = nil
        clearFeedback()
    }

    func showMomentaryRateBadge(_ rate: PlayerMomentaryRate) {
        feedbackDismissTask?.cancel()
        feedbackDismissTask = nil
        feedbackID = nil
        showFeedback(.momentaryRate(rate))
    }

    func clearMomentaryRateBadge() {
        guard case .momentaryRate = displayedFeedback else { return }
        dismissFeedbackAnimated()
    }

    func startKeyboardMonitoring() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .leftMouseDown]
        ) { [weak self] event in
            if event.type == .leftMouseDown {
                DispatchQueue.main.async { @MainActor [weak self] in
                    self?.cancelIfEditableResponder()
                }
                return event
            }
            guard let snapshot = Self.keyboardSnapshot(from: event) else {
                DispatchQueue.main.async { @MainActor [weak self] in
                    self?.cancelIfEditableResponder()
                }
                return event
            }
            let consumed = MainActor.assumeIsolated {
                self?.handleKeyboardEvent(snapshot) == true
            }
            return consumed ? nil : event
        }
    }

    func stopKeyboardMonitoring() {
        cancelInputSession()
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
        stopObservingWindowFocusLoss()
    }

    private func handleKeyboardEvent(_ event: KeyboardEventSnapshot) -> Bool {
        guard let captureWindow = window else { return false }
        let isEditable = Self.isEditable(captureWindow.firstResponder)
        guard
            PlayerKeyboardEventScope.captures(
                isEnabled: keyboardInputEnabled,
                isSupportedKey: true,
                hasDisallowedModifier: event.hasDisallowedModifier,
                eventMatchesCaptureWindow:
                    event.windowNumber == captureWindow.windowNumber,
                isEditableResponder: isEditable
            )
        else {
            if !keyboardInputEnabled
                || event.hasDisallowedModifier
                || isEditable
            {
                cancelKeyboardInputSession()
            }
            return false
        }

        let actions: [PlayerKeyboardInputState.Action]
        switch (event.type, event.key) {
        case (.keyDown, .direction(let direction)):
            actions = keyboardState.keyDown(
                direction,
                isRepeat: event.isRepeat,
                timestamp: event.timestamp
            )
        case (.keyUp, .direction(let direction)):
            actions = keyboardState.keyUp(direction)
        case (.keyDown, .shortcut(let shortcut)):
            actions = keyboardState.shortcutKeyDown(
                shortcut,
                isRepeat: event.isRepeat
            )
        case (.keyUp, .shortcut(let shortcut)):
            actions = keyboardState.shortcutKeyUp(shortcut)
        default:
            return false
        }
        applyKeyboardActions(actions)
        return true
    }

    private func applyKeyboardActions(
        _ actions: [PlayerKeyboardInputState.Action]
    ) {
        for action in actions {
            switch action {
            case .scheduleLongPress(let pressID):
                keyboardLongPressTask?.cancel()
                keyboardLongPressID = pressID
                keyboardLongPressTask = Task { [weak self] in
                    do {
                        try await Task.sleep(
                            for: .seconds(
                                PlayerKeyboardInputState.longPressDelay
                            )
                        )
                    } catch {
                        return
                    }
                    guard let self, self.keyboardLongPressID == pressID else {
                        return
                    }
                    self.keyboardLongPressTask = nil
                    self.keyboardLongPressID = nil
                    self.applyKeyboardActions(
                        self.keyboardState.deadlineReached(pressID: pressID)
                    )
                }
            case .cancelLongPress(let pressID):
                guard keyboardLongPressID == pressID else { break }
                keyboardLongPressTask?.cancel()
                keyboardLongPressTask = nil
                keyboardLongPressID = nil
            case .beginMomentaryRate(let rate, let pressID):
                onKeyboardMomentaryRateBegan(rate, pressID)
            case .endMomentaryRate(let pressID):
                onKeyboardMomentaryRateEnded(pressID)
            case .seekBy(let seconds):
                if onRelativeSeek(seconds) {
                    showTransientFeedback(
                        .relativeSeek(Int(seconds.rounded()))
                    )
                }
            case .adjustVolume(let offset):
                if let volume = onVolumeStep(offset) {
                    showTransientFeedback(
                        .volume(Int((volume * 100).rounded()))
                    )
                }
            case .togglePlayback:
                if let isPlaying = onTogglePlayback() {
                    showTransientFeedback(.playback(isPlaying))
                }
            case .toggleDanmaku:
                if let enabled = onToggleDanmaku() {
                    showTransientFeedback(.danmaku(enabled))
                }
            case .toggleSubtitles:
                subtitleToggleTask?.cancel()
                subtitleToggleTask = Task { [weak self] in
                    guard let self else { return }
                    let result = await self.onToggleSubtitles()
                    guard !Task.isCancelled else { return }
                    self.subtitleToggleTask = nil
                    self.showTransientFeedback(.subtitles(result))
                }
            }
        }
    }

    private func showTransientFeedback(_ feedback: PlayerShortcutFeedback) {
        feedbackDismissTask?.cancel()
        let identity = UUID()
        feedbackID = identity
        showFeedback(feedback)
        feedbackDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: PlayerShortcutFeedbackDismissalPolicy.delay
                )
            } catch {
                return
            }
            guard let self,
                PlayerShortcutFeedbackDismissalPolicy.shouldDismiss(
                    displayedID: self.feedbackID,
                    scheduledID: identity
                )
            else { return }
            self.dismissFeedbackAnimated()
        }
    }

    private func showFeedback(_ feedback: PlayerShortcutFeedback) {
        feedbackFadeTask?.cancel()
        feedbackFadeTask = nil
        feedbackBadge?.removeFromSuperview()
        let badge = PlayerShortcutFeedbackBadgeHostingView(
            rootView: PlayerShortcutFeedbackBadge(feedback: feedback)
        )
        badge.alphaValue = 1
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 20),
        ])
        feedbackBadge = badge
        displayedFeedback = feedback
    }

    private func dismissFeedbackAnimated() {
        feedbackDismissTask?.cancel()
        feedbackDismissTask = nil
        feedbackID = nil
        feedbackFadeTask?.cancel()
        feedbackFadeTask = nil
        guard let badge = feedbackBadge else {
            displayedFeedback = nil
            return
        }
        guard
            PlayerShortcutFeedbackDismissalPolicy.shouldAnimate(
                reduceMotion: NSWorkspace.shared
                    .accessibilityDisplayShouldReduceMotion
            )
        else {
            clearFeedback()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = PlayerShortcutFeedbackDismissalPolicy.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            badge.animator().alphaValue = 0
        }
        feedbackFadeTask = Task { [weak self, weak badge] in
            do {
                try await Task.sleep(
                    for: .seconds(
                        PlayerShortcutFeedbackDismissalPolicy.fadeDuration
                    )
                )
            } catch {
                return
            }
            guard let self, let badge, self.feedbackBadge === badge else {
                return
            }
            self.feedbackFadeTask = nil
            badge.removeFromSuperview()
            self.feedbackBadge = nil
            self.displayedFeedback = nil
        }
    }

    private func clearFeedback() {
        feedbackDismissTask?.cancel()
        feedbackDismissTask = nil
        feedbackFadeTask?.cancel()
        feedbackFadeTask = nil
        feedbackID = nil
        feedbackBadge?.removeFromSuperview()
        feedbackBadge = nil
        displayedFeedback = nil
    }

    private func cancelIfEditableResponder() {
        guard let window, Self.isEditable(window.firstResponder) else { return }
        cancelKeyboardInputSession()
    }

    private static func isEditable(_ responder: NSResponder?) -> Bool {
        switch responder {
        case let textView as NSTextView:
            textView.isEditable
        case let textField as NSTextField:
            textField.isEditable
        default:
            false
        }
    }

    private nonisolated static func keyboardSnapshot(
        from event: NSEvent
    ) -> KeyboardEventSnapshot? {
        let key: KeyboardKey
        switch event.specialKey {
        case .leftArrow: key = .direction(.left)
        case .rightArrow: key = .direction(.right)
        case .upArrow: key = .direction(.up)
        case .downArrow: key = .direction(.down)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ": key = .shortcut(.playback)
            case "d": key = .shortcut(.danmaku)
            case "c": key = .shortcut(.subtitles)
            default: return nil
            }
        }
        let disallowedModifiers: NSEvent.ModifierFlags = [
            .command, .control, .option, .shift,
        ]
        return KeyboardEventSnapshot(
            type: event.type,
            key: key,
            hasDisallowedModifier:
                !event.modifierFlags.intersection(disallowedModifiers).isEmpty,
            isRepeat: event.isARepeat,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber
        )
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

struct PlayerScrollWheelRouting {
    enum Route: Equatable {
        case pending
        case outerScroll
        case ignore
    }

    private static let minimumAxisTravel: CGFloat = 1
    private static let minimumAxisLead: CGFloat = 0.5

    private var directRoute: Route?
    private var completedRoute: Route?
    private var accumulatedDeltaX: CGFloat = 0
    private var accumulatedDeltaY: CGFloat = 0
    private var directGestureIsActive = false
    private var discardsCancelledRemainder = false

    mutating func route(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase
    ) -> Route {
        let startsDirectGesture =
            phase.contains(.mayBegin) || phase.contains(.began)
        let isUnphasedInput = phase.isEmpty && momentumPhase.isEmpty

        if discardsCancelledRemainder {
            guard startsDirectGesture || isUnphasedInput else {
                return .ignore
            }
            discardsCancelledRemainder = false
        }

        if !momentumPhase.isEmpty {
            let route =
                directRoute
                ?? completedRoute
                ?? dominantRoute(deltaX: deltaX, deltaY: deltaY)
            if momentumPhase.contains(.ended)
                || momentumPhase.contains(.cancelled)
            {
                reset()
            }
            return route
        }

        if phase.isEmpty {
            completedRoute = nil
            return dominantRoute(deltaX: deltaX, deltaY: deltaY)
        }

        if startsDirectGesture {
            reset()
            directGestureIsActive = true
        } else if !directGestureIsActive {
            guard phase.contains(.changed) else { return .ignore }
            directGestureIsActive = true
            directRoute = dominantRoute(deltaX: deltaX, deltaY: deltaY)
        }

        if directRoute == nil {
            accumulatedDeltaX += deltaX
            accumulatedDeltaY += deltaY
            directRoute = accumulatedRoute()
        }

        let resolvedRoute: Route
        if phase.contains(.ended) || phase.contains(.cancelled) {
            resolvedRoute =
                directRoute
                ?? dominantRoute(
                    deltaX: accumulatedDeltaX,
                    deltaY: accumulatedDeltaY
                )
            if phase.contains(.ended) {
                completedRoute = resolvedRoute
                resetDirectGesture()
            } else {
                reset()
            }
        } else {
            resolvedRoute = directRoute ?? .pending
        }
        return resolvedRoute
    }

    mutating func cancel() {
        reset()
        discardsCancelledRemainder = true
    }

    private func accumulatedRoute() -> Route? {
        let horizontalMagnitude = abs(accumulatedDeltaX)
        let verticalMagnitude = abs(accumulatedDeltaY)
        guard
            max(horizontalMagnitude, verticalMagnitude)
                >= Self.minimumAxisTravel,
            abs(verticalMagnitude - horizontalMagnitude)
                >= Self.minimumAxisLead
        else { return nil }
        return verticalMagnitude > horizontalMagnitude ? .outerScroll : .ignore
    }

    private func dominantRoute(deltaX: CGFloat, deltaY: CGFloat) -> Route {
        abs(deltaY) > abs(deltaX) ? .outerScroll : .ignore
    }

    private mutating func resetDirectGesture() {
        directRoute = nil
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        directGestureIsActive = false
    }

    private mutating func reset() {
        resetDirectGesture()
        completedRoute = nil
    }
}
