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

/// 把写入效果落到本窗口的视图上。
///
/// 稍后再看列表只标记为过期，下次页面出现时原地刷新，不在后台读取；收藏写入在本地增减侧栏收藏夹的条数（三连不改，宽限期后补读），受影响的收藏夹正在显示时原地刷新，否则回来时刷新；点赞、
/// 投币、三连与收藏改动让正在播放同一视频的播放页重读互动状态（三连的收藏进默认收藏夹，也按收藏写入刷新），关注与取消
/// 关注让正在播放同一 UP 主视频的播放页重读（关注状态在同一份互动状态里），正在显示这位 UP 主的整页空间页直接取确认的
/// 状态。关注、取消关注、特别关注与设置分组都让关系存储取确认的关系、侧栏「关注」组按写前与写后的关系在本地改人数（写前
/// 分组未知时宽限期后重读），关注页去掉已不属于正在显示的列表的卡片（刚加入的人不插入，宽限期后重读那一页）；取消关注的
/// 写前分组取自本窗口的关系存储，效果里没有。「不感兴趣」
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
    private let uploaderSpacePage: UploaderSpaceViewModel
    private let followRelations: FollowRelationStore
    private let followGroupList: FollowGroupListModel
    private let followSession: FollowListSession
    private let writableAccount: @MainActor () -> WritableAccount?

    init(
        watchLaterModel: WatchLaterViewModel,
        favoriteFolderList: FavoriteFolderListModel,
        favoriteFolders: FavoriteFolderViewModel,
        engagementModel: VideoEngagementModel,
        uploaderSpacePage: UploaderSpaceViewModel,
        followRelations: FollowRelationStore,
        followGroupList: FollowGroupListModel,
        followSession: FollowListSession,
        writableAccount: @escaping @MainActor () -> WritableAccount?
    ) {
        self.watchLaterModel = watchLaterModel
        self.favoriteFolderList = favoriteFolderList
        self.favoriteFolders = favoriteFolders
        self.engagementModel = engagementModel
        self.uploaderSpacePage = uploaderSpacePage
        self.followRelations = followRelations
        self.followGroupList = followGroupList
        self.followSession = followSession
        self.writableAccount = writableAccount
    }

    /// 把一次写入效果落到本窗口；不属于本窗口账户与会话代次的丢弃。
    ///
    /// `appliedLocally` 为 true 表示本窗口的视图已经按这次写入改过（稍后再看页与收藏夹页的乐观移除），不再刷新那一页：
    /// 否则刚移除成功就会再刷新一次。侧栏收藏夹与关注分组的条数不看它：每个窗口都按效果在本地增减一次（发起窗口没有另改）。
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
            favoriteFolderList.membershipDidChange(
                added: change.addedFolderIDs,
                removed: change.removedFolderIDs
            )
            favoriteFolders.markNeedsReload(
                folderIDs: Set(change.addedFolderIDs + change.removedFolderIDs)
            )
            engagementModel.markNeedsReload(bvid: change.target.bvid)
        case .removedFromFavoriteFolder(let entry):
            favoriteFolderList.membershipDidChange(added: [], removed: [entry.folderID])
            guard !appliedLocally else { return }
            favoriteFolders.markNeedsReload(folderIDs: [entry.folderID])
        case .likeChanged(let target, _), .coinsAdded(let target, _, _):
            guard !appliedLocally else { return }
            engagementModel.markNeedsReload(bvid: target.bvid)
        case .tripled(let target, _):
            // 收藏进了默认收藏夹（写前可能已在，条数不在本地改，宽限期后补读）；默认收藏夹正在显示时刷新。
            favoriteFolderList.membershipDidChangeUnknown()
            if let defaultFolder = favoriteFolderList.folders.first(where: \.isDefault) {
                favoriteFolders.markNeedsReload(folderIDs: [defaultFolder.id])
            }
            guard !appliedLocally else { return }
            engagementModel.markNeedsReload(bvid: target.bvid)
        case .followChanged(let uploader, let isFollowing):
            uploaderSpacePage.followDidChange(ownerID: uploader.mid, isFollowing: isFollowing)
            let known = followRelations.relation(of: uploader.mid)
            if isFollowing {
                // 协调者只在按钮显示「关注」时发出关注，写前固定是没有关注：存储里这时的“已关注”是写入落地后才读到的
                // （预读与写入赛跑），按它作写前会让人数少加一。读到的分组就是写后的位置，没有时进默认分组。
                applyRelation(
                    from: .notFollowing,
                    to: known.flatMap { $0.isFollowing ? $0 : nil }
                        ?? .following(.defaultGroupOnly),
                    mid: uploader.mid
                )
            } else {
                applyRelation(
                    from: known ?? .followingWithUnknownGroups(isSpecial: nil),
                    to: .notFollowing,
                    mid: uploader.mid
                )
            }
            guard !appliedLocally else { return }
            engagementModel.markNeedsReload(uploaderID: uploader.mid)
        case .followSpecialChanged(let uploader, let isSpecial, let before):
            // 写前只用效果里带的分组（来自发起窗口写入之前）：发起窗口的存储此时已是乐观改动后的值，其他窗口的也可能是。
            // 不知道时写前分组未知，人数宽限期后重读。
            applyRelation(
                from: before.map(FollowRelation.following)
                    ?? .followingWithUnknownGroups(isSpecial: nil),
                to: .settingSpecial(isSpecial, before: before),
                mid: uploader.mid
            )
        case .followGroupsChanged(let uploader, let before, let after):
            applyRelation(from: .following(before), to: .following(after), mid: uploader.mid)
        case .recommendationDisliked, .recommendationDislikeCancelled, .danmakuPosted,
            .commentReactionChanged, .commentPosted:
            break
        }
    }

    /// 写入确认一个人的关系从 `before` 变成 `after`：关系存储取确认值，侧栏人数在本地调整（任一侧分组未知时只等宽限期后
    /// 补读），关注页去掉已不属于正在显示的列表的卡片。
    private func applyRelation(from before: FollowRelation, to after: FollowRelation, mid: Int64) {
        followRelations.confirm(after, for: mid)
        followGroupList.relationDidChange(from: before, to: after)
        followSession.relationDidChange(after, mid: mid)
    }
}
