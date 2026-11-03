import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliLibraryFeature

/// 稍后再看按页码翻页、没有下一页即停止，加载更多失败保留条目并重试同一页，刷新原地进行，`reset` 清空、
/// 离开页面只停用，凭据失败请求复核；账户变化的处理与观看历史是同一个模型，由 `WatchHistoryRevalidationTests` 固定。
@Suite(.timeLimit(.minutes(1)))
struct WatchLaterViewModelTests {
    @Test
    @MainActor
    func loadsAndAutoLoadsTheNextPageUntilTheLastPage() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1LaterA1"], page: 1, next: 2),
                laterPage(["BV1LaterA1", "BV1LaterB2"], page: 2, next: nil)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        #expect(model.paginationTailIdentity != nil)
        #expect(!model.requiresManualLoadMore)
        model.loadMore()
        await model.waitForCurrentTask()

        #expect(
            model.state
                == .loaded(
                    items: [laterItem("BV1LaterA1"), laterItem("BV1LaterB2")],
                    continuation: nil,
                    loadMoreError: nil
                )
        )
        #expect(model.paginationTailIdentity == nil)
        #expect(await repository.requestedPages == [1, 2])
    }

    @Test
    @MainActor
    func loadMoreFailureKeepsItemsAndRetriesTheSamePage() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1LaterA1"], page: 1, next: 2),
                .failure(ContentApplicationError.transportFailure),
                laterPage(["BV1LaterB2"], page: 2, next: nil)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()
        #expect(
            model.state
                == .loaded(
                    items: [laterItem("BV1LaterA1")],
                    continuation: WatchLaterRequest(page: 2),
                    loadMoreError: .transportFailure
                )
        )
        // 失败期间暂停自动加载。
        #expect(model.paginationTailIdentity == nil)

        model.loadMore()
        await model.waitForCurrentTask()

        #expect(
            model.state
                == .loaded(
                    items: [laterItem("BV1LaterA1"), laterItem("BV1LaterB2")],
                    continuation: nil,
                    loadMoreError: nil
                )
        )
        #expect(await repository.requestedPages == [1, 2, 2])
    }

    @Test
    @MainActor
    func refreshKeepsItemsOnFailureAndReplacesThemOnSuccess() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1LaterA1"], page: 1, next: nil),
                .failure(ContentApplicationError.transportFailure),
                laterPage(["BV1LaterC3"], page: 1, next: nil)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.reload()
        #expect(model.isRefreshing)
        await model.waitForCurrentTask()
        #expect(model.refreshError == .transportFailure)
        #expect(
            model.state
                == .loaded(items: [laterItem("BV1LaterA1")], continuation: nil, loadMoreError: nil)
        )

        model.reload()
        await model.waitForCurrentTask()

        #expect(model.refreshError == nil)
        #expect(model.successfulReloadGeneration == 2)
        #expect(
            model.state
                == .loaded(items: [laterItem("BV1LaterC3")], continuation: nil, loadMoreError: nil)
        )
    }

    @Test
    @MainActor
    func resetClearsAndDeactivationKeepsLoadedItems() async {
        let repository = WatchLaterRepositoryStub(
            results: [laterPage(["BV1LaterA1"], page: 1, next: nil)]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.deactivateRoute()
        #expect(
            model.state
                == .loaded(items: [laterItem("BV1LaterA1")], continuation: nil, loadMoreError: nil)
        )

        model.reset()

        #expect(model.state == .idle)
    }

    /// 稍后再看只在已登录时显示：凭据失效与本地无凭据都放弃条目并请求复核，复核确认后自动重载一次。
    @Test(arguments: [
        ContentApplicationError.authenticationInvalid,
        .authenticationRequired
    ])
    @MainActor
    func credentialFailureRequestsRevalidationAndReloadsOnce(
        failure: ContentApplicationError
    ) async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1LaterA1"], page: 1, next: 2),
                .failure(failure),
                laterPage(["BV1LaterA1"], page: 1, next: nil)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()
        #expect(model.state == .failed(failure))
        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(model.isAwaitingAuthenticationRevalidation)

        model.authenticationRevalidationSucceeded()
        await model.waitForCurrentTask()

        #expect(
            model.state
                == .loaded(items: [laterItem("BV1LaterA1")], continuation: nil, loadMoreError: nil)
        )
        #expect(await repository.requestedPages == [1, 2, 1])
    }

    /// 加载更多途中认证会话切换（请求以取消结束而本任务未被取消）：保留条目与游标，记为可重试的加载更多失败，
    /// 重试请求同一页；不会停在既没有入口也不再自动加载的状态。
    @Test
    @MainActor
    func sessionSwitchDuringLoadMoreLeavesARetryableFailure() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1LaterA1"], page: 1, next: 2, total: 2),
                .failure(CancellationError()),
                laterPage(["BV1LaterB2"], page: 2, next: nil, total: 3)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()

        guard case .loaded(let items, let continuation, let loadMoreError) = model.state else {
            Issue.record("会话切换后应保持 loaded")
            return
        }
        #expect(items == [laterItem("BV1LaterA1")])
        #expect(continuation == WatchLaterRequest(page: 2))
        #expect(loadMoreError?.isRetryable == true)
        #expect(!model.requiresManualLoadMore)

        model.loadMore()
        await model.waitForCurrentTask()

        #expect(await repository.requestedPages == [1, 2, 2])
        #expect(
            model.state
                == .loaded(
                    items: [laterItem("BV1LaterA1"), laterItem("BV1LaterB2")],
                    continuation: nil,
                    loadMoreError: nil
                )
        )
        // 加载更多成功时总数按响应更新。
        #expect(model.totalCount == 3)
    }
}
