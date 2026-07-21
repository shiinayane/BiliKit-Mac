import BiliApplication
import BiliModels
import Foundation
import Testing
@testable import BiliHistoryFeature

struct WatchHistoryViewModelTests {
    @Test
    @MainActor
    func loadsAndPaginatesWithoutDuplicatingBVIDs() async throws {
        let cursor = WatchHistoryCursor(
            maximum: 100,
            viewedAt: 200,
            business: "archive"
        )
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        nextCursor: cursor
                    )
                ),
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1"), item("BV1HistoryB2")],
                        nextCursor: nil
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

        guard case let .loaded(items, nextCursor, error) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryA1", "BV1HistoryB2"])
        #expect(nextCursor == nil)
        #expect(error == nil)
        #expect(await repository.observedCursors() == [nil, cursor])
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
    func reloadPreventsOlderResultFromOverwritingNewIntent() async throws {
        let repository = HistoryRepositoryStub(
            results: [
                .success(WatchHistoryPage(items: [item("BV1HistoryA1")], nextCursor: nil)),
                .success(WatchHistoryPage(items: [item("BV1HistoryB2")], nextCursor: nil)),
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
                        nextCursor: nil
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
                        nextCursor: nil
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
    private var cursors: [WatchHistoryCursor?] = []

    init(
        results: [Result<WatchHistoryPage, WatchHistoryError>],
        firstDelay: Duration? = nil
    ) {
        self.results = results
        self.firstDelay = firstDelay
    }

    func watchHistory(
        after cursor: WatchHistoryCursor?,
        pageSize: Int
    ) async throws -> WatchHistoryPage {
        callCount += 1
        let currentCall = callCount
        cursors.append(cursor)
        guard !results.isEmpty else { throw WatchHistoryError.invalidResponse }
        let result = results.removeFirst()
        if currentCall == 1, let firstDelay {
            try? await Task.sleep(for: firstDelay)
        }
        return try result.get()
    }

    func observedCursors() -> [WatchHistoryCursor?] {
        cursors
    }
}
