import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliLibraryFeature

@Suite(.timeLimit(.minutes(1)))
struct WatchHistoryViewModelTests {
    @Test
    @MainActor
    func loadsAndPaginatesWithoutDuplicatingBVIDs() async throws {
        let continuation = token(100)
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        continuation: continuation
                    )
                ),
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1"), item("BV1HistoryB2")],
                        continuation: nil
                    )
                )
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        #expect(model.isBusy)
        await model.waitForCurrentTask()
        #expect(model.successfulReloadGeneration == 1)
        let firstTailIdentity = model.paginationTailIdentity
        #expect(!model.isBusy)
        model.loadMore()
        #expect(model.isBusy)
        await model.waitForCurrentTask()
        #expect(!model.isBusy)
        #expect(model.successfulReloadGeneration == 1)

        guard case .loaded(let items, let nextContinuation, let error) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryA1", "BV1HistoryB2"])
        #expect(nextContinuation == nil)
        #expect(error == nil)
        #expect(firstTailIdentity != nil)
        #expect(model.paginationTailIdentity == nil)
        #expect(await repository.observedContinuations() == [nil, continuation])
    }

    /// 加载更多失败保留条目与 continuation，并暂停自动加载（没有尾标）；重试请求同一 continuation。
    @Test
    @MainActor
    func loadMoreFailureKeepsItemsPausesAutomaticLoadingAndRetriesSameContinuation() async {
        let continuation = token(100)
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        continuation: continuation
                    )
                ),
                .failure(ContentApplicationError.transportFailure),
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryB2")],
                        continuation: nil
                    )
                )
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        let tailIdentity = model.paginationTailIdentity
        model.loadMore()

        #expect(
            model.state
                == .loadingMore(
                    items: [item("BV1HistoryA1")],
                    continuation: continuation
                )
        )
        await model.waitForCurrentTask()

        #expect(
            model.state
                == .loaded(
                    items: [item("BV1HistoryA1")],
                    continuation: continuation,
                    loadMoreError: .transportFailure
                )
        )
        #expect(tailIdentity != nil)
        #expect(model.paginationTailIdentity == nil)
        #expect(!model.requiresManualLoadMore)
        #expect(!model.isBusy)

        model.loadMore()
        await model.waitForCurrentTask()

        #expect(
            model.state
                == .loaded(
                    items: [item("BV1HistoryA1"), item("BV1HistoryB2")],
                    continuation: nil,
                    loadMoreError: nil
                )
        )
        #expect(await repository.observedContinuations() == [nil, continuation, continuation])
    }

    @Test
    @MainActor
    func emptyPaginationPageRequiresExplicitContinueAndThenRearms() async {
        let first = token(100)
        let second = token(200)
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        continuation: first
                    )
                )
            ] + emptyPagesEnding(at: second) + [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryB2")],
                        continuation: nil
                    )
                )
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()

        #expect(
            model.state
                == .loaded(
                    items: [item("BV1HistoryA1")],
                    continuation: second,
                    loadMoreError: nil
                )
        )
        #expect(model.requiresManualLoadMore)
        #expect(model.paginationTailIdentity == nil)

        model.loadMore()
        await model.waitForCurrentTask()

        guard case .loaded(let items, let continuation, _) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryA1", "BV1HistoryB2"])
        #expect(continuation == nil)
        #expect(!model.requiresManualLoadMore)
    }

    @Test
    @MainActor
    func manualPaginationFailureKeepsExplicitRetryAndCanRecover() async {
        let first = token(100)
        let manual = token(200)
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        continuation: first
                    )
                )
            ] + emptyPagesEnding(at: manual) + [
                .failure(ContentApplicationError.transportFailure),
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryB2")],
                        continuation: nil
                    )
                )
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()
        #expect(model.requiresManualLoadMore)

        model.loadMore()
        await model.waitForCurrentTask()
        #expect(model.requiresManualLoadMore)
        #expect(
            model.state
                == .loaded(
                    items: [item("BV1HistoryA1")],
                    continuation: manual,
                    loadMoreError: .transportFailure
                )
        )

        model.loadMore()
        await model.waitForCurrentTask()
        guard case .loaded(let items, let continuation, let error) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryA1", "BV1HistoryB2"])
        #expect(continuation == nil)
        #expect(error == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func reloadPreventsOlderResultFromOverwritingNewIntent() async throws {
        let repository = HistoryRepositoryStub(
            results: [
                .success(WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: nil)),
                .success(WatchHistoryPage(items: [item("BV1HistoryB2")], continuation: nil))
            ],
            suspendedCalls: [1]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.reload()
        try await repository.waitUntilCallCount(1)
        model.reload()
        try await repository.waitUntilCancellationCount(1)
        await model.waitForCurrentTask()
        await repository.releaseCall(1)

        guard case .loaded(let items, _, _) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryB2"])
        #expect(model.successfulReloadGeneration == 1)
    }

    /// 已有条目时刷新原地进行：刷新期间条目保持显示且不分页，成功后整体替换并推进刷新代次。
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func refreshKeepsItemsVisibleUntilTheNewPageArrives() async throws {
        let repository = HistoryRepositoryStub(
            results: [
                .success(WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: token(1))),
                .success(WatchHistoryPage(items: [item("BV1HistoryB2")], continuation: nil))
            ],
            suspendedCalls: [2]
        )
        let model = WatchHistoryViewModel(useCase: WatchHistoryUseCase(repository: repository))
        model.reload()
        await model.waitForCurrentTask()

        model.reload()
        try await repository.waitUntilCallCount(2)
        let duringRefresh = model.state
        let wasRefreshing = model.isRefreshing
        let wasBusy = model.isBusy
        model.loadMore()
        let tailDuringRefresh = model.paginationTailIdentity
        await repository.releaseCall(2)
        await model.waitForCurrentTask()

        #expect(wasRefreshing)
        #expect(wasBusy)
        #expect(tailDuringRefresh == nil)
        guard case .loaded(let oldItems, _, _) = duringRefresh else {
            Issue.record("刷新期间历史状态不是 loaded")
            return
        }
        #expect(oldItems.map(\.bvid) == ["BV1HistoryA1"])
        guard case .loaded(let newItems, _, _) = model.state else {
            Issue.record("刷新后历史状态不是 loaded")
            return
        }
        #expect(newItems.map(\.bvid) == ["BV1HistoryB2"])
        #expect(!model.isRefreshing)
        #expect(model.refreshError == nil)
        #expect(model.successfulReloadGeneration == 2)
        #expect(await repository.observedContinuations() == [nil, nil])
    }

    /// 原地刷新失败保留已显示条目并恢复自动分页；凭据缺失或失效进入终态并请求复核，
    /// 本地凭据读不到只给出刷新错误。
    @Test(arguments: [
        (ContentApplicationError.transportFailure, true),
        (.authenticationUnavailable, true),
        (.authenticationRequired, false),
        (.authenticationInvalid, false)
    ])
    @MainActor
    func refreshFailureKeepsItemsUnlessAuthenticationExpired(
        failure: ContentApplicationError,
        keepsItems: Bool
    ) async {
        let repository = HistoryRepositoryStub(
            results: [
                .success(WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: token(1))),
                .failure(failure)
            ]
        )
        let model = WatchHistoryViewModel(useCase: WatchHistoryUseCase(repository: repository))
        model.reload()
        await model.waitForCurrentTask()

        model.reload()
        await model.waitForCurrentTask()

        #expect(!model.isRefreshing)
        if keepsItems {
            guard case .loaded(let items, let continuation, nil) = model.state else {
                Issue.record("刷新失败后历史状态不是 loaded")
                return
            }
            #expect(items.map(\.bvid) == ["BV1HistoryA1"])
            #expect(continuation == token(1))
            #expect(model.refreshError == failure)
            #expect(model.paginationTailIdentity != nil)
            #expect(model.successfulReloadGeneration == 1)
        } else {
            #expect(model.state == .failed(failure))
            #expect(model.authenticationRevalidationGeneration == 1)
        }
    }

    /// 原地刷新期间收起“加载更早的记录”（刷新中加载更多不会开始），刷新失败后显式继续门与它的 continuation 原样恢复，
    /// 不会变成自动连续扫描。
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func refreshWithdrawsTheManualContinueEntryUntilItFails() async throws {
        let manual = token(904)
        let prefix: [Result<WatchHistoryPage, any Error>] =
            [.success(WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: token(1)))]
            + emptyPagesEnding(at: manual)
        let repository = HistoryRepositoryStub(
            results: prefix + [.failure(ContentApplicationError.transportFailure)],
            suspendedCalls: [prefix.count + 1]
        )
        let model = WatchHistoryViewModel(useCase: WatchHistoryUseCase(repository: repository))
        model.reload()
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()
        #expect(model.requiresManualLoadMore)

        model.reload()
        try await repository.waitUntilCallCount(prefix.count + 1)
        let offeredDuringRefresh = model.requiresManualLoadMore
        let wasRefreshing = model.isRefreshing
        await repository.releaseCall(prefix.count + 1)
        await model.waitForCurrentTask()

        #expect(wasRefreshing)
        #expect(!offeredDuringRefresh)
        #expect(model.refreshError == .transportFailure)
        #expect(model.requiresManualLoadMore)
        #expect(model.paginationTailIdentity == nil)
        guard case .loaded(_, let continuation, _) = model.state else {
            Issue.record("刷新失败后历史状态不是 loaded")
            return
        }
        #expect(continuation == manual)
    }

    /// 离开页面会取消原地刷新，保留条目、恢复刷新前的分页状态，并清掉刷新错误。
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func leavingDuringRefreshKeepsItems() async throws {
        let repository = HistoryRepositoryStub(
            results: [
                .success(WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: token(1))),
                .success(WatchHistoryPage(items: [item("BV1HistoryB2")], continuation: nil))
            ],
            suspendedCalls: [2]
        )
        let model = WatchHistoryViewModel(useCase: WatchHistoryUseCase(repository: repository))
        model.reload()
        await model.waitForCurrentTask()

        model.reload()
        try await repository.waitUntilCallCount(2)
        model.deactivateRoute()
        await repository.releaseCall(2)
        await model.waitForCurrentTask()

        #expect(!model.isRefreshing)
        guard case .loaded(let items, _, _) = model.state else {
            Issue.record("离开后历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryA1"])
        #expect(model.paginationTailIdentity != nil)
        #expect(model.successfulReloadGeneration == 1)
    }

    @Test
    @MainActor
    func resetClearsPersonalizedItemsFromMemory() async {
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        continuation: nil
                    )
                )
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.reset()

        #expect(model.state == .idle)
    }

    @Test
    @MainActor
    func resetRejectsLatePaginationContinuationMutation() async throws {
        let oldContinuation = token(100)
        let intermediateContinuation = token(200)
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1OldA")],
                        continuation: oldContinuation
                    )
                ),
                .success(
                    WatchHistoryPage(
                        items: [item("BV1OldB")],
                        continuation: intermediateContinuation
                    )
                ),
                .success(
                    WatchHistoryPage(
                        items: [item("BV1NewA")],
                        continuation: intermediateContinuation
                    )
                ),
                .success(
                    WatchHistoryPage(
                        items: [item("BV1NewB")],
                        continuation: oldContinuation
                    )
                )
            ],
            suspendedCalls: [2]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.reload()
        await model.waitForCurrentTask()
        model.loadMore()
        try await repository.waitUntilCallCount(2)
        model.reset()
        try await repository.waitUntilCancellationCount(1)
        model.reload()
        await model.waitForCurrentTask()
        await repository.releaseCall(2)
        model.loadMore()
        await model.waitForCurrentTask()

        guard case .loaded(let items, let continuation, let error) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1NewA", "BV1NewB"])
        #expect(continuation == oldContinuation)
        #expect(error == nil)
    }

    enum Interruption: CaseIterable, Sendable {
        case resetInitialLoad
        case deactivateInitialLoad
        case deactivatePagination
        case deactivateManualPagination
    }

    @Test(arguments: Interruption.allCases)
    @MainActor
    func interruptionCancelsInFlightLoadAndRejectsItsLateResult(
        _ interruption: Interruption
    ) async throws {
        let first = token(100)
        let manual = token(200)
        let firstPage: Result<WatchHistoryPage, any Error> = .success(
            WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: first)
        )
        let prefix: [Result<WatchHistoryPage, any Error>] =
            switch interruption {
            case .resetInitialLoad, .deactivateInitialLoad: []
            case .deactivatePagination: [firstPage]
            case .deactivateManualPagination: [firstPage] + emptyPagesEnding(at: manual)
            }
        let lateResult: Result<WatchHistoryPage, any Error> = .success(
            WatchHistoryPage(items: [item("BV1HistoryB2")], continuation: nil)
        )
        let repository = HistoryRepositoryStub(
            results: prefix + [lateResult],
            suspendedCalls: [prefix.count + 1]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        if !prefix.isEmpty {
            await model.waitForCurrentTask()
            if interruption == .deactivateManualPagination {
                model.loadMore()
                await model.waitForCurrentTask()
                #expect(model.requiresManualLoadMore)
            }
            model.loadMore()
        }
        try await repository.waitUntilCallCount(prefix.count + 1)
        if interruption == .resetInitialLoad {
            model.reset()
        } else {
            model.deactivateRoute()
        }
        try await repository.waitUntilCancellationCount(1)
        await repository.releaseCall(prefix.count + 1)

        switch interruption {
        case .resetInitialLoad, .deactivateInitialLoad:
            #expect(model.state == .idle)
        case .deactivatePagination:
            #expect(
                model.state
                    == .loaded(
                        items: [item("BV1HistoryA1")],
                        continuation: first,
                        loadMoreError: nil
                    )
            )
            #expect(!model.requiresManualLoadMore)
        case .deactivateManualPagination:
            #expect(
                model.state
                    == .loaded(
                        items: [item("BV1HistoryA1")],
                        continuation: manual,
                        loadMoreError: nil
                    )
            )
            #expect(model.requiresManualLoadMore)
            #expect(model.paginationTailIdentity == nil)
        }
    }
}
