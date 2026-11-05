import BiliApplication
import BiliModels
import Foundation
import Observation

/// 收藏夹来源的 ViewModel：选中的收藏夹、夹内的排序与关键词、按页整体替换的当前页，以及请求与复核。
///
/// 每个窗口一份，由 App 的窗口组装构造，绑定收藏夹来源（只在本页时读取，见 SECURITY-MODEL §3）。拥有选中的收藏夹 ID、
/// 条件（排序菜单的选择与已应用的排序、搜索框草稿与已应用的关键词，只在窗口内存里）、翻页状态（`PageReplacementPaging`）、
/// 原地刷新、加载 Task 与账户复核进度；不拥有收藏夹列表（`FavoriteFolderListModel`，构造时接管它的加载成功通知，用来回落
/// 已不存在的选择）。
///
/// 换夹、换排序、提交或清空关键词与翻页都整体替换：旧请求由 `LatestTask` 取消、迟到结果丢弃，每次替换成功
/// `successfulReloadGeneration` 前进，App 据此把网格滚回顶部。换夹时清空关键词、保留排序、回到第 1 页。工具栏刷新在已有
/// 内容时原地重读当前页：内容保持显示，成功后整体替换，失败保留内容并给出 `refreshError`。夹内读取报告收藏夹不存在时
/// 重新读取收藏夹列表，列表到达后按回落规则改选。
///
/// 写入相关：「从此收藏夹移除」由 App 的写入协调者调用 `removeItem` 乐观移除、失败时 `restoreItem` 放回；别处的写入改了
/// 某个收藏夹时由写入效果路由调用 `markNeedsReload`，显示中的夹原地刷新，不在本页时回来再刷新。写入的 Task 不归这里。
@MainActor
@Observable
public final class FavoriteFolderViewModel: AccountRevalidationParticipant {
    /// 选中的收藏夹（media_id），没有选择时为 nil；侧栏据此高亮对应的行。
    public private(set) var selectedFolderID: Int64?
    /// 排序菜单的选择；菜单选中后经 `selectOrder` 生效。
    public var orderSelection = FavoriteFolderOrder.recentlyFavorited
    /// 当前内容使用的排序。
    public private(set) var appliedOrder = FavoriteFolderOrder.recentlyFavorited
    /// 工具栏搜索框的文字；清空（只剩空白）且已按关键词过滤时恢复全部，提交前不影响内容（规则在
    /// `LibrarySearchKeyword`，与稍后再看共用）。
    public var searchDraft: String {
        get { keyword.draft }
        set {
            if keyword.updateDraft(newValue) {
                replaceContent()
            }
        }
    }
    /// 当前内容使用的关键词；空串表示不按关键词过滤。
    public var appliedKeyword: String {
        keyword.applied
    }
    /// 每次整体替换成功（含原地刷新）递增；App 只在它前进时把这个来源的网格滚回顶部。
    ///
    /// 写入引起的原地刷新不递增，见 `refresh(keepingPosition:)`。
    public private(set) var successfulReloadGeneration: UInt64 = 0
    /// 已有内容时的原地刷新正在进行。
    public private(set) var isRefreshing = false
    /// 最近一次原地刷新失败的原因，内容仍是刷新前的；下一次请求开始时清除。
    public private(set) var refreshError: ContentApplicationError?

    /// 读取发现凭据缺失或失效时递增；规则在共用的 `AccountRevalidationProgress`。
    public var authenticationRevalidationGeneration: Int {
        revalidation.generation
    }

    /// 本页请求的账户复核尚未结束；失败页据此显示“正在重新确认”。
    public var isAwaitingAuthenticationRevalidation: Bool {
        revalidation.isAwaiting
    }

    /// 选中的收藏夹在列表里的元数据（标题、私密）；列表还没到或已不含它时为 nil。
    public var selectedFolder: FavoriteFolder? {
        guard let selectedFolderID else { return nil }
        return folderList.folders.first { $0.id == selectedFolderID }
    }

    /// 选中的收藏夹名称，App 用作导航标题；列表还没到或已不含它时为 nil。
    public var selectedFolderTitle: String? {
        selectedFolder?.title
    }

    /// 当前条件下的总条数（有关键词时是过滤后的条数）；翻页加载与失败期间保留，换夹或换条件后、第一页到达前为 nil。
    public var totalCount: Int? {
        paging.totalCount
    }

