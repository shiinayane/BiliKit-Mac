import BiliApplication
import BiliPlayback
import BiliUI
import SwiftUI

/// 长按左右键的临时倍速：左 0.5 倍、右 2 倍；`rawValue` 即交给播放器的速率。
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

/// 快捷键与动作菜单操作后在播放器顶部显示的反馈徽标内容：文字、SF Symbol、VoiceOver 文案与它属于哪一档。
enum PlayerShortcutFeedback: Equatable {
    /// 提示的档：决定停留多久、字号与读屏通告的优先级。
    enum Tier: Equatable {
        /// 按键回显：只确认按键被接收（进退、音量、开关、拷贝），短暂停留，新回显打断还没读完的旧通告。
        case echo
        /// 一句话的说明：做不了的原因或播放器自己做了什么（登录后可…、接着播放…），停留到读得完，按默认优先级通告。
        case message

        var displayDuration: Duration {
            switch self {
            case .echo: TransientNoticePolicy.echoDuration
            case .message: TransientNoticePolicy.messageDuration
            }
        }
    }

    case momentaryRate(PlayerMomentaryRate)
    case relativeSeek(Int)
    case volume(Int)
    case playback(Bool)
    case danmaku(Bool)
    case subtitles(NativeSubtitleToggleResult)
    case engagement(PlayerEngagementFeedback)
    case action(PlayerActionFeedback)

    var tier: Tier {
        switch self {
        case .momentaryRate, .relativeSeek, .volume, .playback, .danmaku, .subtitles: .echo
        case .engagement(let feedback): feedback.tier
        case .action(let feedback): feedback.tier
        }
    }

    /// 发出了一次写入（点赞、取消点赞、三连、加入稍后再看）。
    ///
    /// 不作为反馈显示：写入结果只在一处说明（窗口底部或全屏时的播放器上），按下时再说一遍就成了两条。窗口里工具栏的按钮
    /// 当下就翻转；全屏时看不到按钮，在结果的位置先显示这一句，结果到达后原位换成结果（`PlayerOverlayModel.showFeedback`）。
    var isWriteRequest: Bool {
        switch self {
        case .momentaryRate, .relativeSeek, .volume, .playback, .danmaku, .subtitles: false
        case .engagement(let feedback): feedback.isWriteRequest
        case .action(let feedback): feedback.isWriteRequest
        }
    }

    var label: String {
        switch self {
        case .engagement(let feedback): feedback.label
        case .action(let feedback): feedback.label
        case .momentaryRate(let rate): rate.label
        case .relativeSeek(let seconds):
            seconds < 0
                ? AppStrings.localized("后退 \(-seconds) 秒")
                : AppStrings.localized("前进 \(seconds) 秒")
        case .volume(let percent): Self.volumeText(percent)
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
        case .engagement(let feedback): feedback.symbolName
        case .action(let feedback): feedback.symbolName
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
        case .engagement(let feedback): feedback.accessibilityLabel
        case .action(let feedback): feedback.label
        case .momentaryRate(let rate): rate.accessibilityLabel
        case .relativeSeek(let seconds):
            seconds < 0
                ? AppStrings.localized("已后退 \(-seconds) 秒")
                : AppStrings.localized("已前进 \(seconds) 秒")
        case .volume(let percent): AppStrings.localized("播放器音量 \(Self.volumeText(percent))")
        case .playback(let isPlaying):
            isPlaying ? AppStrings.localized("已开始播放") : AppStrings.localized("已暂停播放")
        case .danmaku(let enabled):
            enabled ? AppStrings.localized("弹幕已开启") : AppStrings.localized("弹幕已关闭")
        case .subtitles(.enabled(let label)): AppStrings.localized("字幕已开启，\(label)")
        case .subtitles(.disabled): AppStrings.localized("字幕已关闭")
        case .subtitles(.unavailable): AppStrings.localized("当前视频没有可用字幕")
        }
    }

    /// 音量百分比的唯一写法，locale 取与文案同语言的 `InterfaceLocale`。
    private static func volumeText(_ percent: Int) -> String {
        percent.formatted(.percent.locale(InterfaceLocale.current))
    }
}

/// 反馈徽标自动消失时的淡出时长；停留多久按档取 `TransientNoticePolicy`（见 `PlayerShortcutFeedback.Tier`）。
///
/// 连续操作会生成新反馈并重新计时。
enum PlayerShortcutFeedbackDismissalPolicy {
    static let fadeDuration: TimeInterval = 0.16
}

/// 播放器顶部的快捷键与动作反馈徽标；长按 Q 时图标换成三连进度环。
struct PlayerShortcutFeedbackBadge: View {
    let feedback: PlayerShortcutFeedback

    var body: some View {
        PlayerNoticeBadge(
            tier: feedback.tier,
            label: feedback.label,
            accessibilityLabel: feedback.accessibilityLabel
        ) {
            if feedback == .engagement(.tripleProgress) {
                PlayerTripleProgressRing()
            } else {
                Image(systemName: feedback.symbolName)
            }
        }
    }
}

/// 播放器上的写入结果（结果显示在播放器上时，见 `PlayerWriteResults`）：与窗口底部胶囊同一句话，按说明一档排版。
///
/// 被 B 站拒绝、网页上可以完成的结果不放「在浏览器中打开」：全屏下跳到浏览器会打断观看，说明里已经写了可以在网页上完成；
/// 浮层也不为它开可点区域。
struct PlayerWriteResultBadge: View {
    let report: AccountWriteReport

    var body: some View {
        let message = AccountWriteStatusText.message(for: report)
        PlayerNoticeBadge(tier: .message, label: message, accessibilityLabel: message) {
            Image(
                systemName: report.failure == nil ? "checkmark.circle" : "exclamationmark.circle"
            )
        }
    }
}

/// 播放器顶部徽标的共同排版：图标加一句话，回显用大字单行，说明用正文字号、最多两行，玻璃胶囊底。
private struct PlayerNoticeBadge<Icon: View>: View {
    private static var messageLineLimit: Int { 2 }

    let tier: PlayerShortcutFeedback.Tier
    let label: String
    let accessibilityLabel: String
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(label)
                .monospacedDigit()
                .lineLimit(tier == .echo ? 1 : Self.messageLineLimit)
                .multilineTextAlignment(.leading)
        }
        .font(tier == .echo ? .title3.weight(.semibold) : .body.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .modifier(PlayerGlassCapsuleBackground())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}
