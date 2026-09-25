import BiliApplication
import BiliBrowseFeature
import BiliPlayback
import SwiftUI

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
    /// 浮层命名坐标空间；非隔离常量，可在 `onGeometryChange` 的 Sendable 闭包中引用。
    static let coordinateSpace = "PlayerOverlay"
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

    let model: PlayerOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .overlay(alignment: .top) { feedbackBadge }
            .overlay(alignment: .bottomLeading) { resumeButton }
            .overlay(alignment: .bottom) { previewEndedBadge }
            .coordinateSpace(.named(PlayerOverlayLayout.coordinateSpace))
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

    @ViewBuilder
    private var previewEndedBadge: some View {
        if let message = model.previewEndedMessage {
            PlayerPreviewEndedBadge(message: message)
                .padding(.horizontal, PlayerOverlayLayout.edgeInset)
                .padding(.bottom, PlayerOverlayLayout.bottomInset)
        }
    }
}
