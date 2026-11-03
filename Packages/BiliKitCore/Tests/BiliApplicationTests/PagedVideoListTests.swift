import Testing

@testable import BiliApplication

/// 五个列表来源共用的分页规则：按 BVID 去重并截到条目上限，无进展页按策略停止或要求显式继续，游标回环
/// 报无效响应，页数封顶，失败暂停自动加载并重试同一游标，原地刷新收起尾标、失败时恢复，尾标只在并入新
/// 条目时变化。
struct PagedVideoListTests {
    typealias List = PagedVideoList<String, Int>

    @Test
    func firstPageDeduplicatesAndTruncatesToCapacity() {
        var list = List(stallPolicy: .stop)
        let ids = (0..<1_200).map { "BV\($0)" }

        list.replaceFirstPage(page(["BV0"] + ids, next: 2), bvid: \.self)

        #expect(list.items == Array(ids.prefix(VideoListRetention.maximumItemCount)))
        #expect(list.nextCursor == nil)
        #expect(list.tailIdentity == nil)
        #expect(list.beginLoadMore() == nil)
    }

    @Test
    func appendSkipsLoadedAndRepeatedItemsAndAdvancesTheTail() {
        var list = List(stallPolicy: .stop)
        list.replaceFirstPage(page(["BV1A", "BV1B", "BV1A"], next: 2), bvid: \.self)
        let firstTail = list.tailIdentity

        let cursor = list.beginLoadMore()
        #expect(cursor == 2)
        #expect(list.isLoadingMore)
        #expect(list.tailIdentity == firstTail)
        list.apply(page(["BV1B", "BV1C", "BV1C"], next: 3), requested: 2, bvid: \.self)

        #expect(list.items == ["BV1A", "BV1B", "BV1C"])
        #expect(list.nextCursor == 3)
        #expect(!list.isLoadingMore)
        #expect(firstTail != nil)
        #expect(list.tailIdentity != nil)
        #expect(list.tailIdentity != firstTail)
    }

    @Test
    func reachingCapacityStopsPaginationWithoutATail() {
        var list = List(stallPolicy: .stop)
        list.replaceFirstPage(page((0..<999).map { "BV\($0)" }, next: 2), bvid: \.self)

        _ = list.beginLoadMore()
        list.apply(page((999..<1_005).map { "BV\($0)" }, next: 3), requested: 2, bvid: \.self)

        #expect(list.items.count == VideoListRetention.maximumItemCount)
        #expect(list.nextCursor == nil)
        #expect(list.loadMoreError == nil)
        #expect(list.tailIdentity == nil)
        #expect(list.beginLoadMore() == nil)
    }

    /// 推荐、热门与搜索无新增即停止；历史保留游标、收起尾标，由用户显式继续，有新增后重新给出尾标。
    @Test(arguments: [List.StallPolicy.stop, .requireManualContinue])
    func nonProgressingPageFollowsTheStallPolicy(_ policy: List.StallPolicy) {
        var list = List(stallPolicy: policy)
        list.replaceFirstPage(page(["BV1A"], next: 2), bvid: \.self)
        let tail = list.tailIdentity

        _ = list.beginLoadMore()
        list.apply(page(["BV1A"], next: 3), requested: 2, bvid: \.self)

        #expect(list.items == ["BV1A"])
        #expect(list.tailIdentity == nil)
        #expect(list.loadMoreError == nil)
        switch policy {
        case .stop:
            #expect(list.nextCursor == nil)
            #expect(!list.requiresManualContinue)
            #expect(list.beginLoadMore() == nil)
        case .requireManualContinue:
            #expect(list.nextCursor == 3)
            #expect(list.requiresManualContinue)
            #expect(list.beginLoadMore() == 3)
            #expect(!list.requiresManualContinue)
            list.apply(page(["BV1B"], next: 4), requested: 3, bvid: \.self)
            #expect(list.items == ["BV1A", "BV1B"])
            #expect(!list.requiresManualContinue)
            #expect(list.tailIdentity != nil)
            #expect(list.tailIdentity != tail)
        }
    }

