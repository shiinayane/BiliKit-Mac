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
    let videoModel: VideoViewModel?
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
        videoModel: VideoViewModel? = nil,
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

/// 播放器浮层相对 content overlay 的位置；底部留出原生控制条的高度。
enum PlayerOverlayLayout {
    static let edgeInset: CGFloat = 20
    static let bottomInset: CGFloat = 64
}

enum PlayerResumeNoticePresentation {
    static var title: String { AppStrings.localized("从头播放") }
}

enum PlayerResumeNoticeDismissalPolicy {
    static let delay: Duration = .seconds(5)
    static let fadeDurationSeconds: TimeInterval = 0.2
    /// 时间跳转后离续播位置超过该秒数即视为用户已自行定位，收起“从头播放”。
    static let positionToleranceSeconds: Double = 0.5
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

/// 默认不接收鼠标事件的浮层 hosting view。
///
/// `interactiveFrame` 返回本视图坐标（左上原点）中的可交互区域时，只有该区域照常命中 SwiftUI 内容；
/// 其余点击、拖动与悬停穿透给下方的 AVKit 视图。
@MainActor
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var interactiveFrame: () -> CGRect? = { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let frame = interactiveFrame(),
            frame.contains(convert(point, from: superview))
        else { return nil }
        return super.hitTest(point)
    }
}

/// 播放器 content overlay 上的全部临时提示：快捷键反馈、“从头播放”按钮与试看结束徽章。
///
/// 自动消失的计时由 `PlayerOverlayView` 的 `.task(id:)` 持有；这里只保存状态与 identity 规则。
@MainActor
@Observable
final class PlayerOverlayModel {
    struct Feedback: Equatable {
        let id = UUID()
        let content: PlayerShortcutFeedback
        /// 临时倍速在按住期间保持显示；其他反馈到时自动消失。
        let dismissesAutomatically: Bool
    }

    private(set) var feedback: Feedback?
    private(set) var resumeNotice: PlaybackResumeNotice?
    private(set) var previewEndedMessage: String?
    @ObservationIgnored private(set) var restartFromBeginning: () -> Void = {}
    @ObservationIgnored private var dismissedResumeToken: PlaybackResumeToken?
    @ObservationIgnored fileprivate var resumeButtonFrame: CGRect?

    /// 只有“从头播放”按钮接收鼠标；坐标为 overlay 根视图空间。
    var interactiveFrame: CGRect? {
        resumeNotice == nil ? nil : resumeButtonFrame
    }

    func showFeedback(_ content: PlayerShortcutFeedback) {
        feedback = Feedback(content: content, dismissesAutomatically: true)
    }

    func showMomentaryRate(_ rate: PlayerMomentaryRate) {
        feedback = Feedback(content: .momentaryRate(rate), dismissesAutomatically: false)
    }

    func endMomentaryRate() {
        guard case .momentaryRate = feedback?.content else { return }
        fadeOutFeedback()
    }

    func expireFeedback(id: UUID) {
        guard feedback?.id == id else { return }
        fadeOutFeedback()
    }

    func clearFeedback() {
        feedback = nil
    }

    func setResumeNotice(
        _ notice: PlaybackResumeNotice?,
        restartFromBeginning: @escaping () -> Void
    ) {
        self.restartFromBeginning = restartFromBeginning
        guard let notice else {
            clearResumeNotice(markDismissed: false)
            dismissedResumeToken = nil
            return
        }
        guard notice.token != dismissedResumeToken,
            notice.token != resumeNotice?.token
        else { return }
        resumeNotice = notice
    }

    /// 自动消失：淡出并记住 token，同一次续播不再出现。
    func expireResumeNotice(token: PlaybackResumeToken) {
        guard resumeNotice?.token == token else { return }
        withAnimation(
            .easeInOut(duration: PlayerResumeNoticeDismissalPolicy.fadeDurationSeconds)
        ) {
            clearResumeNotice(markDismissed: true)
        }
    }

    /// 播放项目时间跳转后离开续播位置即收起提示；位置未知时同样收起。
    func observeTimeJump(toSeconds seconds: Double) {
        guard let resumeNotice,
            !seconds.isFinite
                || abs(seconds - resumeNotice.positionSeconds)
                    > PlayerResumeNoticeDismissalPolicy.positionToleranceSeconds
        else { return }
        clearResumeNotice(markDismissed: true)
    }

