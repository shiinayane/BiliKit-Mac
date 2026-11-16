import BiliApplication
import BiliModels
import Observation

/// 侧栏「关注」组读到的值：侧栏顺序的分组与关注总人数。
///
/// 总人数单独读取（分组人数相加会重复计算在多个分组里的人），读不到时为 nil，侧栏「全部关注」行不显示人数，分组照常。
public struct FollowGroupList: Sendable, Equatable {
    public let groups: [FollowGroup]
    public let totalCount: Int?

    public init(groups: [FollowGroup], totalCount: Int?) {
        self.groups = groups
        self.totalCount = totalCount
    }
}

/// 侧栏「关注」组的分组与人数；加载、账户绑定与复核是侧栏各组共用的 `LibrarySidebarListModel`。
public typealias FollowGroupListModel = LibrarySidebarListModel<FollowGroupList>

extension FollowGroupList {
    /// 一个人的关系从 `before` 变成 `after` 之后的人数；任一侧分组未知时为 nil，人数只能重读。
    ///
    /// 全部关注随是否关注增减；各行按 `FollowMembership.groupIDs` 计数，减去写前所在的行、加上写后所在的行，所以只加入特别
    /// 关注时默认分组随之减一。列表里没有的分组（已在网页上删掉）不计。分组人数与总人数都不低于 0（读到的人数可能已过时）。
    public func adjusted(from before: FollowRelation, to after: FollowRelation) -> FollowGroupList?
    {
        guard let beforeIDs = Self.countedGroupIDs(before),
            let afterIDs = Self.countedGroupIDs(after)
        else { return nil }
        let totalDelta = (after.isFollowing ? 1 : 0) - (before.isFollowing ? 1 : 0)
        return FollowGroupList(
            groups: groups.map { group in
                let delta =
                    (afterIDs.contains(group.id) ? 1 : 0) - (beforeIDs.contains(group.id) ? 1 : 0)
                return FollowGroup(
                    id: group.id,
                    name: group.name,
                    count: max(0, group.count + delta)
                )
            },
            totalCount: totalCount.map { max(0, $0 + totalDelta) }
        )
    }

    /// 计数时这个人算在哪几行：没有关注时不算任何一行；分组未知时为 nil。
    private static func countedGroupIDs(_ relation: FollowRelation) -> Set<Int64>? {
        switch relation {
        case .notFollowing: []
        case .following(let membership): membership.groupIDs
        case .followingWithUnknownGroups: nil
        }
    }
}

extension LibrarySidebarListModel where Value == FollowGroupList {
    /// 分组与总人数并发读取；分组读不到即整体失败，总人数读不到只缺人数。
    public convenience init(
        useCase: FollowListUseCase,
        accountScope: @escaping @MainActor () -> AccountSessionScope
    ) {
        self.init(accountScope: accountScope) { ownerID in
            async let count = useCase.followingCount(ownerID: ownerID)
            let groups = try await useCase.groups(ownerID: ownerID)
            return FollowGroupList(groups: groups, totalCount: try? await count)
        }
    }

    /// 已加载的分组；其他状态为空。
    public var groups: [FollowGroup] { loadedValue?.groups ?? [] }

    /// 写入确认一个人的关系从 `before` 变成 `after`：在本地改人数。
    ///
    /// 宽限期后补读（见 `adjustAfterWrite`）；任一侧分组未知时不改，只等补读。由 App 的写入效果路由调用。
    public func relationDidChange(from before: FollowRelation, to after: FollowRelation) {
        adjustAfterWrite { $0.adjusted(from: before, to: after) }
    }
}

/// 关注页的列表：资料库列表的共用状态机，游标是列表种类加页码；选中的行、排序与关键词由 `FollowListSession` 拥有。
public typealias FollowListViewModel = LibraryVideoListModel<FollowedUser, FollowListCursor>

