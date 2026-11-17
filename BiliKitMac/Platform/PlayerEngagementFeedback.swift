import SwiftUI

/// 点赞、投币、收藏快捷键（Q／长按 Q／W／E）在播放器顶部的提示：动作本身，或做不了的原因。
///
/// 写入结果（成功、失败原因）由窗口底部的写入结果胶囊说明；这里只给按键当下的反馈，所以点赞显示的是乐观结果。
/// 全屏（AVKit 独立全屏窗口）下投币面板与「收藏到…」面板在主窗口里看不到，W／E 只提示先退出全屏。
enum PlayerEngagementFeedback: Equatable {
    case liked
    case unliked
    case tripleRequested
    /// 按住 Q 到 `longPressDelay`：继续按住到 `tripleHoldDuration` 就三连。
    case tripleProgress
    /// 未登录、认证仍在确认或其他窗口换号待复核。
    case signInRequired
    /// 这个视频的互动状态还没读到。
    case unavailable
    case exitFullScreenToCoin
    case exitFullScreenToFavorite

    var tier: PlayerShortcutFeedback.Tier {
        switch self {
        case .liked, .unliked, .tripleRequested, .tripleProgress: .echo
        case .signInRequired, .unavailable, .exitFullScreenToCoin, .exitFullScreenToFavorite:
            .message
        }
    }

    var label: String {
        switch self {
        case .liked: AppStrings.localized("已点赞")
        case .unliked: AppStrings.localized("已取消点赞")
        case .tripleRequested: AppStrings.localized("三连")
        case .tripleProgress: AppStrings.localized("继续按住三连")
        case .signInRequired: AppStrings.localized("登录后可点赞、投币与收藏")
        case .unavailable: AppStrings.localized("暂时无法点赞、投币与收藏")
        case .exitFullScreenToCoin: AppStrings.localized("退出全屏后可投币")
        case .exitFullScreenToFavorite: AppStrings.localized("退出全屏后可收藏")
        }
    }

    var symbolName: String {
        switch self {
        case .liked, .tripleRequested, .tripleProgress: "hand.thumbsup.fill"
        case .unliked: "hand.thumbsup"
        case .signInRequired: "person.crop.circle"
        case .unavailable: "exclamationmark.circle"
        case .exitFullScreenToCoin: "bitcoinsign.circle"
        case .exitFullScreenToFavorite: "star"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .tripleProgress: AppStrings.localized("继续按住 Q 三连")
        case .liked, .unliked, .tripleRequested, .signInRequired, .unavailable,
            .exitFullScreenToCoin, .exitFullScreenToFavorite:
            label
        }
    }
}

/// 三连进度环：出现时从空填到满，用时是从显示进度到执行三连的剩余按住时间。
///
/// 减弱动态效果时不做填充动画，直接画满一圈作为“按住中”的提示。
struct PlayerTripleProgressRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    .secondary.opacity(PlayerTripleProgressGeometry.trackOpacity),
                    lineWidth: PlayerTripleProgressGeometry.lineWidth
                )
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    .tint,
                    style: StrokeStyle(
                        lineWidth: PlayerTripleProgressGeometry.lineWidth,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(
            width: PlayerTripleProgressGeometry.diameter,
            height: PlayerTripleProgressGeometry.diameter
        )
        .onAppear {
            guard !reduceMotion else {
                progress = 1
                return
            }
            withAnimation(.linear(duration: PlayerTripleProgressGeometry.fillDuration)) {
                progress = 1
            }
        }
        .accessibilityHidden(true)
    }
}

/// 三连进度环的几何与用时。
enum PlayerTripleProgressGeometry {
    static let diameter: CGFloat = 20
    static let lineWidth: CGFloat = 3
    static let trackOpacity: Double = 0.35
    /// 从显示进度到执行三连的剩余按住时间，与键盘状态机的两个时限一致。
    static let fillDuration =
        PlayerKeyboardInputState.tripleHoldDuration - PlayerKeyboardInputState.longPressDelay
}