    @Test(arguments: [List.StallPolicy.stop, .requireManualContinue])
    func emptyFirstPageFollowsTheStallPolicy(_ policy: List.StallPolicy) {
        var list = List(stallPolicy: policy)

        list.replaceFirstPage(page([], next: 2), bvid: \.self)

        #expect(list.tailIdentity == nil)
        #expect(list.nextCursor == (policy == .stop ? nil : 2))
        #expect(list.requiresManualContinue == (policy == .requireManualContinue))
    }

    /// 回环（回到请求过的游标，或游标不前进）是接口异常：停止翻页并报告，即使这一页恰好让条目达到上限也不被上限吞掉。
    ///
    /// 第二次加载请求游标 3：响应给出的下一页 2 回到请求过的游标，3 是游标不前进。
    @Test(arguments: [(2, false), (2, true), (3, false)])
    func cursorLoopReportsInvalidResponseEvenAtCapacity(nextCursor: Int, reachesCapacity: Bool) {
        var list = List(stallPolicy: .requireManualContinue)
        list.replaceFirstPage(page(["BV-first"], next: 2), bvid: \.self)
        _ = list.beginLoadMore()
        list.apply(page(["BV-second"], next: 3), requested: 2, bvid: \.self)

        _ = list.beginLoadMore()
        let items = reachesCapacity ? (0..<1_000).map { "BV\($0)" } : ["BV-third"]
        list.apply(page(items, next: nextCursor), requested: 3, bvid: \.self)

        #expect(list.items.count == (reachesCapacity ? 1_000 : 3))
        #expect(list.nextCursor == nil)
        #expect(list.loadMoreError == .invalidResponse)
        #expect(list.tailIdentity == nil)
        #expect(!list.requiresManualContinue)
    }

    /// 没有新条目的页不受条目上限约束，页数封顶让显式继续的扫描也有界。
    @Test
    func loadedPageLimitStopsPagination() {
        var list = List(stallPolicy: .requireManualContinue)
        list.replaceFirstPage(page(["BV-first"], next: 1), bvid: \.self)

        for cursor in 1...VideoListRetention.maximumLoadedPages {
            #expect(list.beginLoadMore() == cursor)
            list.apply(page([], next: cursor + 1), requested: cursor, bvid: \.self)
        }

        #expect(list.nextCursor == nil)
        #expect(!list.requiresManualContinue)
        #expect(list.loadMoreError == nil)
        #expect(list.beginLoadMore() == nil)
    }

    @Test
    func pageThatDoesNotAnswerThePendingCursorIsInvalid() {
        var list = List(stallPolicy: .stop)
        list.replaceFirstPage(page(["BV1A"], next: 2), bvid: \.self)

        _ = list.beginLoadMore()
        list.apply(page(["BV1B"], next: 4), requested: 3, bvid: \.self)

        #expect(list.items == ["BV1A"])
        #expect(list.nextCursor == 2)
        #expect(list.loadMoreError == .invalidResponse)
    }

    /// 失败保留条目与游标、暂停自动加载（没有尾标），显式重试请求同一游标；成功后尾标前进。
    @Test
    func failureKeepsCursorPausesTheTailAndRetriesTheSameCursor() {
        var list = List(stallPolicy: .stop)
        list.replaceFirstPage(page(["BV1A"], next: 2), bvid: \.self)
        let tail = list.tailIdentity

        _ = list.beginLoadMore()
        list.failLoadMore(.transportFailure)

        #expect(list.items == ["BV1A"])
        #expect(list.nextCursor == 2)
        #expect(list.loadMoreError == .transportFailure)
        #expect(!list.isLoadingMore)
        #expect(list.tailIdentity == nil)

        #expect(list.beginLoadMore() == 2)
        #expect(list.loadMoreError == nil)
        list.apply(page(["BV1B"], next: 3), requested: 2, bvid: \.self)
        #expect(list.items == ["BV1A", "BV1B"])
        #expect(list.tailIdentity != nil)
        #expect(list.tailIdentity != tail)
    }