    /// 加载中的骨架应画的本页条数。
    ///
    /// 取侧栏收藏夹列表里该夹的 `media_count`，按当前页码与每页条数算出本页条数，不另发请求；换夹、翻页时跟着变，
    /// 排序不改变总数。有关键词时为 nil：`media_count` 是未过滤的总数。列表还没到或已不含该夹时为 nil，骨架铺满。
    package var expectedPageItemCount: Int? {
        guard appliedKeyword.isEmpty, let selectedFolder else { return nil }
        return PageNumbering.itemCount(
            onPage: paging.currentPage,
            totalCount: selectedFolder.mediaCount,
            pageSize: FavoritesUseCase.pageSize
        )
    }

    /// 有关键词在起作用；结果为空时界面据此给出“清除搜索”。
    public var narrowsResults: Bool {
        !appliedKeyword.isEmpty
    }

    /// 当前请求、显示或失败的页与内容。
    package var phase: PageReplacementPaging<FavoriteFolderPage>.Phase {
        paging.phase
    }

    package var currentPage: Int {
        paging.currentPage
    }

    package var pageCount: Int {
        paging.pageCount
    }

    /// 工具栏刷新按钮是否禁用：正在读取；没有选中收藏夹时刷新重读收藏夹列表，列表正在读或账户 mid 未知（读不了）时禁用。
    public var isBusy: Bool {
        guard selectedFolderID != nil else {
            switch folderList.state {
            case .loading, .accountUnidentified:
                return true
            case .idle, .loaded, .failed:
                return folderList.isRefreshing
            }
        }
        if isRefreshing { return true }
        if case .loading = paging.phase { return true }
        return false
    }

    let folderList: FavoriteFolderListModel
    private var paging = PageReplacementPaging<FavoriteFolderPage>()
    private var keyword = LibrarySearchKeyword()
    private var revalidation = AccountRevalidationProgress()
    @ObservationIgnored private let useCase: FavoritesUseCase
    /// 刷新、翻页与换条件共用的最新意图 Task；`reset` 与 `deactivateRoute` 取消。
    @ObservationIgnored private let loadTask = LatestTask()
    /// 收藏夹页面正在显示：`activate()` 置位，`deactivateRoute()` 清除。
    ///
    /// 只有显示时才因列表变化而加载新的选择。
    @ObservationIgnored private var isRouteActive = false
    /// 离开页面打断了加载、或留下了凭据失败页：回来时（`activate()`）重新读取当前页。
    @ObservationIgnored private var needsReloadOnActivation = false
    /// 显示的内容已被别处的写入改变（`markNeedsReload`），回来时（`activate()`）原地刷新；任何一次读取开始时清除。
    @ObservationIgnored private var isStale = false
    /// 显示的内容每被整体替换或丢弃一次就递增；乐观移除记下它，回滚时不符就不放回。
    @ObservationIgnored private var contentGeneration: UInt64 = 0

    public init(useCase: FavoritesUseCase, folderList: FavoriteFolderListModel) {
        self.useCase = useCase
        self.folderList = folderList
        folderList.onFoldersLoaded = { [weak self] in self?.folderListDidLoad($0) }
    }

    /// 收藏夹页面出现或选中的收藏夹变化时由页面调用：标记正在显示；没有内容时加载当前页，还没有选择时选默认收藏夹。
    public func activate() {
        isRouteActive = true
        guard selectedFolderID != nil else {
            selectFallback(in: folderList.folders)
            return
        }
        if paging.phase == .idle || needsReloadOnActivation {
            load(page: paging.currentPage)
        } else if isStale {
            refresh(keepingPosition: true)
        }
    }

    /// 侧栏选中一个收藏夹：换夹时取消在途请求、清空关键词、保留排序，从第 1 页整体替换；选中同一个收藏夹时只重试失败。
    public func selectFolder(_ folderID: Int64) {
        guard folderID != selectedFolderID else {
            if case .failed = paging.phase { load(page: paging.currentPage) }
            return
        }
        selectedFolderID = folderID
        _ = keyword.clear()
        replaceContent()
    }

