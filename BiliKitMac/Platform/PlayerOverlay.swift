import AVFoundation
import BiliApplication
import BiliPlayback
import BiliUI
import BiliVideoDetailFeature
import SwiftUI

/// 播放器浮层上的胶囊底：macOS 26 起是液态玻璃，之前是磨砂材质加细描边；快捷键反馈、按钮与弹幕输入胶囊共用。
struct PlayerGlassCapsuleBackground: ViewModifier {
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

/// 开播后的加载转圈：用户在等画面时由浮层转圈，AVKit 此时不画任何指示。
///
/// 等画面只有两种：一次 seek 还没落地，新位置的画面还没出来（播放、暂停、原生进度条拖动与 progressive 源
/// 都一样，见 `SeekTrackingPlayer`）；或者播放器要播却停着等数据，即 `waitingToPlayAtSpecifiedRate` 且
/// item 不再“可能跟得上”。不看等待原因：seek 后先是 `evaluatingBufferingRate` 再转为 `toMinimizeStalls`，
/// 两者都是在等数据；而 HLS 源播完后再调用播放会一直停在 `toMinimizeStalls`，却已“可能跟得上”，那不是在等画面。
/// 准备期间与 item 未就绪时分别由准备转圈与 AVKit 自己的转圈负责，这里都不算。
/// 等待持续 `LoadingIndicatorPolicy.presentationDelay` 才呈现，期间恢复则不出现：开播、变速与已缓冲区内 seek 的瞬时等待都在
/// 几十毫秒内结束，不会闪一下。
enum PlayerLoadingPolicy {
    static let fadeDurationSeconds = OverlayFadePolicy.durationSeconds

    static func isWaitingForPicture(
        isPreparing: Bool,
        isItemReady: Bool,
        hasPendingSeek: Bool,
        timeControlStatus: AVPlayer.TimeControlStatus,
        isPlaybackLikelyToKeepUp: Bool
    ) -> Bool {
        guard !isPreparing, isItemReady else { return false }
        return hasPendingSeek
            || (timeControlStatus == .waitingToPlayAtSpecifiedRate && !isPlaybackLikelyToKeepUp)
    }
}

/// 播放器浮层相对 content overlay 的位置；底部留出原生控制条的高度。
enum PlayerOverlayLayout {
    static let edgeInset: CGFloat = 20
    static let bottomInset: CGFloat = 64
    /// 顶部反馈徽标与其下写入结果徽标之间的距离。
    static let badgeSpacing: CGFloat = 8
    /// 浮层命名坐标空间；非隔离常量，可在 `onGeometryChange` 的 Sendable 闭包中引用。
    static let coordinateSpace = "PlayerOverlay"
}

/// “从头播放”按钮的标题，按钮文字与 accessibility label 共用。
enum PlayerResumeNoticePresentation {
    static var title: String { AppStrings.localized("从头播放") }
}

/// “从头播放”提示的自动收起规则。
///
/// `delay` 是续播后提示保留的时长，到时淡出，同一次续播不再出现；调长更久遮挡画面，
/// 调短用户来不及点。
enum PlayerResumeNoticeDismissalPolicy {
    static let delay: Duration = .seconds(5)
    static let fadeDurationSeconds = OverlayFadePolicy.durationSeconds
    /// 时间跳转后离续播位置超过该秒数即视为用户已自行定位，收起“从头播放”。
    static let positionToleranceSeconds: Double = 0.5
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
/// `interactiveFrames` 给出本视图坐标（左上原点）中的可交互区域，只有落在其中的点照常命中 SwiftUI 内容；
/// 其余点击、拖动与悬停穿透给下方的 AVKit 视图。
@MainActor
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var interactiveFrames: () -> [CGRect] = { [] }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let location = convert(point, from: superview)
        guard interactiveFrames().contains(where: { $0.contains(location) }) else { return nil }
        return super.hitTest(point)
    }
}

/// 播放器 content overlay 上的全部临时提示：准备与加载转圈、快捷键反馈、显示在播放器上的写入结果、“从头播放”按钮与
/// 试看结束徽章。
///
/// 自动消失的计时由 `PlayerOverlayView` 的 `.task(id:)` 持有；这里只保存状态与 identity 规则。
@MainActor
@Observable
final class PlayerOverlayModel {
    /// 一次反馈：每次显示都生成新的 `id`。
    ///
    /// 视图的消失计时以 `id` 为 `.task(id:)`，重复相同的操作也会重新计时；旧计时到时按 id
    /// 比对后忽略。
    struct Feedback: Equatable {
        let id = UUID()
        let content: PlayerShortcutFeedback
        /// 临时倍速在按住期间保持显示；其他反馈到时自动消失。
        var dismissesAutomatically = true
        /// 通告这条时打断还没读完的上一条：回显总是打断，说明只在与正在显示的那条相同时打断（连按同一个键时只读最新
        /// 一遍，不排成一串）。
        var interruptsAnnouncement = true
    }