extension LibraryVideoListModel where Item == FollowedUser, Cursor == FollowListCursor {
    /// 按页码翻页，没有新条目的页即停止；按 mid 去重；最多保留 `FollowListUseCase.maximumItemCount` 人。
    ///
    /// `accountID` 是窗口此刻可读取的账户 mid（认证仍在确认或其他窗口换号、本窗口复核未完时为 nil）。为 nil 时不用旧账户
    /// 的 mid 去读，按认证会话切换中途处理（抛 `CancellationError`）：列表回到未加载、不显示失败也不请求复核，等复核或
    /// 账户变化后重新加载；当成凭据失败会在复核本来就在进行时再请求一次，并把“需要登录”显示给已登录的窗口。第一页游标由
    /// `FollowListSession` 构造时接管。
    ///
    /// `reconcile` 拿到每一页的人之后、并入列表之前调用，由 App 的关系存储给出：写入后的宽限期内去掉确认已不在这一页的人、
    /// 换上确认的分组（见 `FollowRelationLedger`），并记下这一页说明的关系。在到底判断之后调用：先去掉人会让分组页不满一页、
    /// 被误判为到底。
    public convenience init(
        useCase: FollowListUseCase,
        accountID: @escaping @MainActor () -> Int64?,
        reconcile:
            @escaping @MainActor (_ ownerID: Int64, FollowListQuery, [FollowedUser]) ->
            [FollowedUser]
    ) {
        self.init(
            stallPolicy: .stop,
            pageSize: FollowListUseCase.pageSize,
            maximumItemCount: FollowListUseCase.maximumItemCount,
            bvid: { String($0.id) },
            load: { cursor in
                guard let cursor else { throw ContentApplicationError.invalidRequest }
                guard let ownerID = accountID() else { throw CancellationError() }
                let result = try await useCase.page(cursor, ownerID: ownerID)
                return (
                    VideoListPage(
                        items: reconcile(ownerID, cursor.query, result.page.items),
                        nextCursor: result.page.nextCursor
                    ),
                    result.totalCount
                )
            }
        )
    }
}

/// 关注来源的会话：侧栏选中的行、全部关注的排序与工具栏搜索，以及它们到列表请求的映射。
///
/// 每个窗口一份，由 App 的窗口组装构造。拥有选中的行、排序与关键词（只在窗口内存里，不持久化）；不拥有请求、分页与复核
/// （`FollowListViewModel`），也不拥有分组列表（`FollowGroupListModel`）。条件变化（换行、换排序、提交或清空关键词）从空列表
/// 重新加载（`reloadReplacingContent()`），旧条件的迟到结果由列表的最新意图丢弃。排序与搜索只作用于全部关注：换到分组时
/// 清空关键词、保留排序。分组列表重读后选中的分组已不存在（在网页上删了）时回落到全部关注（不在本页时回来再读）。
@MainActor
@Observable
public final class FollowListSession {
    /// 侧栏「全部关注」行的 id。
    ///
    /// 分组 tagid 只会是 -10、0 或正整数，取 `Int64.max` 不会与它们相撞。
    public static let allFollowingsRowID = Int64.max

    public private(set) var selectedRowID = FollowListSession.allFollowingsRowID
    public private(set) var order = FollowListOrder.recentlyFollowed

    /// 工具栏搜索框的文字（规则在 `LibrarySearchKeyword`）。
    public var searchDraft: String {
        get { keyword.draft }
        set {
            if keyword.updateDraft(newValue) {
                model.reloadReplacingContent()
            }
        }
    }

    /// 当前列表使用的关键词；空串表示不搜索。
    public var appliedKeyword: String { keyword.applied }

    public var isShowingAllFollowings: Bool { selectedRowID == Self.allFollowingsRowID }

    private var keyword = LibrarySearchKeyword()
    /// 关注页正在显示：`activate()` 置位，`deactivateRoute()` 清除；分组消失时据此决定回落后立即重读还是只改选择。
    ///
    /// 空间页、播放页只是覆盖本页面，不清除，与收藏夹一致。
    @ObservationIgnored private var isRouteActive = false

    @ObservationIgnored public let model: FollowListViewModel