    /// 页码条翻页；越界、正在显示或正在加载的页不请求，失败的页可以再次请求。
    public func showPage(_ page: Int) {
        guard selectedFolderID != nil, paging.accepts(page) else { return }
        load(page: page)
    }

    /// 排序菜单已把 `orderSelection` 设为 `order`。
    public func selectOrder(_ order: FavoriteFolderOrder) {
        guard order != appliedOrder else { return }
        appliedOrder = order
        replaceContent()
    }

    /// 提交规范化后的草稿作为关键词；与已应用的关键词相同时不重新加载。
    public func submitSearch() {
        guard keyword.submit() else { return }
        replaceContent()
    }

    /// 无结果空态的“清除搜索”：清空关键词与草稿并重新加载，保留排序。
    public func clearSearch() {
        guard keyword.clear() else { return }
        replaceContent()
    }

    /// 工具栏刷新与失败重试：已显示条目时原地重读当前页，否则重新读取当前页；没有选中收藏夹时重读收藏夹列表。
    public func reload() {
        refresh(keepingPosition: false)
    }

    /// `reload` 与写入引起的刷新共用；`keepingPosition` 时成功也不推进 `successfulReloadGeneration`，网格不回顶部：写入
    /// 只让本页多一条或少一条，用户正看着的位置不该跳走。
    private func refresh(keepingPosition: Bool) {
        guard selectedFolderID != nil else {
            folderList.reload()
            return
        }
        // 本页没有条目时三种空态都不显示网格与刷新胶囊：完整重读（骨架或失败页），否则刷新既看不到进度、失败也被吞掉。
        guard case .loaded(_, let content) = paging.phase, !content.items.isEmpty else {
            load(page: paging.currentPage)
            return
        }
        refreshError = nil
        isStale = false
        isRefreshing = true
        paging.beginRefresh()
        request(page: paging.currentPage, refreshing: true, keepingPosition: keepingPosition)
    }

    /// 离开收藏夹来源：取消请求，停止等待复核；被打断的加载与凭据失败页在回来时重新读取，已显示的内容保留。
    public func deactivateRoute() {
        isRouteActive = false
        loadTask.cancel()
        revalidation.stopAwaiting()
        isRefreshing = false
        refreshError = nil
        switch paging.phase {
        case .loading:
            needsReloadOnActivation = true
        case .failed(_, let failure) where LibraryAccountRevalidation.isCredentialFailure(failure):
            needsReloadOnActivation = true
        case .idle, .loaded, .failed:
            break
        }
    }

    /// 窗口的账户范围变化（登出、换号）：丢弃上一账户的选择、条件与内容。
    ///
    /// 仍在本页且已登录时，收藏夹列表重新到达后选中新账户的默认收藏夹。
    public func synchronizeAuthenticationSession() {
        reset()
    }

    /// 取消请求并从内存删除选择、条件与内容，供登出、换号与关窗调用；复核代次保留。
    public func reset() {
        discardContent()
        selectedFolderID = nil
        orderSelection = .recentlyFavorited
        appliedOrder = .recentlyFavorited
        keyword = LibrarySearchKeyword()
        revalidation.reset()
    }

    /// 乐观移除显示中的一条（「从此收藏夹移除」）。
    ///
    /// `entry` 属于显示中的收藏夹、本页已显示且有这条视频条目时从页里删掉、总数减一，否则为 nil。服务端确认之前只是本地
    /// 变化，写入失败或被取消时交回 `restoreItem`。由 App 的写入协调者调用，Task 也归它。
    public func removeItem(_ entry: FavoriteFolderEntry) -> FavoriteFolderRemoval? {
        guard entry.folderID == selectedFolderID,
            case .loaded(_, let content) = paging.phase,
            let index = content.items.firstIndex(where: { $0.videoAID == entry.videoAID })
        else { return nil }
        var items = content.items
        let item = items.remove(at: index)
        guard replaceDisplayedItems(items, of: content, totalCountDelta: -1) else { return nil }
        return FavoriteFolderRemoval(
            item: item,
            index: index,
            folderID: entry.folderID,
            contentGeneration: contentGeneration
        )
    }

