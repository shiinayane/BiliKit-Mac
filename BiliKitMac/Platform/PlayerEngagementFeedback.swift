import SwiftUI

/// 点赞、投币、收藏快捷键（Q／长按 Q／W／E）在播放器上的提示：发出了哪次写入、三连进度，或做不了的原因。
///
/// 写入结果（成功、失败原因）只由写入结果的一处说明（见 docs/ARCHITECTURE.md「临时提示与结果」）；发出写入的几项
/// （`isWriteRequest`）不作为反馈显示，只在全屏时于结果的位置先显示「正在…」，结果到达后原位换成结果。
/// 全屏（AVKit 独立全屏窗口）下投币面板与「收藏到…」面板在主窗口里看不到，W／E 只提示先退出全屏。
enum PlayerEngagementFeedback: Equatable {
    case likeRequested
    case unlikeRequested
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
        case .tripleProgress: .echo
        case .likeRequested, .unlikeRequested, .tripleRequested, .signInRequired, .unavailable,
            .exitFullScreenToCoin, .exitFullScreenToFavorite:
            .message
        }
    }

    var isWriteRequest: Bool {
        switch self {
        case .likeRequested, .unlikeRequested, .tripleRequested: true
        case .tripleProgress, .signInRequired, .unavailable, .exitFullScreenToCoin,
            .exitFullScreenToFavorite:
            false
        }
    }

    var label: String {
        switch self {
        case .likeRequested: AppStrings.localized("正在点赞")
        case .unlikeRequested: AppStrings.localized("正在取消点赞")
        case .tripleRequested: AppStrings.localized("正在三连")
        case .tripleProgress: AppStrings.localized("继续按住三连")
        case .signInRequired: AppStrings.localized("登录后可点赞、投币与收藏")
        case .unavailable: AppStrings.localized("暂时无法点赞、投币与收藏")
        case .exitFullScreenToCoin: AppStrings.localized("退出全屏后可投币")
        case .exitFullScreenToFavorite: AppStrings.localized("退出全屏后可收藏")
        }
    }

    var symbolName: String {
        switch self {
        case .likeRequested, .tripleRequested, .tripleProgress: "hand.thumbsup.fill"
        case .unlikeRequested: "hand.thumbsup"
        case .signInRequired: "person.crop.circle"
        case .unavailable: "exclamationmark.circle"
        case .exitFullScreenToCoin: "bitcoinsign.circle"
        case .exitFullScreenToFavorite: "star"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .tripleProgress: AppStrings.localized("继续按住 Q 三连")
        case .likeRequested, .unlikeRequested, .tripleRequested, .signInRequired, .unavailable,
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
