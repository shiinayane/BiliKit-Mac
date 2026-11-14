import BiliApplication
import BiliLibraryFeature
import BiliModels
import BiliVideoDetailFeature

/// 窗口账户此刻能否写入：窗口账户已确认登录且 mid 已知，并带上进程账户会话代次（`AccountSessionCoordinator.generation`）。
///
/// 由 `WindowComposition` 按与收藏夹列表相同的规则（`settledAccountScope`）算出：认证仍在确认、或其他窗口换号而本窗口还没
/// 复核到时为 nil。写入协调者据此决定门槛、写请求绑定哪个账户；效果路由据此丢弃不属于本窗口账户的效果。
struct WritableAccount: Equatable {
    let accountID: Int64
    let sessionGeneration: UInt64
}

/// 一次确认成功的写入效果，连同发起时的进程账户会话代次；在窗口之间经 `AccountWriteEffectHub` 传递。
struct AccountWriteEffectDelivery: Equatable {
    let effect: AccountWriteEffect
    let sessionGeneration: UInt64
}

/// 把写入效果落到本窗口的视图上：稍后再看列表只标记为过期，下次页面出现时原地刷新，不在后台读取；收藏写入让侧栏的
/// 收藏夹列表在后台重读条数（它本来就在已登录时常驻读取），受影响的收藏夹正在显示时原地刷新，否则回来时刷新；点赞、
/// 投币、三连与收藏改动让正在播放同一视频的播放页重读互动状态（三连的收藏进默认收藏夹，也按收藏写入刷新），关注与取消
/// 关注让正在播放同一 UP 主视频的播放页重读（关注状态在同一份互动状态里）。「不感兴趣」
/// 与撤销不落到任何视图：标记只在发起窗口的推荐网格里（由写入协调者乐观改动），各窗口的推荐流本来就各不相同。
///
/// 每个窗口一个，由 `WindowComposition` 构造；本窗口的写入协调者直接交给它，其他窗口的效果经进程级 `AccountWriteEffectHub`
/// 转来（窗口打开时登记、关闭时注销）。只处理与本窗口当前账户、会话代次都一致的效果，其余丢弃：换号或登出之后迟到的
/// 效果不能让新账户的列表刷新。不持有 Task 与状态，只引用窗口的模型。
@MainActor
final class AccountWriteEffectRouter {
    private let watchLaterModel: WatchLaterViewModel
    private let favoriteFolderList: FavoriteFolderListModel
    private let favoriteFolders: FavoriteFolderViewModel
    private let engagementModel: VideoEngagementModel
    private let writableAccount: @MainActor () -> WritableAccount?

    init(
        watchLaterModel: WatchLaterViewModel,
        favoriteFolderList: FavoriteFolderListModel,
        favoriteFolders: FavoriteFolderViewModel,
        engagementModel: VideoEngagementModel,
        writableAccount: @escaping @MainActor () -> WritableAccount?
    ) {
        self.watchLaterModel = watchLaterModel
        self.favoriteFolderList = favoriteFolderList
        self.favoriteFolders = favoriteFolders
        self.engagementModel = engagementModel
        self.writableAccount = writableAccount
    }

    /// 把一次写入效果落到本窗口；不属于本窗口账户与会话代次的丢弃。
    ///
    /// `appliedLocally` 为 true 表示本窗口的视图已经按这次写入改过（稍后再看页与收藏夹页的乐观移除），不再刷新那一页：
    /// 否则刚移除成功就会再刷新一次。侧栏收藏夹的条数没有乐观改动，总要重读。
    func apply(_ delivery: AccountWriteEffectDelivery, appliedLocally: Bool) {
        guard
            let account = writableAccount(),
            account.accountID == delivery.effect.accountID,
            account.sessionGeneration == delivery.sessionGeneration
        else { return }
        switch delivery.effect.change {
        case .watchLaterAdded, .watchLaterRemoved:
            guard !appliedLocally else { return }
            watchLaterModel.markNeedsReload()
        case .favoriteMembershipChanged(let change):
            favoriteFolderList.refreshAfterWrite()
            favoriteFolders.markNeedsReload(
                folderIDs: Set(change.addedFolderIDs + change.removedFolderIDs)
            )
            engagementModel.markNeedsReload(bvid: change.target.bvid)
        case .removedFromFavoriteFolder(let entry):
            favoriteFolderList.refreshAfterWrite()
            guard !appliedLocally else { return }
            favoriteFolders.markNeedsReload(folderIDs: [entry.folderID])
        case .likeChanged(let target, _), .coinsAdded(let target, _, _):
            guard !appliedLocally else { return }
            engagementModel.markNeedsReload(bvid: target.bvid)
        case .tripled(let target, _):
            // 收藏进了默认收藏夹：侧栏条数重读，默认收藏夹正在显示时刷新。
            favoriteFolderList.refreshAfterWrite()
            if let defaultFolder = favoriteFolderList.folders.first(where: \.isDefault) {
                favoriteFolders.markNeedsReload(folderIDs: [defaultFolder.id])
            }
            guard !appliedLocally else { return }
            engagementModel.markNeedsReload(bvid: target.bvid)
        case .followChanged(let uploader, _):
            guard !appliedLocally else { return }
            engagementModel.markNeedsReload(uploaderID: uploader.mid)
        case .recommendationDisliked, .recommendationDislikeCancelled, .danmakuPosted,
            .commentReactionChanged, .commentPosted:
            break
        }
    }
}