    /// 写入失败的回滚：放回原位、总数加一。
    ///
    /// 移除之后内容被整体替换过（刷新、翻页、换夹、换条件、账户变化）时不放回：新内容已是服务端此刻的状态，旧条目放进去
    /// 会混排，账户变化时还会把上一账户的条目放进新账户的页面。
    public func restoreItem(_ removal: FavoriteFolderRemoval) {
        guard removal.contentGeneration == contentGeneration,
            removal.folderID == selectedFolderID,
            case .loaded(_, let content) = paging.phase,
            !content.items.contains(where: { $0.id == removal.item.id })
        else { return }
        var items = content.items
        items.insert(removal.item, at: min(removal.index, items.count))
        _ = replaceDisplayedItems(items, of: content, totalCountDelta: 1)
    }

    /// 写入成功时，显示的仍是这次乐观移除之后的内容：没有被整体替换过，也没有在途的读取。
    ///
    /// 期间落地的刷新或翻页带回的是写入前的快照，在途的读取也可能如此；这两种情况都要让效果路由按“未在本地改过”处理、
    /// 重读一次，否则服务端已删除的条目会一直显示。
    public func stillShowsRemoval(_ removal: FavoriteFolderRemoval) -> Bool {
        guard removal.contentGeneration == contentGeneration, !isRefreshing,
            case .loaded = paging.phase
        else { return false }
        return true
    }

    /// 收藏夹 `folderIDs` 在服务端的内容被别处的写入改变了（「收藏到…」面板、另一窗口）。
    ///
    /// 显示中的是其中之一时，正在显示就原地刷新，不在本页就记下、回来时刷新；不涉及显示中的夹时不动作。由 App 的写入
    /// 效果路由调用。
    public func markNeedsReload(folderIDs: Set<Int64>) {
        guard let selectedFolderID, folderIDs.contains(selectedFolderID) else { return }
        guard case .loaded = paging.phase else { return }
        if isRouteActive {
            refresh(keepingPosition: true)
        } else {
            isStale = true
        }
    }

    public func waitForCurrentTask() async {
        await loadTask.wait()
    }

    /// 账户复核确认仍已登录（窗口只在收藏夹是当前来源时调用）：本页请求的复核在本会话内自动重读一次当前页，其余情况只在
    /// 还没有内容时加载。
    public func authenticationRevalidationSucceeded() {
        guard selectedFolderID != nil else { return }
        if revalidation.concluded() || paging.phase == .idle {
            load(page: paging.currentPage)
        }
    }

    /// 账户复核没能确认登录状态（窗口只在收藏夹是当前来源时调用）：给出可重试的“无法读取登录状态”。
    public func authenticationRevalidationFailed() {
        let requestedRevalidation = revalidation.failed()
        guard selectedFolderID != nil else { return }
        switch paging.phase {
        case .idle:
            paging.fail(page: paging.currentPage, error: .authenticationUnavailable)
        case .failed(let page, _) where requestedRevalidation:
            paging.fail(page: page, error: .authenticationUnavailable)
        case .loading, .loaded, .failed:
            break
        }
    }

    /// 条件或收藏夹变了：丢弃旧内容与总数，从第 1 页重新读取。
    private func replaceContent() {
        contentGeneration &+= 1
        paging.reset()
        load(page: 1)
    }

    private func load(page: Int) {
        guard selectedFolderID != nil else { return }
        isStale = false
        isRefreshing = false
        refreshError = nil
        needsReloadOnActivation = false
        paging.beginLoading(page: page)
        request(page: page, refreshing: false, keepingPosition: false)
    }

    /// 发出 `page` 的请求；翻页状态已转为加载这一页，或正在原地刷新。
    ///
    /// `keepingPosition` 见 `refresh(keepingPosition:)`。
    private func request(page: Int, refreshing: Bool, keepingPosition: Bool) {
        guard let folderID = selectedFolderID else { return }
        let pageRequest = FavoriteFolderRequest(
            folderID: folderID,
            order: appliedOrder,
            keyword: appliedKeyword,
            page: page
        )
        let useCase = useCase
        loadTask.replace { [weak self] isCurrent in
            do {
                let result = try await useCase.page(pageRequest)
                guard let self, isCurrent() else { return }
                apply(result, page: page, keepingPosition: keepingPosition)
            } catch is CancellationError {
                // 本任务未被取消却收到取消：认证会话在请求途中切换。原地刷新保留内容，其余回到空闲，由账户范围变化或
                // 复核结果重新加载。
                guard let self, isCurrent() else { return }
                isRefreshing = false
                if !refreshing { paging.reset() }
            } catch {
                guard let self, isCurrent() else { return }
                fail(
                    error as? ContentApplicationError ?? .unavailable,
                    page: page,
                    refreshing: refreshing
                )
            }
        }
    }

