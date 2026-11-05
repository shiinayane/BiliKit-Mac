import BiliApplication
import BiliModels
import Foundation
import Observation

/// 资料库视频列表页的呈现状态，由 `LibraryVideoListModel.state` 从加载阶段与 `PagedVideoList` 投影得出。
///
/// `loaded` 的 continuation 为 nil 表示已到底；`loadingMore` 的 continuation 是正在请求的那一页。
public enum LibraryVideoListState<Item: Sendable & Equatable, Cursor: Equatable & Sendable>:
    Sendable,
    Equatable
{
    case idle
    case loading
    case loaded(
        items: [Item],
        continuation: Cursor?,
        loadMoreError: ContentApplicationError?
    )
    case loadingMore(
        items: [Item],
        continuation: Cursor
    )
    case failed(ContentApplicationError)
}

/// 资料库里只按账户读取的视频列表（观看历史、稍后再看）共用的 ViewModel：拥有当前登录会话的列表
/// （`PagedVideoList`）、加载阶段、凭据复核状态与最新请求 Task。
///
/// 两个来源只在分页游标、第一页游标、无进展页策略与读取闭包上不同，由各自的构造入口给出（`WatchHistoryViewModel`、
/// `WatchLaterViewModel`）。游标是完整请求时（稍后再看的条件加页码），第一页游标在每次开始新的分页会话时由
/// `firstPageCursor` 重新求值（稍后再看的相对加入时间因此按当时的日历解析）；条件变化由来源的会话经
/// `reloadReplacingContent()` 从空列表重新加载；旧条件的迟到结果由 `LatestTask` 丢弃，旧条件的下一页游标也与新列表
/// 的游标不等而被 `PagedVideoList` 拒收。去重、上限、无进展页、回环、加载更多失败与原地刷新的分页恢复都由 `PagedVideoList`
/// 承担；空页跳过等来源规则在各自的 Use Case。`reset` 会清除个性化内容；普通路由停用只取消在途请求，并在分页或
/// 刷新中断时保留已显示条目。已有条目时刷新原地进行：条目保持显示，成功后整体替换，失败时保留条目并给出
/// `refreshError`；凭据缺失或失效则放弃条目、转入失败页并请求账户复核。
@MainActor
@Observable
public final class LibraryVideoListModel<
    Item: Sendable & Equatable,
    Cursor: Equatable & Sendable