    func clearResumeNotice(markDismissed: Bool) {
        if markDismissed {
            dismissedResumeToken = resumeNotice?.token
        }
        guard resumeNotice != nil else { return }
        resumeNotice = nil
    }

    func setPreviewEndedMessage(_ message: String?) {
        guard previewEndedMessage != message else { return }
        previewEndedMessage = message
    }

    private func fadeOutFeedback() {
        withAnimation(.easeInOut(duration: PlayerShortcutFeedbackDismissalPolicy.fadeDuration)) {
            feedback = nil
        }
    }
}

/// 所有播放器浮层共用的一棵 SwiftUI 树，铺满 content overlay。
struct PlayerOverlayView: View {
    private static let coordinateSpace = "PlayerOverlay"

    let model: PlayerOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .overlay(alignment: .top) { feedbackBadge }
            .overlay(alignment: .bottomLeading) { resumeButton }
            .overlay(alignment: .bottom) { previewEndedBadge }
            .coordinateSpace(.named(Self.coordinateSpace))
    }

    @ViewBuilder
    private var feedbackBadge: some View {
        if let feedback = model.feedback {
            PlayerShortcutFeedbackBadge(feedback: feedback.content)
                .padding(.top, PlayerOverlayLayout.edgeInset)
                .transition(reduceMotion ? .identity : .opacity)
                .task(id: feedback.id) {
                    guard feedback.dismissesAutomatically else { return }
                    try? await Task.sleep(for: PlayerShortcutFeedbackDismissalPolicy.delay)
                    guard !Task.isCancelled else { return }
                    model.expireFeedback(id: feedback.id)
                }
        }
    }

    @ViewBuilder
    private var resumeButton: some View {
        if let notice = model.resumeNotice {
            PlayerResumeButton { model.restartFromBeginning() }
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(Self.coordinateSpace))
                } action: { frame in
                    model.resumeButtonFrame = frame
                }
                .padding(.leading, PlayerOverlayLayout.edgeInset)
                .padding(.bottom, PlayerOverlayLayout.bottomInset)
                .transition(.opacity)
                .task(id: notice.token) {
                    try? await Task.sleep(for: PlayerResumeNoticeDismissalPolicy.delay)
                    guard !Task.isCancelled else { return }
                    model.expireResumeNotice(token: notice.token)
                }
        }
    }

    @ViewBuilder
    private var previewEndedBadge: some View {
        if let message = model.previewEndedMessage {
            PlayerPreviewEndedBadge(message: message)
                .padding(.horizontal, PlayerOverlayLayout.edgeInset)
                .padding(.bottom, PlayerOverlayLayout.bottomInset)
        }
    }
}

/// 打开时独占方向键等按键的浮层；播放器快捷键不会越过它。
@MainActor
protocol PlayerKeyboardFocusOwner: NSView {}

@MainActor
final class DanmakuPlayerView: AVPlayerView {
    let danmakuOverlay: DanmakuOverlayView
    private let scrollWheelCaptureView = PlayerScrollWheelCaptureView()
    private let windowScrollWheelShieldView = PlayerScrollWheelShieldView()
    private let overlayModel = PlayerOverlayModel()
    private let overlayHostingView: PassthroughHostingView<PlayerOverlayView>
    private var installedDanmakuOverlay = false
    private var installedWindowScrollWheelShield = false
    private var momentaryRateSessionID: UUID?
    private var momentaryRatePressID: UUID?
    private weak var observedPlayer: AVPlayer?
    private var playerItemObservation: NSKeyValueObservation?
    private var playerTimeControlObservation: NSKeyValueObservation?
    private var playerItemTimeJumpObservers = NativeVideoNotificationObservers()
    private var blocksNativePlaybackInteraction = false
    private var lastInitialFocusIdentity: String?
    private var pendingInitialFocusIdentity: String?
    private var focusLossObservers = NativeVideoNotificationObservers()
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
        overlayHostingView = PassthroughHostingView(
            rootView: PlayerOverlayView(model: overlayModel)
        )
        super.init(frame: .zero)
        updatesNowPlayingInfoCenter = false
        overlayHostingView.sizingOptions = []
        overlayHostingView.interactiveFrame = { [overlayModel] in
            overlayModel.interactiveFrame
        }
        let keyboardShortcuts = scrollWheelCaptureView.keyboardShortcuts
        keyboardShortcuts.feedbackPresenter = overlayModel
        keyboardShortcuts.onKeyboardMomentaryRateBegan = {
            [weak self] rate, pressID in
            self?.beginMomentaryPlaybackRate(rate, pressID: pressID)
        }
        keyboardShortcuts.onKeyboardMomentaryRateEnded = {
            [weak self] pressID in
            self?.endMomentaryPlaybackRate(ifPressID: pressID)
        }
        keyboardShortcuts.onRelativeSeek = { [weak self] offset in
            self?.seekByTransportOffset?(offset) ?? false
        }
        keyboardShortcuts.onVolumeStep = { [weak self] offset in
            self?.adjustVolume?(offset)
        }
        keyboardShortcuts.onTogglePlayback = { [weak self] in
            guard let togglePlayback = self?.togglePlayback else { return nil }
            return togglePlayback()
        }
        keyboardShortcuts.onToggleDanmaku = { [weak self] in
            self?.toggleDanmaku?()
        }
        keyboardShortcuts.onToggleSubtitles = { [weak self] in
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
        scrollWheelCaptureView.keyboardShortcuts.setKeyboardInputEnabled(!blocked)
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
        overlayModel.setResumeNotice(notice, restartFromBeginning: restartFromBeginning)
    }

