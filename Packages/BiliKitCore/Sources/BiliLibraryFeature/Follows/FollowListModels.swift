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
    public convenience init(
        useCase: FollowListUseCase,
        accountID: @escaping @MainActor () -> Int64?
    ) {
        self.init(
            stallPolicy: .stop,
            pageSize: FollowListUseCase.pageSize,
            maximumItemCount: FollowListUseCase.maximumItemCount,
            bvid: { String($0.id) },
            load: { cursor in
                guard let cursor else { throw ContentApplicationError.invalidRequest }
                guard let ownerID = accountID() else { throw CancellationError() }
                return try await useCase.page(cursor, ownerID: ownerID)
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
