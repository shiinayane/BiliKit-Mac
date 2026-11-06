/// 一页远端结果：本页条目与下一页游标；游标为 nil 表示远端没有更多。
package struct VideoListPage<Item, Cursor> {
    package let items: [Item]
    package let nextCursor: Cursor?

    package init(items: [Item], nextCursor: Cursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// 首页推荐、热门、搜索、观看历史、稍后再看与 UP 主空间投稿共用的分页列表。
///
/// 按 BVID 去重累积条目，决定何时继续、停止、暂停自动加载或要求用户显式继续，并给出近尾自动加载用的
/// 尾标；各条规则写在下方对应的成员上。
///
/// 拥有已显示条目、下一页游标、本次分页会话已消费的游标、加载更多与原地刷新是否进行、加载更多失败、
/// 显式继续门与尾标计数。不拥有网络请求、Task 与取消（ViewModel 的 `LatestTask`）、请求身份与账户
/// generation、凭据失败策略与刷新成功代次（各 ViewModel），也不跳过空页（历史的 `WatchHistoryUseCase`）。
/// 纯同步值类型：调用方只在自己的最新意图仍有效时调用变更方法，迟到的旧结果由调用方丢弃，不交给本类型。
package struct PagedVideoList<Item, Cursor: Equatable & Sendable> {
    /// 一页没有并入任何新条目（空页、全重复页或已没有余量）时的处理。
    package enum StallPolicy: Sendable, Equatable {
        /// 停止翻页：推荐、热门、搜索、稍后再看与空间投稿再请求下一页也不会更有进展。
        case stop
        /// 保留游标但收起尾标，由用户显式继续：历史的空页之后可能还有更早的记录，但不在后台连续扫描。
        case requireManualContinue
    }

    package private(set) var items: [Item] = []
    /// 与 `items` 一一对应的并入序号：每并入一条取 `nextOrdinal` 并递增，`replaceFirstPage` 时从头编号。
    ///
    /// 只用于乐观移除的回滚定位：序号在同一分页会话里随列表顺序严格递增，回滚时插到第一个序号更大的条目之前，连续移除
    /// 多条再以任意顺序回滚也能回到原来的相对位置；只记绝对下标或单个邻居都做不到。
    private var ordinals: [UInt64] = []
    private var nextOrdinal: UInt64 = 0
    /// 下一页游标；nil 表示远端已到底、`.stop` 遇到无进展页、达到条目上限（显式继续策略另有页数上限），
    /// 或检测到游标回环。
    package private(set) var nextCursor: Cursor?
    package private(set) var isLoadingMore = false
    /// 最近一次加载更多的失败：存在时暂停自动加载，显式重试经 `beginLoadMore` 请求同一游标。
    package private(set) var loadMoreError: ContentApplicationError?
    /// 无进展页之后要用户显式继续；为 true 时不给尾标。
    package private(set) var requiresManualContinue = false
    /// 原地刷新进行中：条目保持显示，尾标收起，不加载更多。
    package private(set) var isRefreshing = false

    private let stallPolicy: StallPolicy
    /// 本次分页会话（自最近一次 `replaceFirstPage`）加载更多请求过的游标。
    ///
    /// 新的下一页游标落在其中即回环（含游标不前进）；数量即已加载更多的页数。`.stop` 下每页至少并入一条，
    /// 数量已被条目上限封住；`.requireManualContinue` 下另封顶 `VideoListRetention.maximumLoadedPages`。
    /// 线性查找随之有界。
    private var consumedCursors: [Cursor] = []
    /// 尾标计数：每次并入新条目（> 0 条）时递增，在同一实例内从不回退，刷新与失败都不改变它。
    ///
    /// 网格的 `NearEndPagination` 比对它：同一尾标只触发一次，变化才为新尾部布防；所以无新增的页不会让
    /// 网格立即再触发。调用方换用新实例（新的工作集、首次加载、失败或 `reset`）时计数从 0 重新开始：
    /// 这些路径都先经过不显示网格的阶段（骨架或失败页），网格连同 `NearEndPagination` 已卸载重建，
    /// 不会把新实例的尾标误认作旧尾部。
    private var tailGeneration: UInt64 = 0
    /// 本次加载更多开始前是否处于显式继续门；加载失败或被取消时据此恢复，避免被打断的显式继续变成自动扫描。
    private var requiredManualContinueBeforeLoad = false

    package init(stallPolicy: StallPolicy) {
        self.stallPolicy = stallPolicy
    }

    /// 近尾自动加载的尾标：仍有下一页、且没有因失败、显式继续门或原地刷新而暂停时为当前尾标计数，否则 nil。
    ///
    /// 加载更多进行中保持不变，网格另按加载状态背压。
    package var tailIdentity: UInt64? {
        guard nextCursor != nil, !requiresManualContinue, loadMoreError == nil, !isRefreshing
        else { return nil }
        return tailGeneration
    }

    /// 是否给出显式继续入口：需要显式继续且不在原地刷新时为 true。
    ///
    /// 与尾标一样在刷新期间收起：刷新中 `beginLoadMore` 不会开始，入口留着只会点了无效；刷新失败或取消后
    /// 随 `restoreAfterFailedRefresh` 恢复。
    package var offersManualContinue: Bool {
        requiresManualContinue && !isRefreshing
    }

    /// 首次加载或刷新成功：整体替换条目，开始新的分页会话（清空已消费游标、失败与进行状态）。
    package mutating func replaceFirstPage(
        _ page: VideoListPage<Item, Cursor>,
        bvid: (Item) -> String
    ) {
        items = []
        ordinals = []
        nextOrdinal = 0
        consumedCursors = []
        isRefreshing = false
        isLoadingMore = false
        loadMoreError = nil
        requiredManualContinueBeforeLoad = false
        merge(page, cursorLoops: false, bvid: bvid)
    }

    /// 开始加载更多；近尾自动加载、显式继续与失败后重试共用。
    ///
    /// 返回调用方应请求的游标（失败后重试仍是同一游标）；正在加载、原地刷新或没有下一页时返回 nil，
    /// 调用方不发请求。
    package mutating func beginLoadMore() -> Cursor? {
        guard !isLoadingMore, !isRefreshing, let nextCursor else { return nil }
        requiredManualContinueBeforeLoad = requiresManualContinue
        requiresManualContinue = false
        loadMoreError = nil
        isLoadingMore = true
        return nextCursor
    }

    /// 并入游标 `requested` 对应的一页；`requested` 必须是 `beginLoadMore` 刚返回、仍在等待的游标。
    ///
    /// 没有进行中的加载时什么也不做；不衔接时按无效响应记为加载失败。新的下一页游标已被本会话请求过
    /// （回环）时停止翻页并报告 `.invalidResponse`；即使同时达到条目上限也报告，回环是接口异常，不被上限吞掉。
    package mutating func apply(
        _ page: VideoListPage<Item, Cursor>,
        requested: Cursor,
        bvid: (Item) -> String
    ) {
        guard isLoadingMore else { return }
        guard requested == nextCursor else {
            failLoadMore(.invalidResponse)
            return
        }
        isLoadingMore = false
        consumedCursors.append(requested)
        let cursorLoops = page.nextCursor.map(consumedCursors.contains) ?? false
        merge(page, cursorLoops: cursorLoops, bvid: bvid)
        if cursorLoops {
            loadMoreError = .invalidResponse
        }
    }

    /// 加载更多失败：条目与游标不变，恢复开始前的显式继续门；失败期间不给尾标（暂停自动加载）。
    ///
    /// 没有进行中的加载时什么也不做，迟到的失败不会改写已替换的列表。
    package mutating func failLoadMore(_ error: ContentApplicationError) {
        guard isLoadingMore else { return }
        isLoadingMore = false
        requiresManualContinue = requiredManualContinueBeforeLoad
        loadMoreError = error
    }

    /// 加载更多被取消：条目与游标不变；没有进行中的加载时什么也不做。
    ///
    /// `requiringManualContinue` 为 true 时之后要用户显式继续（请求被外部中断，例如认证会话切换），
    /// 否则恢复开始前的显式继续门（被离开页面或刷新取代）。
    package mutating func cancelLoadMore(requiringManualContinue: Bool) {
        guard isLoadingMore else { return }
        isLoadingMore = false
        requiresManualContinue = requiringManualContinue || requiredManualContinueBeforeLoad
    }

    /// 开始原地刷新：条目保持显示并收起尾标，取代进行中的加载更多并清除加载更多失败。
    ///
    /// 刷新期间不改动游标、显式继续门与尾标计数：成功时由 `replaceFirstPage` 整体替换，失败或被取消时
    /// `restoreAfterFailedRefresh` 即回到刷新前的分页状态。
    package mutating func beginRefresh() {
        cancelLoadMore(requiringManualContinue: false)
        loadMoreError = nil
        isRefreshing = true
    }

    /// 原地刷新失败或被取消：条目、游标与显式继续门仍是刷新前的样子，尾标随之恢复为刷新前的值。
    package mutating func restoreAfterFailedRefresh() {
        isRefreshing = false
    }

    /// 本地移除的一条：被移除的条目与它的并入序号，交回 `restore(_:bvid:)` 放回原位。
    package struct Removal {
        package let item: Item
        fileprivate let ordinal: UInt64
    }

    /// 按 BVID 从已显示条目里移除一条（稍后再看的乐观移除）；没有这条时为 nil。
    ///
    /// 不改游标、尾标、加载与刷新状态：服务端确认之前这只是本地视图的变化。调用方负责在列表被整体替换后不再交回
    /// 旧的 `Removal`（本类型不知道两次之间是否换过内容）。
    package mutating func remove(id: String, bvid: (Item) -> String) -> Removal? {
        guard let index = items.firstIndex(where: { bvid($0) == id }) else { return nil }
        return Removal(item: items.remove(at: index), ordinal: ordinals.remove(at: index))
    }

    /// 把移除的条目放回原位（写入失败的回滚）：插到第一个并入序号比它大的条目之前，没有就放到末尾；同一 BVID 已在
    /// 列表里时不重复放入。
    package mutating func restore(_ removal: Removal, bvid: (Item) -> String) {
        let id = bvid(removal.item)
        guard !items.contains(where: { bvid($0) == id }) else { return }
        let index = ordinals.firstIndex { $0 > removal.ordinal } ?? items.count
        items.insert(removal.item, at: index)
        ordinals.insert(removal.ordinal, at: index)
    }

    /// 按 BVID 去重并截到条目上限后并入，再按上限、回环与无进展策略决定下一页游标。
    private mutating func merge(
        _ page: VideoListPage<Item, Cursor>,
        cursorLoops: Bool,
        bvid: (Item) -> String
    ) {
        let remainingCapacity = Swift.max(0, VideoListRetention.maximumItemCount - items.count)
        let appended = page.items.uniquedByBVID(after: items, bvid).prefix(remainingCapacity)
        items += appended
        ordinals += (0..<UInt64(appended.count)).map { nextOrdinal + $0 }
        nextOrdinal += UInt64(appended.count)
        if !appended.isEmpty {
            tailGeneration &+= 1
        }
        requiresManualContinue = false
        // 页数上限只约束显式继续：`.stop` 下每页至少并入一条，页数已被条目上限封住，再加页数上限会让
        // 每批条目较少的来源（推荐）在条目上限之前静默停止。
        let reachedLimit =
            items.count >= VideoListRetention.maximumItemCount
            || (stallPolicy == .requireManualContinue
                && consumedCursors.count >= VideoListRetention.maximumLoadedPages)
        guard let next = page.nextCursor, !cursorLoops, !reachedLimit else {
            nextCursor = nil
            return
        }
        guard appended.isEmpty else {
            nextCursor = next
            return
        }
        switch stallPolicy {
        case .stop:
            nextCursor = nil
        case .requireManualContinue:
            nextCursor = next
            requiresManualContinue = true
        }
    }
}

extension VideoListPage: Sendable where Item: Sendable, Cursor: Sendable {}

extension PagedVideoList: Sendable where Item: Sendable {}

extension PagedVideoList.Removal: Sendable where Item: Sendable {}

extension PagedVideoList: Equatable where Item: Equatable {}