    private(set) var feedback: Feedback?
    private(set) var resumeNotice: PlaybackResumeNotice?
    private(set) var previewEndedMessage: String?
    /// 写入结果显示在播放器上时由浮层在反馈徽标下方显示；宿主从 `PlayerHostOwner` 拿到后交来。
    @ObservationIgnored var writeResults: PlayerWriteResults?
    /// 全屏时按下写入键后、结果到达前在结果位置显示的一句「正在…」。
    ///
    /// `sequence` 是发出时最新结果的序号：之后有了新结果（序号变了）就让给结果，不再显示；写入被取消、没有结果时按说明一档
    /// 的时长收起。窗口里不设置：工具栏按钮当下就翻转。
    struct PendingWrite: Equatable {
        let id = UUID()
        let content: PlayerShortcutFeedback
        let sequence: UInt64
    }

    private(set) var pendingWrite: PendingWrite?
    private(set) var showsPreparationActivity = false
    /// 当前这次等画面的 identity，不在等待时为 nil。
    ///
    /// 呈现计时以它为 `.task` id，计时起点是用户最近一次看到画面更新：等待开始时，或转圈还没呈现时又有 seek
    /// 落地（新位置的画面出来了），都生成新 id 重新计时。拖动已缓冲区间时 AVKit 一次接一次地 seek，每次都很快
    /// 落地，不会转；在未缓冲区连按快捷键时旧 seek 被打断而没有落地，画面一直停在原处，从第一次按下起计时。
    /// 转圈已经呈现后再落地沿用原 id，转圈不闪。
    private(set) var loadingID: UUID?
    private(set) var showsLoadingActivity = false
    /// 最近一次 `setWaitingForPicture` 带来的 seek 落地次数，只用来判断画面是否又更新过。
    @ObservationIgnored private var loadingLandedSeekCount: UInt64 = 0
    @ObservationIgnored private(set) var restartFromBeginning: () -> Void = {}
    @ObservationIgnored private var dismissedResumeToken: PlaybackResumeToken?
    @ObservationIgnored fileprivate var resumeButtonFrame: CGRect?
    /// 发送弹幕的输入胶囊；由窗口的播放器内容注入，nil 时回车不呼出。
    ///
    /// 呼出被拒（未登录、没有在播的视频）时在顶部提示；发出成功由写入结果的一处说明，失败在输入胶囊下方说明。
    var danmakuComposer: DanmakuComposerModel? {
        didSet {
            danmakuComposer?.onPresentationRefused = { [weak self] failure in
                self?.showFeedback(
                    .action(failure == .signInRequired ? .danmakuSignInRequired : .unavailable)
                )
            }
        }
    }
    @ObservationIgnored var danmakuComposerFrame: CGRect?

    /// 只有“从头播放”按钮与呼出的弹幕输入胶囊接收鼠标；坐标为 overlay 根视图空间。
    var interactiveFrames: [CGRect] {
        var frames: [CGRect] = []
        if resumeNotice != nil, let resumeButtonFrame { frames.append(resumeButtonFrame) }
        if danmakuComposer?.isPresented == true, let danmakuComposerFrame {
            frames.append(danmakuComposerFrame)
        }
        return frames
    }

    /// 显示一条反馈；发出写入的那几种（`isWriteRequest`）不显示，只在结果显示在播放器上时先占住结果的位置。
    func showFeedback(_ content: PlayerShortcutFeedback) {
        guard content.isWriteRequest else {
            feedback = Feedback(
                content: content,
                interruptsAnnouncement: content.tier == .echo || feedback?.content == content
            )
            return
        }
        guard let writeResults, writeResults.isOnPlayer() else { return }
        pendingWrite = PendingWrite(content: content, sequence: writeResults.latestSequence())
    }

    /// 占位到时还没等到结果（写入被取消时没有结果）就收起。
    func expirePendingWrite(id: UUID) {
        guard pendingWrite?.id == id else { return }
        pendingWrite = nil
    }

    /// 此刻在结果位置显示的占位：结果仍显示在播放器上、发出之后还没有新结果时才显示，结果一到就让给结果；途中退出全屏
    /// 时也不再显示，结果改由窗口底部的胶囊说明。
    var shownPendingWrite: PendingWrite? {
        guard let pendingWrite, let writeResults, writeResults.isOnPlayer(),
            writeResults.latestSequence() == pendingWrite.sequence
        else { return nil }
        return pendingWrite
    }

    func showMomentaryRate(_ rate: PlayerMomentaryRate) {
        feedback = Feedback(content: .momentaryRate(rate), dismissesAutomatically: false)
    }

