import BiliApplication
import BiliModels
import Foundation
import Testing
@testable import BiliLibraryFeature

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
                ),
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()

        guard case let .loaded(items, nextContinuation, error) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryA1", "BV1HistoryB2"])
        #expect(nextContinuation == nil)
        #expect(error == nil)
        #expect(await repository.observedContinuations() == [nil, continuation])
    }

    @Test
    @MainActor
    func authenticationFailureRequestsRevalidation() async {
        let repository = HistoryRepositoryStub(
            results: [.failure(.authenticationRequired)]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()

        #expect(model.state == .failed(.authenticationRequired))
        #expect(model.requiresAuthentication)
    }

    @Test
    @MainActor
    func initialFilteredEmptyPageContinuesUntilDisplayableItems() async throws {
        let continuation = token(100)
        let repository = HistoryRepositoryStub(
            results: [
                .success(WatchHistoryPage(items: [], continuation: continuation)),
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        continuation: nil
                    )
                ),
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()

        guard case let .loaded(items, nextContinuation, error) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryA1"])
        #expect(nextContinuation == nil)
        #expect(error == nil)
        #expect(await repository.observedContinuations() == [nil, continuation])
    }

    @Test
    @MainActor
    func reloadPreventsOlderResultFromOverwritingNewIntent() async throws {
        let repository = HistoryRepositoryStub(
            results: [
                .success(WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: nil)),
                .success(WatchHistoryPage(items: [item("BV1HistoryB2")], continuation: nil)),
            ],
            firstDelay: .milliseconds(50)
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.reload()
        try await Task.sleep(for: .milliseconds(5))
        model.reload()
        await model.waitForCurrentTask()
        try await Task.sleep(for: .milliseconds(60))

        guard case let .loaded(items, _, _) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryB2"])
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
                ),
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
    func resetCancelsInFlightLoadAndRejectsItsLateResult() async throws {
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        continuation: nil
                    )
                ),
            ],
            firstDelay: .milliseconds(40)
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        try await Task.sleep(for: .milliseconds(5))
        model.reset()
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.state == .idle)
    }
}

private func token(_ value: Int) -> WatchHistoryContinuation {
    WatchHistoryContinuation(rawValue: "fixture-\(value)")
}

private func item(_ bvid: String) -> WatchHistoryItem {
    WatchHistoryItem(
        bvid: bvid,
        title: "手写历史条目",
        coverURL: nil,
        owner: VideoOwner(id: 1, name: "测试作者"),
        progressSeconds: 10,
        durationSeconds: 100,
        viewedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private actor HistoryRepositoryStub: WatchHistoryRepository {
    private var results: [Result<WatchHistoryPage, WatchHistoryError>]
    private let firstDelay: Duration?
    private var callCount = 0
    private var continuations: [WatchHistoryContinuation?] = []

    init(
        results: [Result<WatchHistoryPage, WatchHistoryError>],
        firstDelay: Duration? = nil
    ) {
        self.results = results
        self.firstDelay = firstDelay
    }

    func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage {
        callCount += 1
        let currentCall = callCount
        continuations.append(continuation)
        guard !results.isEmpty else { throw WatchHistoryError.invalidResponse }
        let result = results.removeFirst()
        if currentCall == 1, let firstDelay {
            try? await Task.sleep(for: firstDelay)
        }
        return try result.get()
    }

    func observedContinuations() -> [WatchHistoryContinuation?] {
        continuations
    }
}