    private func apply(_ result: FavoriteFolderPage, page: Int, keepingPosition: Bool) {
        isRefreshing = false
        let outcome = paging.succeed(
            page: page,
            content: result,
            totalCount: result.totalCount,
            pageSize: result.pageSize,
            hasMore: result.hasMore
        )
        switch outcome {
        case .show:
            contentGeneration &+= 1
            revalidation.loadSucceeded()
            if !keepingPosition {
                successfulReloadGeneration &+= 1
            }
        case .request(let target):
            // 请求的页已越界（总数在翻页期间变少）：`paging` 改请求最后一页，或先回第 1 页取得新总数。换了页就回顶部。
            request(page: target, refreshing: false, keepingPosition: false)
        }
    }

    private func fail(_ failure: ContentApplicationError, page: Int, refreshing: Bool) {
        isRefreshing = false
        if failure == .contentUnavailable {
            // 收藏夹已不存在（被删除或不属于当前账户）：原地刷新也不再保留旧内容；重读列表，到达后按回落规则改选。
            paging.fail(page: page, error: failure)
            folderList.reload()
            return
        }
        let isCredentialFailure = LibraryAccountRevalidation.isCredentialFailure(failure)
        // 原地刷新失败保留已显示内容；凭据失败不再显示该账户的内容。
        if refreshing, !isCredentialFailure {
            refreshError = failure
            return
        }
        if isCredentialFailure {
            revalidation.request()
        }
        paging.fail(page: page, error: failure)
    }

    /// 收藏夹列表加载成功：选中的收藏夹已不在列表里就回落；还没有选择而页面正在显示（例如换号后）就选默认收藏夹。
    private func folderListDidLoad(_ folders: [FavoriteFolder]) {
        if let selectedFolderID, folders.contains(where: { $0.id == selectedFolderID }) {
            return
        }
        guard selectedFolderID != nil || isRouteActive else { return }
        selectFallback(in: folders)
    }

    /// 回落到默认收藏夹（按标记识别，不靠位置），没有默认收藏夹时取第一个；不在本页时只改选择，回来时再加载。
    private func selectFallback(in folders: [FavoriteFolder]) {
        guard let fallback = folders.first(where: \.isDefault) ?? folders.first else { return }
        if isRouteActive {
            selectFolder(fallback.id)
        } else {
            // 不在本页：取消旧收藏夹的在途请求、丢弃它的内容，只改选择，回来时再加载。
            discardContent()
            selectedFolderID = fallback.id
            _ = keyword.clear()
        }
    }

    /// 取消在途请求并丢弃当前内容与刷新状态（`reset` 与不在本页时的回落共用）；选择与条件由调用方处理。
    private func discardContent() {
        contentGeneration &+= 1
        isStale = false
        loadTask.cancel()
        paging.reset()
        isRefreshing = false
        refreshError = nil
        needsReloadOnActivation = false
    }
}

extension FavoriteFolderViewModel {
    /// 换上本地改动后的条目（乐观移除或回滚），总数随之增减；条目以外的页信息不变。
    fileprivate func replaceDisplayedItems(
        _ items: [FavoriteItem],
        of content: FavoriteFolderPage,
        totalCountDelta: Int
    ) -> Bool {
        let totalCount = content.totalCount.map { max(0, $0 + totalCountDelta) }
        return paging.replaceLoadedContent(
            FavoriteFolderPage(
                items: items,
                pageNumber: content.pageNumber,
                pageSize: content.pageSize,
                totalCount: totalCount,
                hasMore: content.hasMore
            ),
            totalCount: totalCount ?? paging.totalCount
        )
    }
}

/// 一次乐观移除留下的回滚信息：被移除的条目、原位置、所在收藏夹与当时的内容代次；由写入协调者持有到写入结束。
public struct FavoriteFolderRemoval: Sendable {
    let item: FavoriteItem
    let index: Int
    let folderID: Int64
    let contentGeneration: UInt64
}