    func endMomentaryRate() {
        guard case .momentaryRate = feedback?.content else { return }
        fadeOutFeedback()
    }

    /// 按住 Q 显示三连进度：按住期间保持显示，由 `endTripleProgress` 收起。
    func showTripleProgress() {
        feedback = Feedback(content: .engagement(.tripleProgress), dismissesAutomatically: false)
    }

    func endTripleProgress() {
        guard feedback?.content == .engagement(.tripleProgress) else { return }
        fadeOutFeedback()
    }

    /// 立即收起反馈，不淡出：播放页重新挂上宿主时丢掉上一页留下的提示。
    func clearFeedback() {
        feedback = nil
        pendingWrite = nil
    }

    func expireFeedback(id: UUID) {
        guard feedback?.id == id else { return }
        fadeOutFeedback()
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

    /// 播放器阻塞期间（换视频、切分 P、准备播放）player 还没挂上 item 时补一个转圈；item 一挂上，
    /// 未就绪期间由 AVKit 自己的转圈接手，两者不同时出现。
    ///
    /// AVKit 只在“有 item 且未就绪”时画转圈，item 挂上后约 1.5 秒才出现，不受 `controlsStyle` 影响；没有
    /// item 时只是黑屏，开播后的 seek 与缓冲卡住也不画，所以这两段由浮层转圈补上。
    func setPreparationActivity(isPreparing: Bool, hasCurrentItem: Bool) {
        let shows = isPreparing && !hasCurrentItem
        guard showsPreparationActivity != shows else { return }
        showsPreparationActivity = shows
    }

    /// 等待结束立即撤下转圈；进入等待只记录，呈现由视图在延迟后调用 `presentLoading(id:)`。
    ///
    /// 由播放器宿主在播放器、item 或 seek 登记任一变化后按最新状态调用；`landedSeekCount` 是
    /// `PlayerSeekActivity.landedSeekCount`。
    func setWaitingForPicture(_ waiting: Bool, landedSeekCount: UInt64) {
        let pictureUpdated = landedSeekCount != loadingLandedSeekCount
        loadingLandedSeekCount = landedSeekCount
        guard waiting else {
            guard loadingID != nil else { return }
            loadingID = nil
            guard showsLoadingActivity else { return }
            withAnimation(.easeInOut(duration: PlayerLoadingPolicy.fadeDurationSeconds)) {
                showsLoadingActivity = false
            }
            return
        }
        guard loadingID == nil || (pictureUpdated && !showsLoadingActivity) else { return }
        loadingID = UUID()
    }

    func presentLoading(id: UUID) {
        guard loadingID == id, !showsLoadingActivity else { return }
        withAnimation(.easeInOut(duration: PlayerLoadingPolicy.fadeDurationSeconds)) {
            showsLoadingActivity = true
        }
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
    let model: PlayerOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 弹幕输入胶囊的高度，试看结束徽章据此排到呼出的胶囊上方。
    @State private var danmakuComposerHeight: CGFloat = 0

    var body: some View {
        Color.clear
            .overlay { loadingActivity }
            .overlay { preparationActivity }
            .overlay(alignment: .top) {
                VStack(spacing: PlayerOverlayLayout.badgeSpacing) {
                    feedbackBadge
                    writeResultBadge
                }
                .padding(.top, PlayerOverlayLayout.edgeInset)
                .padding(.horizontal, PlayerOverlayLayout.edgeInset)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: OverlayFadePolicy.durationSeconds),
                    value: writeResult
                )
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: OverlayFadePolicy.durationSeconds),
                    value: model.writeResults?.latestSequence()
                )
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: OverlayFadePolicy.durationSeconds),
                    value: model.shownPendingWrite
                )
            }
            .overlay(alignment: .bottomLeading) { resumeButton }
            .overlay(alignment: .bottom) { previewEndedBadge }
            .overlay(alignment: .bottom) {
                danmakuComposer.animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: PlayerDanmakuComposerLayout.fadeDurationSeconds),
                    value: model.danmakuComposer?.isPresented
                )
            }
            .coordinateSpace(.named(PlayerOverlayLayout.coordinateSpace))
            // 快捷键的结果只在徽标上停留片刻，读屏焦点也不在播放器浮层上，所以每条新反馈都通告一次；按反馈的
            // id 触发，连按同一个键也逐次报。是否打断上一条见 `Feedback.interruptsAnnouncement`：说明不打断读屏
            // 正在读的其他内容。临时倍速只在按下时报，松开时徽标消失、不再通告。
            .accessibilityAnnouncement(
                model.feedback?.content.accessibilityLabel,
                trigger: model.feedback?.id,
                interruptsPrevious: model.feedback?.interruptsAnnouncement ?? true
            )
            // 结果显示在播放器上时由这里通告，窗口底部的胶囊此时不显示也不通告。按最新结果的序号触发（不论显示在哪），
            // 不按正在显示的那条：结果从窗口换到播放器时序号不变，不再报一遍。
            .accessibilityAnnouncement(
                writeResult.map(AccountWriteStatusText.message(for:)),
                trigger: model.writeResults?.latestSequence()
            )
            // 续播与试看结束都是播放器自己做的事，读屏焦点不在浮层上；各通告一次（同一次续播按 token，试看结束按这句话）。
            .accessibilityAnnouncement(
                model.resumeNotice == nil
                    ? nil : AppStrings.localized("已从上次看到的位置继续播放"),
                trigger: model.resumeNotice?.token
            )
            .accessibilityAnnouncement(
                model.previewEndedMessage,
                trigger: model.previewEndedMessage
            )
            // 占位的收起计时挂在一直在的根视图上，不挂在占位徽章上：徽章在退出全屏或结果到达时被移除，计时随之取消，
            // 占位就会留在模型里，再进全屏时又冒出来。
            .task(id: model.pendingWrite?.id) {
                guard let id = model.pendingWrite?.id else { return }
                try? await Task.sleep(for: TransientNoticePolicy.messageDuration)
                guard !Task.isCancelled else { return }
                model.expirePendingWrite(id: id)
            }
            .task(id: model.loadingID) {
                guard let loadingID = model.loadingID else { return }
                try? await Task.sleep(for: LoadingIndicatorPolicy.presentationDelay)
                guard !Task.isCancelled else { return }
                model.presentLoading(id: loadingID)
            }
    }

    @ViewBuilder
    private var loadingActivity: some View {
        if model.showsLoadingActivity {
            PlayerLoadingIndicator()
                .accessibilityLabel(AppStrings.localized("正在加载"))
                .transition(reduceMotion ? .identity : .opacity)
        }
    }

    @ViewBuilder
    private var preparationActivity: some View {
        if model.showsPreparationActivity {
            PlayerLoadingIndicator()
                .accessibilityLabel(AppStrings.localized("正在准备播放"))
        }
    }

    /// 此刻显示在播放器上的写入结果；结果显示在窗口底部时为 nil。
    private var writeResult: AccountWriteReport? {
        model.writeResults?.current()
    }

    @ViewBuilder
    private var writeResultBadge: some View {
        if let pending = model.shownPendingWrite {
            // 占位不通告：结果到达时那一句才是要读的，先报「正在…」再报结果就成了两条。
            PlayerShortcutFeedbackBadge(feedback: pending.content)
                .transition(reduceMotion ? .identity : .opacity)
        } else if let writeResult {
            PlayerWriteResultBadge(report: writeResult)
                .id(model.writeResults?.latestSequence())
                .transition(reduceMotion ? .identity : .opacity)
        }
    }

    @ViewBuilder
    private var feedbackBadge: some View {
        if let feedback = model.feedback {
            PlayerShortcutFeedbackBadge(feedback: feedback.content)
                .transition(reduceMotion ? .identity : .opacity)
                .task(id: feedback.id) {
                    guard feedback.dismissesAutomatically else { return }
                    try? await Task.sleep(for: feedback.content.tier.displayDuration)
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
                    proxy.frame(in: .named(PlayerOverlayLayout.coordinateSpace))
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

    /// 有胶囊就一直挂着，呼出与收起只改透明度与可用状态（理由见 `PlayerDanmakuComposerView`）；收起后不再进入
    /// 可点区域（`interactiveFrames`），点击穿透给 AVKit。
    @ViewBuilder
    private var danmakuComposer: some View {
        if let composer = model.danmakuComposer {
            PlayerDanmakuComposerView(model: composer)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(PlayerOverlayLayout.coordinateSpace))
                } action: { frame in
                    model.danmakuComposerFrame = frame
                    danmakuComposerHeight = frame.height
                }
                .padding(.horizontal, PlayerOverlayLayout.edgeInset)
                .padding(.bottom, PlayerOverlayLayout.bottomInset)
                .opacity(composer.isPresented ? 1 : 0)
                .disabled(!composer.isPresented)
                .accessibilityHidden(!composer.isPresented)
        }
    }

    /// 试看结束徽章与弹幕输入胶囊都在底部正中：胶囊呼出时徽章排到它上方，不叠在一起。
    @ViewBuilder
    private var previewEndedBadge: some View {
        if let message = model.previewEndedMessage {
            PlayerPreviewEndedBadge(message: message)
                .padding(.horizontal, PlayerOverlayLayout.edgeInset)
                .padding(
                    .bottom,
                    PlayerOverlayLayout.bottomInset
                        + (model.danmakuComposer?.isPresented == true
                            ? danmakuComposerHeight + PlayerOverlayLayout.badgeSpacing : 0)
                )
        }
    }
}