    /// 被打断的显式继续不会变成自动扫描：失败或被取代时恢复显式继续门，被外部中断时要求显式继续。
    @Test
    func interruptedLoadRestoresOrRequiresTheManualContinueGate() {
        var list = List(stallPolicy: .requireManualContinue)
        list.replaceFirstPage(page([], next: 2), bvid: \.self)

        _ = list.beginLoadMore()
        list.failLoadMore(.transportFailure)
        #expect(list.requiresManualContinue)

        _ = list.beginLoadMore()
        list.cancelLoadMore(requiringManualContinue: false)
        #expect(list.requiresManualContinue)
        #expect(!list.isLoadingMore)

        var automatic = List(stallPolicy: .requireManualContinue)
        automatic.replaceFirstPage(page(["BV1A"], next: 2), bvid: \.self)
        let tail = automatic.tailIdentity
        _ = automatic.beginLoadMore()
        automatic.cancelLoadMore(requiringManualContinue: false)
        #expect(!automatic.requiresManualContinue)
        #expect(automatic.tailIdentity == tail)

        _ = automatic.beginLoadMore()
        automatic.cancelLoadMore(requiringManualContinue: true)
        #expect(automatic.requiresManualContinue)
        #expect(automatic.tailIdentity == nil)
        #expect(automatic.nextCursor == 2)
    }

    /// 原地刷新收起尾标、取代加载更多并清除其失败；失败或取消时恢复刷新前的尾标，成功时开始新的会话。
    @Test
    func refreshWithdrawsTheTailAndRestoresItWhenItFails() {
        var list = List(stallPolicy: .requireManualContinue)
        list.replaceFirstPage(page(["BV1A"], next: 2), bvid: \.self)
        _ = list.beginLoadMore()
        list.apply(page(["BV1B"], next: 3), requested: 2, bvid: \.self)
        let tail = list.tailIdentity
        _ = list.beginLoadMore()
        list.failLoadMore(.transportFailure)

        list.beginRefresh()
        #expect(list.isRefreshing)
        #expect(list.tailIdentity == nil)
        #expect(list.loadMoreError == nil)
        #expect(list.beginLoadMore() == nil)

        list.restoreAfterFailedRefresh()
        #expect(!list.isRefreshing)
        #expect(list.items == ["BV1A", "BV1B"])
        #expect(list.nextCursor == 3)
        #expect(list.tailIdentity == tail)

        _ = list.beginLoadMore()
        list.beginRefresh()
        #expect(!list.isLoadingMore)
        list.replaceFirstPage(page(["BV1C"], next: 2), bvid: \.self)
        #expect(!list.isRefreshing)
        #expect(list.items == ["BV1C"])
        #expect(list.tailIdentity != nil)
        #expect(list.tailIdentity != tail)
        // 新会话不记得刷新前请求过的游标：再次请求 2 不算回环。
        _ = list.beginLoadMore()
        list.apply(page(["BV1D"], next: 3), requested: 2, bvid: \.self)
        #expect(list.loadMoreError == nil)
        #expect(list.nextCursor == 3)
    }

    /// 显式继续入口与尾标一样在原地刷新期间收起（刷新中加载更多不会开始），刷新失败后恢复。
    @Test
    func refreshWithdrawsTheManualContinueEntryUntilItSettles() {
        var list = List(stallPolicy: .requireManualContinue)
        list.replaceFirstPage(page([], next: 2), bvid: \.self)
        #expect(list.offersManualContinue)

        list.beginRefresh()
        #expect(!list.offersManualContinue)
        #expect(list.beginLoadMore() == nil)

        list.restoreAfterFailedRefresh()
        #expect(list.offersManualContinue)
        #expect(list.nextCursor == 2)
    }

    /// 尾标只在并入新条目时变化：失败、重试中、无新增的页与刷新失败都不改变它。
    @Test
    func tailChangesOnlyWhenItemsAreAppended() {
        var list = List(stallPolicy: .requireManualContinue)
        list.replaceFirstPage(page(["BV1A"], next: 2), bvid: \.self)
        let first = list.tailIdentity

        _ = list.beginLoadMore()
        list.failLoadMore(.transportFailure)
        _ = list.beginLoadMore()
        #expect(list.tailIdentity == first)
        list.apply(page(["BV1A"], next: 3), requested: 2, bvid: \.self)
        _ = list.beginLoadMore()
        #expect(list.tailIdentity == first)
        list.apply(page(["BV1B"], next: 4), requested: 3, bvid: \.self)
        let second = list.tailIdentity

        list.beginRefresh()
        list.restoreAfterFailedRefresh()

        #expect(first != nil)
        #expect(second != nil)
        #expect(second != first)
        #expect(list.tailIdentity == second)
    }