    public init(model: FollowListViewModel, groupList: FollowGroupListModel) {
        self.model = model
        model.firstPageCursor = { [weak self] in self?.firstPageCursor() }
        groupList.onLoaded = { [weak self] in self?.groupListDidLoad($0) }
    }

    /// 关注页内容出现时由页面调用：标记正在显示，从未加载时加载。
    public func activate() {
        isRouteActive = true
        model.loadIfNeeded()
    }

    /// 离开关注来源时由 App 经来源描述调用：标记不在本页，再交给列表取消在途请求。
    public func deactivateRoute() {
        isRouteActive = false
        model.deactivateRoute()
    }

    /// 侧栏选中一行；同一行不重新加载。
    public func select(rowID: Int64) {
        guard rowID != selectedRowID else { return }
        selectedRowID = rowID
        _ = keyword.clear()
        model.reloadReplacingContent()
    }

    public func selectOrder(_ order: FollowListOrder) {
        guard order != self.order else { return }
        self.order = order
        model.reloadReplacingContent()
    }

    /// 提交规范化后的草稿作为关键词；与已应用的相同时不重新加载。
    public func submitSearch() {
        guard keyword.submit() else { return }
        model.reloadReplacingContent()
    }

    /// 关窗、登出与换号：条件恢复默认，丢弃列表内容（不发请求）。
    public func reset() {
        resetCriteria()
        model.reset()
    }

    /// 窗口账户范围变化：条件恢复默认，再交给列表丢弃上一账户的内容并按需重新加载。
    public func synchronizeAuthenticationSession(scope: AccountSessionScope, isCurrentRoute: Bool) {
        resetCriteria()
        model.synchronizeAuthenticationSession(scope: scope, isCurrentRoute: isCurrentRoute)
    }

    /// 当前条件的第一页；关键词规范化后为空时就是全部关注。
    func firstPageCursor() -> FollowListCursor? {
        guard isShowingAllFollowings else { return FollowListCursor(query: .group(selectedRowID)) }
        if !appliedKeyword.isEmpty {
            return FollowListUseCase.searchCursor(for: appliedKeyword)
        }
        return FollowListCursor(query: .all(order))
    }

    /// 写入确认这个人的关系变成了 `relation`：已不关注，或已不在正在显示的分组里时，从列表里去掉这张卡片。
    ///
    /// 刚加入这个分组的人不插入（位置只有服务端知道），由 App 的关系存储在宽限期后让这一页重读。由 App 的写入效果路由调用。
    public func relationDidChange(_ relation: FollowRelation, mid: Int64) {
        let stillListed =
            isShowingAllFollowings
            ? relation.isFollowing : relation.allowsMembership(in: selectedRowID)
        guard !stillListed else { return }
        _ = removeUser(mid: mid)
    }

    /// 乐观移除一个人（卡片菜单的取消关注），不在列表里时为 nil；失败时交回 `model.restoreItem` 放回原位。
    public func removeUser(mid: Int64) -> LibraryVideoListRemoval<FollowedUser, FollowListCursor>? {
        model.removeItem(bvid: String(mid))
    }

    /// 选中的分组已不存在时回落到全部关注，规则同收藏夹（`FavoriteFolderViewModel`）：在本页时照常重读；不在本页时只改
    /// 选择并丢弃旧分组的内容（取消在途请求），不在后台读取，回来时由 `activate()` 从未加载开始读。
    private func groupListDidLoad(_ list: FollowGroupList) {
        guard !isShowingAllFollowings, !list.groups.contains(where: { $0.id == selectedRowID })
        else {
            return
        }
        guard isRouteActive else {
            selectedRowID = Self.allFollowingsRowID
            _ = keyword.clear()
            model.reset()
            return
        }
        select(rowID: Self.allFollowingsRowID)
    }

    private func resetCriteria() {
        selectedRowID = Self.allFollowingsRowID
        order = .recentlyFollowed
        keyword = LibrarySearchKeyword()
    }
}