    func setPreviewEndedNotice(_ message: String?) {
        overlayModel.setPreviewEndedMessage(message)
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
                self?.overlayModel.clearResumeNotice(markDismissed: true)
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
        playerItemTimeJumpObservers.removeAll()
        guard let item = player?.currentItem else { return }
        playerItemTimeJumpObservers.observe(
            AVPlayerItem.timeJumpedNotification,
            object: item
        ) { [weak self] in
            guard let self, let player = self.player, player.currentItem != nil
            else { return }
            self.overlayModel.observeTimeJump(toSeconds: player.currentTime().seconds)
        }
    }

    func stopObservingPlayerItemChanges() {
        playerItemObservation?.invalidate()
        playerItemObservation = nil
        playerTimeControlObservation?.invalidate()
        playerTimeControlObservation = nil
        playerItemTimeJumpObservers.removeAll()
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
        overlayHostingView.translatesAutoresizingMaskIntoConstraints = false
        contentOverlayView.addSubview(
            overlayHostingView,
            positioned: .above,
            relativeTo: scrollWheelCaptureView
        )
        NSLayoutConstraint.activate([
            overlayHostingView.leadingAnchor.constraint(
                equalTo: contentOverlayView.leadingAnchor
            ),
            overlayHostingView.trailingAnchor.constraint(
                equalTo: contentOverlayView.trailingAnchor
            ),
            overlayHostingView.topAnchor.constraint(
                equalTo: contentOverlayView.topAnchor
            ),
            overlayHostingView.bottomAnchor.constraint(
                equalTo: contentOverlayView.bottomAnchor
            ),
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
            )
        ])
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
        overlayModel.showMomentaryRate(rate)
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
        overlayModel.endMomentaryRate()
    }

    private func startObservingFocusLoss() {
        focusLossObservers.removeAll()
        guard requestMomentaryPlaybackRate != nil,
            finishMomentaryPlaybackRate != nil,
            let window
        else {
            return
        }
        focusLossObservers.observe(
            NSApplication.didResignActiveNotification,
            object: nil
        ) { [weak self] in
            self?.cancelMomentaryPlaybackRate()
        }
        focusLossObservers.observe(
            NSWindow.didResignKeyNotification,
            object: window
        ) { [weak self] in
            self?.cancelMomentaryPlaybackRate()
        }
    }

    func stopObservingFocusLoss() {
        focusLossObservers.removeAll()
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

/// 播放器键盘快捷键：本地 key monitor、长按临时倍速、离散快捷键与焦点让渡规则。
///
/// 以 content overlay 中的捕获层为锚点取窗口与所属 `AVPlayerView`，因此 detached 全屏窗口里同样生效。
@MainActor
final class PlayerKeyboardShortcutController {
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

    weak var anchorView: NSView?
    weak var feedbackPresenter: PlayerOverlayModel?
    private var keyboardMonitor: Any?
    private var keyboardInputEnabled = true
    private var keyboardState = PlayerKeyboardInputState()
    private var keyboardLongPressTask: Task<Void, Never>?
    private var keyboardLongPressID: UUID?
    private var subtitleToggleTask: Task<Void, Never>?
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

    func setKeyboardInputEnabled(_ enabled: Bool) {
        guard keyboardInputEnabled != enabled else { return }
        keyboardInputEnabled = enabled
        if !enabled {
            cancelInputSession()
        }
    }

    func cancelInputSession() {
        applyKeyboardActions(keyboardState.cancel())
        keyboardLongPressTask?.cancel()
        keyboardLongPressTask = nil
        keyboardLongPressID = nil
        subtitleToggleTask?.cancel()
        subtitleToggleTask = nil
        feedbackPresenter?.clearFeedback()
    }

    func startMonitoring() {
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

    func stopMonitoring() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }

    private func handleKeyboardEvent(_ event: KeyboardEventSnapshot) -> Bool {
        guard let captureWindow = anchorView?.window else { return false }
        let responderOwnsKeys = Self.focusedResponderOwnsKeys(
            captureWindow.firstResponder,
            playerView: enclosingPlayerView
        )
        guard
            PlayerKeyboardEventScope.captures(
                isEnabled: keyboardInputEnabled,
                hasDisallowedModifier: event.hasDisallowedModifier,
                eventMatchesCaptureWindow:
                    event.windowNumber == captureWindow.windowNumber,
                focusedResponderOwnsKeys: responderOwnsKeys
            )
        else {
            if !keyboardInputEnabled
                || event.hasDisallowedModifier
                || responderOwnsKeys
            {
                cancelInputSession()
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
                    feedbackPresenter?.showFeedback(
                        .relativeSeek(Int(seconds.rounded()))
                    )
                }
            case .adjustVolume(let offset):
                if let volume = onVolumeStep(offset) {
                    feedbackPresenter?.showFeedback(
                        .volume(Int((volume * 100).rounded()))
                    )
                }
            case .togglePlayback:
                if let isPlaying = onTogglePlayback() {
                    feedbackPresenter?.showFeedback(.playback(isPlaying))
                }
            case .toggleDanmaku:
                if let enabled = onToggleDanmaku() {
                    feedbackPresenter?.showFeedback(.danmaku(enabled))
                }
            case .toggleSubtitles:
                subtitleToggleTask?.cancel()
                subtitleToggleTask = Task { [weak self] in
                    guard let self else { return }
                    let result = await self.onToggleSubtitles()
                    guard !Task.isCancelled else { return }
                    self.subtitleToggleTask = nil
                    self.feedbackPresenter?.showFeedback(.subtitles(result))
                }
            }
        }
    }

    private func cancelIfEditableResponder() {
        guard
            let window = anchorView?.window,
            Self.focusedResponderOwnsKeys(
                window.firstResponder,
                playerView: enclosingPlayerView
            )
        else { return }
        cancelInputSession()
    }

    private var enclosingPlayerView: AVPlayerView? {
        var ancestor = anchorView?.superview
        while let current = ancestor {
            if let playerView = current as? AVPlayerView { return playerView }
            ancestor = current.superview
        }
        return nil
    }

    /// 键盘焦点位于播放器之外的可交互控件时，快捷键交还给该控件。
    ///
    /// 包括可编辑文本、全键盘访问聚焦的按钮／分段控件、可键盘导航的列表，以及声明为
    /// `PlayerKeyboardFocusOwner` 的浮层（例如评论图片预览）。播放器自身及其子视图仍由播放器处理；
    /// 只可选择、不可编辑的文本不拦截空格等快捷键。
    static func focusedResponderOwnsKeys(
        _ responder: NSResponder?,
        playerView: NSView?
    ) -> Bool {
        guard let view = responder as? NSView else { return false }
        if let playerView, view === playerView || view.isDescendant(of: playerView) {
            return false
        }
        var ancestor: NSView? = view
        while let current = ancestor {
            if current is PlayerKeyboardFocusOwner { return true }
            ancestor = current.superview
        }
        switch view {
        case let textView as NSTextView:
            return textView.isEditable
        case let textField as NSTextField:
            return textField.isEditable
        case let collectionView as NSCollectionView:
            return collectionView.isSelectable
        case is NSControl:
            return true
        default:
            return false
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
            .command, .control, .option, .shift
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
