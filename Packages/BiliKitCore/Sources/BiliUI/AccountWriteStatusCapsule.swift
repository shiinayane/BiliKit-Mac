import BiliApplication
import SwiftUI

/// 账户写入结果的胶囊：盖在窗口主区底部，成功或失败都用一句话说明，并在每次新结果出现时发一次读屏通告。
///
/// 外形与刷新、分页胶囊同源（`StatusCapsuleGeometry`），出现与消失按 `LoadingStateTransition` 淡入淡出。只负责排版、
/// 措辞与通告；显示哪一条、显示多久由 App 的写入协调者决定（`sequence` 每条新结果递增，相同结果连续出现也会再通告）。
/// 被 B 站拒绝、但网页上可以完成的点赞、投币与三连另带「在浏览器中打开」（`AccountWriteReport.webFallbackURL`），
/// 只经系统 `OpenURLAction` 打开视频网页，不附加凭据（见 SECURITY-MODEL §4）；带按钮时整颗胶囊接收点按，按钮是唯一的
/// 读屏焦点，提示里带着这句说明，错过通告的读屏用户聚焦到按钮时仍知道它是做什么的。
public struct AccountWriteStatusCapsule: View {
    private typealias Geometry = StatusCapsuleGeometry

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    private let report: AccountWriteReport?
    private let sequence: UInt64

    public init(report: AccountWriteReport?, sequence: UInt64) {
        self.report = report
        self.sequence = sequence
    }