>: AccountRevalidationParticipant {
    /// 读取一页：传入第一页游标（来源没有时为 nil）或列表给出的下一页游标，返回这一页与来源给出的总条数（没有时
    /// 为 nil）。
    ///
    /// 失败抛出 `ContentApplicationError`，取消原样传播。
    typealias Load =
        @MainActor (Cursor?) async throws -> (page: VideoListPage<Item, Cursor>, totalCount: Int?)

    /// `phase` 与列表的投影；`.loadingMore` 时的 continuation 就是正在请求的那一页。
    public var state: LibraryVideoListState<Item, Cursor> {
        switch phase {
        case .idle:
            .idle
        case .loading:
            .loading
        case .failed(let error):
            .failed(error)
        case .loaded:
            if list.isLoadingMore, let continuation = list.nextCursor {
                .loadingMore(items: list.items, continuation: continuation)
            } else {
                .loaded(
                    items: list.items,
                    continuation: list.nextCursor,
                    loadMoreError: list.loadMoreError
                )
            }
        }
    }

    /// 每次加载成功（含首次加载与原地刷新）递增；App 只在它前进时把这个来源的网格滚回顶部。
    public private(set) var successfulReloadGeneration: UInt64 = 0
    /// 最近一次原地刷新失败的原因，条目仍是刷新前的内容；下一次刷新开始时清除。
    public private(set) var refreshError: ContentApplicationError?
    /// 读取发现凭据缺失或失效时递增，由窗口汇总后复核账户（`AccountRevalidationParticipant`，与其他内容页同一契约）；
    /// 规则在共用的 `AccountRevalidationProgress`。
    public var authenticationRevalidationGeneration: Int {
        revalidation.generation
    }
    /// 本页因凭据缺失或失效请求了账户复核、复核尚未结束；失败页据此显示“正在重新确认”。
    ///
    /// 复核结束（`authenticationRevalidationSucceeded`／`authenticationRevalidationFailed`）、
    /// 加载成功、离开页面或 `reset` 时清除。
    public var isAwaitingAuthenticationRevalidation: Bool {
        revalidation.isAwaiting
    }
    /// 来源给出的当前条件下的总条数：第一页与加载更多成功时都按响应更新；首次加载、条件变化、失败与 `reset` 时
    /// 清空，只在已显示内容时有值。
    public private(set) var totalCount: Int?
    /// 加载中的骨架应画的本页条数。
    ///
    /// 每次清空重载开始时求值：上次成功加载得到的总条数属于这次要加载的同一第一页游标（同一条件）时，取它与每页
    /// 条数的较小者，否则为 nil、骨架铺满。首次进入、条件变化与 `reset` 后为 nil；观看历史没有总数，始终为 nil。
    /// 只用已经拿到的总数，不另发请求。
    package private(set) var expectedLoadingItemCount: Int?

    /// 已有条目时的原地刷新正在进行；首次加载仍是 `.loading`。
    public var isRefreshing: Bool {
        list.isRefreshing
    }

    /// 近尾自动加载的尾标计数，只供 renderer 对 near-end 事件去重，不编码远端游标；没有下一页、
    /// 需要显式继续、加载更多失败或原地刷新时为 nil。
    public var paginationTailIdentity: UInt64? {
        list.tailIdentity
    }

    /// 无进展页保留游标时（显式继续策略），必须由用户显式继续，避免 near-end 连续扫描；原地刷新期间收起，
    /// 刷新失败后恢复。
    ///
    /// 停止策略的来源总是 false：它们没有显式继续入口，加载更多被认证会话切换打断时改记为可重试的加载更多失败。
    public var requiresManualLoadMore: Bool {
        list.offersManualContinue
    }

    public var isBusy: Bool {
        switch phase {
        case .loading:
            true
        case .loaded:
            list.isRefreshing || list.isLoadingMore
        case .idle, .failed:
            false
        }
    }

    /// 列表页的加载阶段；已加载的条目与分页状态在 `list`。
    private enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(ContentApplicationError)
    }

    private var phase: Phase = .idle
    /// 只在 `phase == .loaded` 时被显示；首次加载、失败与 `reset` 时换成空列表，不留下旧账户的条目。
    private var list: PagedVideoList<Item, Cursor>

    /// 每次开始新的分页会话（首次加载、刷新、复核后重载、条件变化）时求值的第一页游标；观看历史恒为 nil，稍后再看
    /// 由会话按当前条件与此刻解析给出。
    ///
    /// 由来源会话在构造后设置一次（`WatchLaterSession.init`）。返回值与当前显示内容的第一页游标不同时，刷新不原地
    /// 进行而是清空重载：条件或解析出的区间变了，旧条目不能留在新请求下显示。
    @ObservationIgnored var firstPageCursor: @MainActor () -> Cursor?
    /// 当前显示内容来自哪个第一页游标；第一页加载成功时记录，`reset` 与失败时清空。
    @ObservationIgnored private var displayedFirstPageCursor: Cursor?
    /// 最近一次成功加载得到的总条数与它所属的第一页游标。
    ///
    /// 第一页与加载更多成功时按响应更新，条件变化与 `reset` 时清空。失败不清空：同条件重试时骨架仍按它画，
    /// 账户变化由 `reset` 清除。
    @ObservationIgnored private var knownTotal: (firstPageCursor: Cursor?, count: Int)?
    /// 来源每页条数，用来把已知总数封顶为一页；来源没有总数（观看历史）时为 nil。
    @ObservationIgnored private let pageSize: Int?
    @ObservationIgnored private let stallPolicy: PagedVideoList<Item, Cursor>.StallPolicy
    @ObservationIgnored private let load: Load
    @ObservationIgnored private let bvid: (Item) -> String
    /// 刷新与加载更多共用的最新意图 Task：新请求替换旧请求，迟到结果经 `isCurrent` 丢弃；`reset` 与
    /// `deactivateRoute` 取消。
    @ObservationIgnored private let loadTask = LatestTask()
    /// 显示的内容是否已被别处的写入改变，等下一次 `loadIfNeeded` 原地刷新；`reload` 开始时清除。
    @ObservationIgnored private var needsReload = false
    /// 显示的列表每被整体替换一次（换成空列表或第一页加载成功）以 `&+=` 递增；`restoreItem` 只在与移除时相同才放回。
    @ObservationIgnored private var contentGeneration: UInt64 = 0
    /// 复核代次、是否在等复核与复核后是否已自动重载过。
    private var revalidation = AccountRevalidationProgress()

    init(
        stallPolicy: PagedVideoList<Item, Cursor>.StallPolicy,
        pageSize: Int?,
        firstPageCursor: @escaping @MainActor () -> Cursor? = { nil },
        bvid: @escaping (Item) -> String,
        load: @escaping Load
    ) {
        self.firstPageCursor = firstPageCursor
        self.stallPolicy = stallPolicy
        self.pageSize = pageSize
        self.bvid = bvid
        self.load = load
        list = PagedVideoList(stallPolicy: stallPolicy)
    }

    /// 页面出现、账户变化或复核成功时调用：从未加载（idle）时加载；已显示内容但被标记为过期
    /// （`markNeedsReload`）时原地刷新一次；其他状态不动作。
    public func loadIfNeeded() {
        switch phase {
        case .idle:
            reload()
        case .loaded where needsReload:
            reload()
        case .loading, .loaded, .failed:
            break
        }
    }

    /// 本列表在服务端的内容已被别处的写入改变（另一视图或另一窗口加入、移除了稍后再看）：只记下过期，不在后台读取。
    ///
    /// 下一次页面出现（`loadIfNeeded`）时原地刷新；由 App 的写入效果路由调用。
    public func markNeedsReload() {
        needsReload = true
    }

    /// 乐观移除一条（稍后再看页的移除）：先从显示的列表里删掉，总数减一；没有这条或列表不在已加载状态时为 nil。
    ///
    /// 服务端确认之前只是本地变化，写入失败时交回 `restoreItem` 放回原位。由 App 的写入协调者调用，Task 也归它。
    public func removeItem(bvid: String) -> LibraryVideoListRemoval<Item, Cursor>? {
        guard phase == .loaded, let removal = list.remove(id: bvid, bvid: self.bvid) else {
            return nil
        }
        totalCount = totalCount.map { max(0, $0 - 1) }
        return LibraryVideoListRemoval(removal: removal, contentGeneration: contentGeneration)
    }

    /// 写入失败的回滚：放回原位，总数加一。
    ///
    /// 移除之后列表被整体替换过（刷新成功、条件变化、账户变化、失败或 `reset`）时不再放回：新内容已经是服务端此刻的
    /// 状态，旧条目放进去会与新内容混排，账户变化时还会把上一账户的条目放进新账户的列表。
    public func restoreItem(_ removal: LibraryVideoListRemoval<Item, Cursor>) {
        guard phase == .loaded, removal.contentGeneration == contentGeneration else { return }
        let before = list.items.count
        list.restore(removal.removal, bvid: bvid)
        if list.items.count > before {
            totalCount = totalCount.map { $0 + 1 }
        }
    }

    public func reload() {
        needsReload = false
        let firstPageCursor = firstPageCursor()
        // 已有条目（或正在加载更多）且第一页游标不变时原地刷新，与首页、热门一致：网格不卸载，成功后由刷新代次回到
        // 顶部。游标变了（稍后再看的条件或解析出的区间不同）就清空重载。
        let refreshesInPlace =
            phase == .loaded && (!list.items.isEmpty || list.isLoadingMore)
            && firstPageCursor == displayedFirstPageCursor
        refreshError = nil
        if refreshesInPlace {
            list.beginRefresh()
        } else {
            replaceList()
            totalCount = nil
            displayedFirstPageCursor = nil
            expectedLoadingItemCount = expectedItemCount(firstPageCursor: firstPageCursor)
            phase = .loading
        }
        loadTask.replace { [weak self] isCurrent in
            guard let self else { return }
            do {
                let result = try await load(firstPageCursor)
                guard isCurrent() else { return }
                list.replaceFirstPage(result.page, bvid: bvid)
                contentGeneration &+= 1
                displayedFirstPageCursor = firstPageCursor
                totalCount = result.totalCount
                knownTotal = result.totalCount.map { (firstPageCursor, $0) }
                phase = .loaded
                successfulReloadGeneration &+= 1
                revalidation.loadSucceeded()
            } catch is CancellationError {
                // 本任务未被取消却收到取消：认证会话在请求途中切换。不是网络失败；已有条目原样保留，
                // 否则回到 idle，由会话切换后的复核与 `authenticationRevalidationSucceeded` 重新加载。
                guard isCurrent() else { return }
                if refreshesInPlace {
                    list.restoreAfterFailedRefresh()
                } else {
                    phase = .idle
                }
            } catch {
                guard isCurrent() else { return }
                let failure = error as? ContentApplicationError ?? .unavailable
                // 原地刷新失败保留已显示条目；凭据缺失或失效进入终态，条目不再显示。
                if refreshesInPlace, !LibraryAccountRevalidation.isCredentialFailure(failure) {
                    refreshError = failure
                    list.restoreAfterFailedRefresh()
                } else {
                    fail(failure)
                }
            }
        }
    }

    /// 近尾自动加载、显式继续与加载更多失败后的重试共用：请求列表给出的同一游标。
    public func loadMore() {
        guard phase == .loaded, let continuation = list.beginLoadMore() else { return }
        loadTask.replace { [weak self] isCurrent in
            guard let self else { return }
            do {
                let result = try await load(continuation)
                guard isCurrent() else { return }
                list.apply(result.page, requested: continuation, bvid: bvid)
                if let totalCount = result.totalCount {
                    self.totalCount = totalCount
                    knownTotal = (displayedFirstPageCursor, totalCount)
                }
            } catch is CancellationError {
                // 认证切换带来的取消只保留已显示条目，不变成自动扫描。显式继续策略的来源（历史）要求用户显式继续；
                // 停止策略的来源（稍后再看）没有显式继续入口，记为可重试的加载更多失败，底部的重试请求同一游标，
                // 否则底部既没有入口也不再自动加载。
                guard isCurrent() else { return }
                switch stallPolicy {
                case .requireManualContinue:
                    list.cancelLoadMore(requiringManualContinue: true)
                case .stop:
                    list.failLoadMore(.unavailable)
                }
            } catch {
                guard isCurrent() else { return }
                let failure = error as? ContentApplicationError ?? .unavailable
                // 与刷新一致：凭据缺失或失效时不再显示该账户的条目，转入失败页并请求复核。
                if LibraryAccountRevalidation.isCredentialFailure(failure) {
                    fail(failure)
                } else {
                    list.failLoadMore(failure)
                }
            }
        }
    }

    /// 条件变化（稍后再看的排序、筛选或关键词）后从空列表重新加载。
    ///
    /// 不原地刷新：旧条件的条目不能留在新条件下显示。加载成功时 `successfulReloadGeneration` 前进，App 据此把网格
    /// 滚回顶部。由来源会话在改完条件后调用。
    func reloadReplacingContent() {
        replaceList()
        displayedFirstPageCursor = nil
        knownTotal = nil
        phase = .idle
        reload()
    }

    /// 窗口的账户范围变化（登出、换号、凭据失效后确认的新范围）时由 App 通知，只在已解析的变化时调用。
    ///
    /// 丢弃上一账户的列表；新范围已登录且本来源是当前来源时立即重新加载，其他来源回来时由页面的
    /// `loadIfNeeded` 加载。不像 Browse 那样按账户会话代次去重：本方法只由本窗口账户范围的变化驱动，每次
    /// 变化调用一次；其他窗口换号时本窗口在复核前另行 `reset`，复核得出新范围后才走到这里，那时进程代次可能
    /// 已经不变，按代次去重会吞掉这次加载。
    public func synchronizeAuthenticationSession(
        scope: AccountSessionScope,
        isCurrentRoute: Bool
    ) {
        reset()
        guard case .signedIn = scope, isCurrentRoute else { return }
        loadIfNeeded()
    }

    /// 取消请求并从内存删除全部个性化条目，供登出、换号与窗口关闭调用。
    public func reset() {
        loadTask.cancel()
        needsReload = false
        replaceList()
        totalCount = nil
        displayedFirstPageCursor = nil
        knownTotal = nil
        expectedLoadingItemCount = nil
        refreshError = nil
        revalidation.reset()
        phase = .idle
    }

    /// 停用页面请求而不抹掉已加载条目；迟到结果由 `LatestTask` 拒绝。
    ///
    /// 被打断的原地刷新恢复刷新前的分页，被打断的加载更多恢复开始前的显式继续门。离开页面后 App 不再把
    /// 复核结果交给本页：停止等待复核，凭据失败页回到 idle，回来时重新加载。
    public func deactivateRoute() {
        loadTask.cancel()
        refreshError = nil
        revalidation.stopAwaiting()
        list.restoreAfterFailedRefresh()
        list.cancelLoadMore(requiringManualContinue: false)
        switch phase {
        case .loading:
            phase = .idle
        case .failed(let failure) where LibraryAccountRevalidation.isCredentialFailure(failure):
            phase = .idle
        case .idle, .loaded, .failed:
            break
        }
    }

    public func waitForCurrentTask() async {
        await loadTask.wait()
    }

    /// 账户复核确认仍已登录（或会话切换后重新确认）；窗口只在本来源是当前来源时调用。
    ///
    /// 本页因凭据失效请求的复核，确认后自动重载一次；同一会话内只做一次，之后再失效只显示失败、
    /// 由用户重试。其余情况只在 idle 时加载。
    public func authenticationRevalidationSucceeded() {
        if revalidation.concluded() {
            reload()
        } else {
            loadIfNeeded()
        }
    }

    /// 账户复核没能确认登录状态（网络或 Keychain 不可用）；窗口只在本来源是当前来源时调用。
    ///
    /// 给出可重试的“无法读取登录状态”，不是网络失败。凭据失败时条目已清空；隐私清理仍由账户范围
    /// 变化负责。
    public func authenticationRevalidationFailed() {
        let requestedRevalidation = revalidation.failed()
        switch phase {
        case .idle:
            phase = .failed(.authenticationUnavailable)
        case .failed where requestedRevalidation:
            phase = .failed(.authenticationUnavailable)
        case .loading, .loaded, .failed:
            break
        }
    }

    /// 已知总数属于 `firstPageCursor`（同一条件）时，本页条数为它与每页条数的较小者；否则不知道。
    private func expectedItemCount(firstPageCursor: Cursor?) -> Int? {
        guard let pageSize, let knownTotal, knownTotal.firstPageCursor == firstPageCursor else {
            return nil
        }
        return min(pageSize, max(0, knownTotal.count))
    }

    private func emptyList() -> PagedVideoList<Item, Cursor> {
        PagedVideoList(stallPolicy: stallPolicy)
    }

    /// 换成空列表，并作废此前的乐观移除。
    private func replaceList() {
        list = emptyList()
        contentGeneration &+= 1
    }

    /// 进入失败页并放弃已显示条目；凭据失败时请求账户复核。
    private func fail(_ failure: ContentApplicationError) {
        if LibraryAccountRevalidation.isCredentialFailure(failure) {
            revalidation.request()
        }
        replaceList()
        totalCount = nil
        displayedFirstPageCursor = nil
        phase = .failed(failure)
    }
}

/// 乐观移除的凭据：被移除的条目、它的位置与移除时列表内容的代次，交回 `LibraryVideoListModel.restoreItem` 回滚。
public struct LibraryVideoListRemoval<Item: Sendable & Equatable, Cursor: Equatable & Sendable>:
    Sendable
{
    fileprivate let removal: PagedVideoList<Item, Cursor>.Removal
    fileprivate let contentGeneration: UInt64
}
