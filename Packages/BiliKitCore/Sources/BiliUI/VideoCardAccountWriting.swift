import BiliApplication
import SwiftUI

/// 卡片菜单里账户写操作的入口：此刻是否满足写入门槛，按卡片 ID（BVID）或收藏夹条目发出写入意图，以及关注页人物卡片的
/// 「已关注」菜单（按 mid）。
///
/// 实现是 App 窗口的写入协调者（`AccountWriteCoordinator`），由 `AppShellView` 经 SwiftUI 环境
/// `videoCardAccountWriting` 注入；各来源的网格、横排与菜单描述只读取它，不持有 Task、不判断账户。没有注入（预览、测试）
/// 时为 nil，写操作项不出现。闭包只转发意图：门槛、卡片是否仍是同一个视频与请求的 owner 都在协调者里，并在执行时
/// 重新核对。`isAvailable` 在菜单与读屏操作每次构造时求值，不满足时菜单项显示为禁用。
public struct VideoCardAccountWriting: Sendable {
    public let isAvailable: @MainActor @Sendable () -> Bool
    public let addToWatchLater: @MainActor @Sendable (_ bvid: String) -> Void
    public let removeFromWatchLater: @MainActor @Sendable (_ bvid: String) -> Void
    /// 打开这个视频的「收藏到…」面板；写入在面板确认时才发出。
    public let chooseFavoriteFolders: @MainActor @Sendable (_ bvid: String) -> Void
    /// 收藏夹页的「从此收藏夹移除」；条目由收藏夹页按显示中的收藏夹与条目给出。
    public let removeFromFavoriteFolder: @MainActor @Sendable (FavoriteFolderEntry) -> Void
    /// 首页推荐的「不感兴趣」与撤销；反馈由首页推荐按卡片的推荐流字段与所选原因给出，撤销交回同一份。
    public let dislikeRecommendation: @MainActor @Sendable (RecommendationFeedback) -> Void
    public let cancelRecommendationDislike: @MainActor @Sendable (RecommendationFeedback) -> Void
    /// 这个人此刻是否在特别关注，不知道时为 nil；取自 App 窗口的关系存储，关注页卡片的菜单与特别关注标记都读它。
    ///
    /// 菜单与卡片在构造时求值；关系存储是 `@Observable`，在视图 `body` 里求值时随它的变化重绘。
    public let followSpecialState: @MainActor @Sendable (_ mid: Int64) -> Bool?
    /// 「已关注」菜单的三项：加入或移出特别关注、打开「设置分组…」面板、取消关注。
    public let setFollowSpecial: @MainActor @Sendable (_ mid: Int64, _ isSpecial: Bool) -> Void
    public let chooseFollowGroups: @MainActor @Sendable (_ mid: Int64) -> Void
    public let unfollow: @MainActor @Sendable (_ mid: Int64) -> Void

    public init(
        isAvailable: @escaping @MainActor @Sendable () -> Bool,
        addToWatchLater: @escaping @MainActor @Sendable (_ bvid: String) -> Void,
        removeFromWatchLater: @escaping @MainActor @Sendable (_ bvid: String) -> Void,
        chooseFavoriteFolders: @escaping @MainActor @Sendable (_ bvid: String) -> Void,
        removeFromFavoriteFolder: @escaping @MainActor @Sendable (FavoriteFolderEntry) -> Void,
        dislikeRecommendation: @escaping @MainActor @Sendable (RecommendationFeedback) -> Void,
        cancelRecommendationDislike:
            @escaping @MainActor @Sendable (RecommendationFeedback) -> Void,
        followSpecialState: @escaping @MainActor @Sendable (_ mid: Int64) -> Bool?,
        setFollowSpecial: @escaping @MainActor @Sendable (_ mid: Int64, _ isSpecial: Bool) -> Void,
        chooseFollowGroups: @escaping @MainActor @Sendable (_ mid: Int64) -> Void,
        unfollow: @escaping @MainActor @Sendable (_ mid: Int64) -> Void
    ) {
        self.isAvailable = isAvailable
        self.addToWatchLater = addToWatchLater
        self.removeFromWatchLater = removeFromWatchLater
        self.chooseFavoriteFolders = chooseFavoriteFolders
        self.removeFromFavoriteFolder = removeFromFavoriteFolder
        self.dislikeRecommendation = dislikeRecommendation
        self.cancelRecommendationDislike = cancelRecommendationDislike
        self.followSpecialState = followSpecialState
        self.setFollowSpecial = setFollowSpecial
        self.chooseFollowGroups = chooseFollowGroups
        self.unfollow = unfollow
    }

    /// 关注页人物卡片的「已关注」菜单内容；关系按 `followSpecialState` 换算。
    @MainActor
    package func followingMenu(mid: Int64) -> UploaderFollowingMenuContent {
        UploaderFollowingMenuContent(isSpecial: followSpecialState(mid), isWritable: isAvailable())
    }

    /// 把「已关注」菜单的一项转给对应的写入口。
    @MainActor
    package func perform(_ action: UploaderFollowingMenuContent.Action, mid: Int64) {
        switch action {
        case .setSpecial(let isSpecial): setFollowSpecial(mid, isSpecial)
        case .chooseGroups: chooseFollowGroups(mid)
        case .unfollow: unfollow(mid)
        }
    }
}

extension EnvironmentValues {
    /// 卡片菜单的账户写入口；App 在窗口外壳上注入一次，见 `VideoCardAccountWriting`。
    @Entry public var videoCardAccountWriting: VideoCardAccountWriting? = nil
}