    public var body: some View {
        ZStack {
            if let report {
                HStack(spacing: Geometry.contentPadding) {
                    Label {
                        Text(AccountWriteStatusText.message(for: report))
                            .lineLimit(Geometry.messageLineLimit)
                    } icon: {
                        Image(
                            systemName: report.failure == nil
                                ? "checkmark.circle" : "exclamationmark.circle"
                        )
                    }
                    // 通告已经读出这句话，说明本身不再进入读屏焦点顺序。
                    .accessibilityHidden(true)
                    // 胶囊盖在网格与相关推荐上，说明不拦截停留期间的点按。
                    .allowsHitTesting(false)
                    if let url = report.webFallbackURL {
                        Button(VideoCardMenuText.openInBrowser) {
                            openURL(url)
                        }
                        .accessibilityHint(AccountWriteStatusText.message(for: report))
                    }
                }
                .font(.callout)
                .padding(Geometry.contentPadding)
                .background(.regularMaterial, in: Capsule())
                // 没有按钮时整个胶囊都不拦截点按；有按钮时胶囊本身就是这个操作的入口。
                .allowsHitTesting(report.webFallbackURL != nil)
                .id(sequence)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Geometry.horizontalInset)
        .padding(.bottom, Geometry.bottomInset)
        .animation(LoadingStateTransition.animation(reduceMotion: reduceMotion), value: sequence)
        .animation(
            LoadingStateTransition.animation(reduceMotion: reduceMotion),
            value: report == nil
        )
        .accessibilityAnnouncement(
            report.map(AccountWriteStatusText.message(for:)),
            trigger: sequence
        )
    }
}

/// 写入结果的文案，胶囊与读屏通告共用。
package enum AccountWriteStatusText {
    package static func message(for report: AccountWriteReport) -> String {
        guard let failure = report.failure else {
            return switch report.change {
            case .watchLaterAdded: BiliUIStrings.localized("已添加到稍后再看")
            case .watchLaterRemoved: BiliUIStrings.localized("已从稍后再看移除")
            case .favoriteMembershipChanged(let change):
                if change.removedFolderIDs.isEmpty {
                    BiliUIStrings.localized("已收藏")
                } else if change.addedFolderIDs.isEmpty {
                    BiliUIStrings.localized("已取消收藏")
                } else {
                    BiliUIStrings.localized("已更新收藏")
                }
            case .removedFromFavoriteFolder: BiliUIStrings.localized("已从收藏夹移除")
            case .likeChanged(_, let isLiked):
                isLiked ? BiliUIStrings.localized("已点赞") : BiliUIStrings.localized("已取消点赞")
            case .coinsAdded(_, let count, let alsoLiked):
                alsoLiked
                    ? BiliUIStrings.localized("已投 \(count) 枚硬币并点赞")
                    : BiliUIStrings.localized("已投 \(count) 枚硬币")
            case .tripled: BiliUIStrings.localized("已三连")
            case .followChanged(_, let isFollowing):
                isFollowing ? BiliUIStrings.localized("已关注") : BiliUIStrings.localized("已取消关注")
            case .recommendationDisliked: VideoCardMenuText.dislikedBadge
            case .recommendationDislikeCancelled: BiliUIStrings.localized("已撤销不感兴趣")
            }
        }
        let reason = reason(for: failure, change: report.change)
        return switch report.change {
        case .watchLaterAdded: BiliUIStrings.localized("无法添加到稍后再看：\(reason)")
        case .watchLaterRemoved: BiliUIStrings.localized("无法从稍后再看移除：\(reason)")
        case .favoriteMembershipChanged: BiliUIStrings.localized("无法更新收藏：\(reason)")
        case .removedFromFavoriteFolder: BiliUIStrings.localized("无法从收藏夹移除：\(reason)")
        case .likeChanged(_, let isLiked):
            isLiked
                ? BiliUIStrings.localized("无法点赞：\(reason)")
                : BiliUIStrings.localized("无法取消点赞：\(reason)")
        case .coinsAdded: BiliUIStrings.localized("无法投币：\(reason)")
        case .tripled: BiliUIStrings.localized("无法三连：\(reason)")
        case .followChanged(_, let isFollowing):
            isFollowing
                ? BiliUIStrings.localized("无法关注：\(reason)")
                : BiliUIStrings.localized("无法取消关注：\(reason)")
        case .recommendationDisliked: BiliUIStrings.localized("无法提交不感兴趣：\(reason)")
        case .recommendationDislikeCancelled: BiliUIStrings.localized("无法撤销不感兴趣：\(reason)")
        }
    }

    private static func reason(for failure: AccountWriteError, change: AccountWriteChange) -> String
    {
        let isFavorites =
            switch change {
            case .watchLaterAdded, .watchLaterRemoved, .likeChanged, .coinsAdded, .tripled,
                .recommendationDisliked, .recommendationDislikeCancelled, .followChanged:
                false
            case .favoriteMembershipChanged, .removedFromFavoriteFolder: true
            }
        let isFollow =
            if case .followChanged = change { true } else { false }
        return switch failure {
        case .authenticationRequired, .authenticationInvalid:
            BiliUIStrings.localized("登录状态可能已失效。")
        case .authenticationUnavailable:
            BiliUIStrings.localized("无法读取登录状态，请稍后再试。")
        case .restricted:
            BiliUIStrings.localized("请求受到限制，请稍后再试。")
        case .listFull:
            if isFavorites {
                BiliUIStrings.localized("收藏夹已满。")
            } else if isFollow {
                BiliUIStrings.localized("关注数已达上限。")
            } else {
                BiliUIStrings.localized("稍后再看已满。")
            }
        case .unsupportedContent:
            BiliUIStrings.localized("这个视频不能加入稍后再看。")
        case .contentUnavailable:
            if isFavorites {
                BiliUIStrings.localized("收藏夹或视频已不存在。")
            } else if isFollow {
                BiliUIStrings.localized("UP 主不存在或已注销。")
            } else {
                BiliUIStrings.localized("视频不存在或已删除。")
            }
        case .coinsInsufficient:
            BiliUIStrings.localized("硬币不足。")
        case .coinLimitReached:
            BiliUIStrings.localized("这个视频的投币已达上限。")
        case .ownVideo:
            BiliUIStrings.localized("不能给自己的视频投币。")
        case .declinedForClient:
            BiliUIStrings.localized("B 站拒绝了这个客户端的这次操作，可以在网页上完成。")
        case .rejected(let code):
            BiliUIStrings.localized("服务拒绝了这次操作（错误码 \(code)）。")
        case .unavailable:
            BiliUIStrings.localized("网络不可用或服务暂时无法完成，请稍后再试。")
        case .invalidRequest:
            BiliUIStrings.localized("当前无法完成这次请求。")
        }
    }
}
