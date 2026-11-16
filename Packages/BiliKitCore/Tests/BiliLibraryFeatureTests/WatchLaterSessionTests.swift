import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliLibraryFeature

/// 稍后再看会话：排序、应用筛选、提交或清空关键词都以新条件的第一页从空列表重新加载，旧条件的在途结果不并入；
/// 弹窗草稿未应用不发请求，超长的关键词提交被忽略；有筛选或关键词时界面可给出“清除筛选”；`reset` 与账户变化把条件
/// 恢复为默认。
@Suite(.timeLimit(.minutes(1)))
struct WatchLaterSessionTests {
    /// 超长的关键词与空间页一样忽略这次提交：不发请求、不进失败页，原来的列表留着（规则在 `LibrarySearchKeyword`，
    /// 收藏夹与关注共用）。
    @Test
    @MainActor
    func overlongKeywordSubmissionIsIgnored() async {
        let repository = WatchLaterRepositoryStub(
            results: [laterPage(["BV1Old"], page: 1, next: nil, total: 1)]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let session = WatchLaterSession(model: model)
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        session.searchDraft = String(repeating: "猫", count: SearchText.maximumLength + 1)
        session.submitSearch()
        await model.waitForCurrentTask()

        #expect(await repository.requests.count == 1)
        #expect(session.appliedKeyword.isEmpty)
        if case .loaded(let items, _, _) = model.state {
            #expect(items.map(\.bvid) == ["BV1Old"])
        } else {
            Issue.record("列表不应离开已加载状态：\(model.state)")
        }
    }

    @Test
    @MainActor
    func criteriaChangeReloadsFromScratchAndDropsTheOldInFlightResult() async throws {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1Old"], page: 1, next: nil, total: 1),
                laterPage(["BV1New"], page: 1, next: nil, total: 7)
            ],
            suspendedCalls: [1]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let session = WatchLaterSession(model: model)

        model.loadIfNeeded()
        try await repository.waitUntilCallCount(1)
        session.filterSelection.order = .oldestAdded
        session.selectOrder(.oldestAdded)
        #expect(model.state == .loading)
        await model.waitForCurrentTask()
        await repository.releaseCall(1)

        #expect(
            model.state
                == .loaded(items: [laterItem("BV1New")], continuation: nil, loadMoreError: nil)
        )
        #expect(model.totalCount == 7)
        #expect(model.successfulReloadGeneration == 1)
        let requests = await repository.requests
        #expect(requests.map(\.criteria.order) == [.newestAdded, .oldestAdded])
    }

    /// 已显示条目时换条件也不原地刷新：旧条件的条目立即撤下，进入加载。
    @Test
    @MainActor
    func criteriaChangeDoesNotKeepTheOldItemsOnScreen() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1Old"], page: 1, next: 2, total: 30),
                laterPage(["BV1New"], page: 1, next: nil, total: 1)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let session = WatchLaterSession(model: model)
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        session.searchDraft = "猫"
        #expect(await repository.requests.count == 1)
        session.submitSearch()

        #expect(model.state == .loading)
        #expect(model.totalCount == nil)
        await model.waitForCurrentTask()
        #expect(session.narrowsResults)
        #expect(
            await repository.requests.last
                == WatchLaterRequest(criteria: WatchLaterCriteria(keyword: "猫"))
        )
    }

    /// 下一页沿用当前条件。
    @Test
    @MainActor
    func nextPageKeepsTheAppliedCriteria() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1Old"], page: 1, next: nil),
                laterPage(["BV1A"], page: 1, next: 2),
                laterPage(["BV1B"], page: 2, next: nil)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let session = WatchLaterSession(model: model)
        model.loadIfNeeded()
        await model.waitForCurrentTask()
        var selection = session.filterSelection
        selection.progress = .unfinished
        selection.duration = .overSixtyMinutes

        session.applyFilters(selection)
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()

        let expected = WatchLaterCriteria(progress: .unfinished, duration: .overSixtyMinutes)
        #expect(
            await repository.requests == [
                WatchLaterRequest(),
                WatchLaterRequest(criteria: expected, page: 1),
                WatchLaterRequest(criteria: expected, page: 2)
            ]
        )
    }

    /// 弹窗只编辑选择的草稿副本；没有“应用”时不发请求、已应用的条件不变。
    @Test
    @MainActor
    func editingTheSelectionWithoutApplyingSendsNothing() async {
        let repository = WatchLaterRepositoryStub(results: [laterPage(["BV1A"], page: 1, next: nil)]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let session = WatchLaterSession(model: model)
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        session.filterSelection.progress = .unfinished
        session.searchDraft = "未提交"

        #expect(session.firstPageRequest() == WatchLaterRequest())
        #expect(!session.narrowsResults)
        #expect(await repository.requests.count == 1)
    }

    /// 清空搜索框即恢复全部；清除筛选同时清掉关键词，保留排序。
    @Test
    @MainActor
    func clearingRestoresEverythingButTheOrder() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1A"], page: 1, next: nil),
                laterPage([], page: 1, next: nil),
                laterPage(["BV1A"], page: 1, next: nil),
                laterPage([], page: 1, next: nil),
                laterPage(["BV1A"], page: 1, next: nil),
                laterPage(["BV1A"], page: 1, next: nil)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let session = WatchLaterSession(model: model)
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        session.searchDraft = "猫"
        session.submitSearch()
        await model.waitForCurrentTask()
        session.searchDraft = " "
        await model.waitForCurrentTask()
        #expect(session.appliedKeyword.isEmpty)

        session.filterSelection.order = .oldestAdded
        session.selectOrder(.oldestAdded)
        await model.waitForCurrentTask()
        var selection = session.filterSelection
        selection.duration = .underTenMinutes
        session.applyFilters(selection)
        await model.waitForCurrentTask()
        #expect(session.narrowsResults)

        session.clearFilters()
        await model.waitForCurrentTask()

        #expect(
            session.firstPageRequest()
                == WatchLaterRequest(criteria: WatchLaterCriteria(order: .oldestAdded))
        )
        #expect(session.filterSelection.activeFilterCount == 0)
        #expect(session.searchDraft.isEmpty)
        #expect(!session.narrowsResults)
        #expect(await repository.requests.count == 6)
    }

    @Test
    @MainActor
    func resetAndAccountChangeRestoreTheDefaultCriteria() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1A"], page: 1, next: nil),
                laterPage(["BV1B"], page: 1, next: nil),
                laterPage(["BV1C"], page: 1, next: nil),
                laterPage(["BV1D"], page: 1, next: nil),
                laterPage(["BV1E"], page: 1, next: nil)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let session = WatchLaterSession(model: model)
        model.loadIfNeeded()
        await model.waitForCurrentTask()
        session.searchDraft = "猫"
        session.submitSearch()
        await model.waitForCurrentTask()

        session.reset()
        #expect(model.state == .idle)
        #expect(session.firstPageRequest() == WatchLaterRequest())
        #expect(session.searchDraft.isEmpty)
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        session.filterSelection.order = .oldestAdded
        session.selectOrder(.oldestAdded)
        await model.waitForCurrentTask()
        session.synchronizeAuthenticationSession(
            scope: .signedIn(accountID: 2),
            isCurrentRoute: true
        )
        await model.waitForCurrentTask()

        #expect(session.filterSelection.order == .newestAdded)
        #expect(session.filterSelection.activeFilterCount == 0)
        let requests = await repository.requests
        #expect(
            requests.map(\.criteria) == [
                WatchLaterCriteria(),
                WatchLaterCriteria(keyword: "猫"),
                WatchLaterCriteria(),
                WatchLaterCriteria(order: .oldestAdded),
                WatchLaterCriteria()
            ]
        )
    }

    /// 刷新时第一页请求重新求值：区间不变时原地刷新（条目保持显示），变了（如跨过午夜）就清空重载。
    @Test
    @MainActor
    func refreshRevaluatesTheFirstPageAndReloadsFromScratchWhenItChanged() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1Day1"], page: 1, next: nil),
                laterPage(["BV1Day1"], page: 1, next: nil),
                laterPage(["BV1Day2"], page: 1, next: nil)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let day = RequestDay()
        let request = { (day: Int64) in
            WatchLaterRequest(
                criteria: WatchLaterCriteria(
                    addedTime: WatchLaterAddedTimeRange(
                        startTimestamp: day * 86_400,
                        endTimestamp: (day + 1) * 86_400
                    )
                )
            )
        }
        model.firstPageCursor = { request(day.value) }
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        model.reload()
        #expect(model.isRefreshing)
        await model.waitForCurrentTask()

        day.value = 2
        model.reload()
        #expect(model.state == .loading)
        await model.waitForCurrentTask()

        #expect(await repository.requests == [request(1), request(1), request(2)])
        #expect(
            model.state
                == .loaded(items: [laterItem("BV1Day2")], continuation: nil, loadMoreError: nil)
        )
    }

    /// 已应用的“今天”在每次刷新时按此刻重新解析，区间止于明天 0 点而不是解析时刻。
    @Test
    @MainActor
    func refreshThroughTheSessionResolvesTheRelativeRangeAgain() async throws {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1A"], page: 1, next: nil),
                laterPage(["BV1A"], page: 1, next: nil),
                laterPage(["BV1A"], page: 1, next: nil)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let session = WatchLaterSession(model: model)
        model.loadIfNeeded()
        await model.waitForCurrentTask()
        var selection = session.filterSelection
        selection.addedTime = .today
        session.applyFilters(selection)
        await model.waitForCurrentTask()

        // 刷新在内部取此刻解析“今天”；前后各取一次时刻，结果必须是其中之一的明天 0 点。只用事后的时刻比对时，
        // 刷新与比对之间若跨过本地午夜，两边的“今天”不同就会失败。
        let before = Date()
        session.refresh()
        await model.waitForCurrentTask()
        let after = Date()

        let requests = await repository.requests
        #expect(requests.count == 3)
        let range = try #require(requests[2].criteria.addedTime)
        let tomorrows = try [before, after].map { moment in
            let tomorrow = try #require(
                Calendar.current.date(
                    byAdding: .day,
                    value: 1,
                    to: Calendar.current.startOfDay(for: moment)
                )
            )
            return Int64(tomorrow.timeIntervalSince1970)
        }
        #expect(tomorrows.contains(range.endTimestamp))
        #expect(range.startTimestamp < range.endTimestamp)
    }
}

/// 测试里模拟“跨过午夜”的可变日序号；列表的第一页求值闭包在主线程读取它。
@MainActor
private final class RequestDay {
    var value: Int64 = 1
}