    /// 无进展即停止的来源不受页数上限约束：每页至少新增一条时，翻过上限页数仍有下一页，只受条目上限约束。
    @Test
    func stopPolicyIsNotBoundedByThePageLimit() {
        var list = List(stallPolicy: .stop)
        list.replaceFirstPage(page(["BV-first"], next: 1), bvid: \.self)

        for cursor in 1...VideoListRetention.maximumLoadedPages {
            #expect(list.beginLoadMore() == cursor)
            list.apply(page(["BV\(cursor)"], next: cursor + 1), requested: cursor, bvid: \.self)
        }

        #expect(list.items.count == VideoListRetention.maximumLoadedPages + 1)
        #expect(list.nextCursor == VideoListRetention.maximumLoadedPages + 1)
        #expect(list.loadMoreError == nil)
        #expect(list.tailIdentity != nil)
    }

    /// 没有进行中的加载时，迟到的追加、失败与取消都不改动列表，不会留下“要显式继续却没有下一页”的组合。
    @Test
    func strayResultsWithoutAPendingLoadAreIgnored() {
        var list = List(stallPolicy: .requireManualContinue)
        list.replaceFirstPage(page([], next: 2), bvid: \.self)
        #expect(list.requiresManualContinue)
        _ = list.beginLoadMore()
        list.replaceFirstPage(page(["BV1A"], next: nil), bvid: \.self)
        let settled = list

        list.failLoadMore(.transportFailure)
        list.apply(page(["BV1B"], next: 3), requested: 2, bvid: \.self)
        list.cancelLoadMore(requiringManualContinue: true)

        #expect(list == settled)
        #expect(list.items == ["BV1A"])
        #expect(list.nextCursor == nil)
        #expect(!list.requiresManualContinue)
        #expect(list.loadMoreError == nil)
    }

    /// 乐观移除只改条目，不动游标与尾标；回滚放回原位，原位已越界时放到末尾，已在列表里的不重复放入。
    @Test
    func removeAndRestoreKeepPaginationAndPosition() throws {
        var list = List(stallPolicy: .stop)
        list.replaceFirstPage(page(["BV1A", "BV1B", "BV1C"], next: 2), bvid: \.self)
        let tail = list.tailIdentity

        let removed = list.remove(id: "BV1B", bvid: \.self)
        let removal = try #require(removed)
        #expect(list.items == ["BV1A", "BV1C"])
        #expect(list.nextCursor == 2)
        #expect(list.tailIdentity == tail)
        #expect(list.remove(id: "BV1Z", bvid: \.self) == nil)

        list.restore(removal, bvid: \.self)
        #expect(list.items == ["BV1A", "BV1B", "BV1C"])
        list.restore(removal, bvid: \.self)
        #expect(list.items == ["BV1A", "BV1B", "BV1C"])

        let removedLast = list.remove(id: "BV1C", bvid: \.self)
        let last = try #require(removedLast)
        _ = list.remove(id: "BV1B", bvid: \.self)
        list.restore(last, bvid: \.self)
        #expect(list.items == ["BV1A", "BV1C"])
    }

    /// 连续移除多条后以任意顺序回滚（含先移除先失败），都回到原来的相对位置；之后加载更多的条目仍排在后面。
    @Test(arguments: [
        (["BV1A", "BV1B"], [0, 1]),
        (["BV1A", "BV1B"], [1, 0]),
        (["BV1B", "BV1A"], [0, 1]),
        (["BV1C", "BV1A", "BV1B"], [1, 2, 0])
    ])
    func consecutiveRemovalsRollBackInAnyOrder(removed: [String], rollbackOrder: [Int]) throws {
        var list = List(stallPolicy: .stop)
        list.replaceFirstPage(page(["BV1A", "BV1B", "BV1C"], next: 2), bvid: \.self)
        var removals: [List.Removal] = []
        for id in removed {
            let removal = list.remove(id: id, bvid: \.self)
            removals.append(try #require(removal))
        }
        _ = list.beginLoadMore()
        list.apply(page(["BV1D"], next: nil), requested: 2, bvid: \.self)

        for index in rollbackOrder {
            list.restore(removals[index], bvid: \.self)
        }

        #expect(list.items == ["BV1A", "BV1B", "BV1C", "BV1D"])
    }

    private func page(_ items: [String], next: Int?) -> VideoListPage<String, Int> {
        VideoListPage(items: items, nextCursor: next)
    }
}
