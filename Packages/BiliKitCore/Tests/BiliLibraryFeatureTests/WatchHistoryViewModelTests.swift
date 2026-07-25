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
                ),
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        #expect(model.isBusy)
        await model.waitForCurrentTask()
        #expect(!model.isBusy)
        model.loadMore()
        #expect(model.isBusy)
        await model.waitForCurrentTask()
        #expect(!model.isBusy)

        guard case .loaded(let items, let nextContinuation, let error) = model.state else {
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

        guard case .loaded(let items, let nextContinuation, let error) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryA1"])
        #expect(nextContinuation == nil)
        #expect(error == nil)
        #expect(await repository.observedContinuations() == [nil, continuation])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func reloadPreventsOlderResultFromOverwritingNewIntent() async throws {
        let repository = HistoryRepositoryStub(
            results: [
                .success(WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: nil)),
                .success(WatchHistoryPage(items: [item("BV1HistoryB2")], continuation: nil)),
            ],
            suspendedCalls: [1]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.reload()
        try await repository.waitUntilCallCount(1)
        let supersededTask = try #require(model.taskSnapshotForTesting())
        model.reload()
        await model.waitForCurrentTask()
        await repository.releaseCall(1)
        await supersededTask.value

        guard case .loaded(let items, _, _) = model.state else {
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
    func resetCancelsInFlightLoadAndRejectsItsLateResult() async throws {
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        continuation: nil
                    )
                )
            ],
            suspendedCalls: [1]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        try await repository.waitUntilCallCount(1)
        let supersededTask = try #require(model.taskSnapshotForTesting())
        model.reset()
        await repository.releaseCall(1)
        await supersededTask.value

        #expect(model.state == .idle)
    }

    @Test
    @MainActor
    func deactivatingRouteDuringInitialLoadReturnsToIdle() async throws {
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        continuation: nil
                    )
                )
            ],
            suspendedCalls: [1]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        try await repository.waitUntilCallCount(1)
        let supersededTask = try #require(model.taskSnapshotForTesting())
        model.deactivateRoute()
        await repository.releaseCall(1)
        await supersededTask.value

        #expect(model.state == .idle)
    }

    @Test
    @MainActor
    func deactivatingRouteDuringPaginationRestoresLoadedItems() async throws {
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
                        items: [item("BV1HistoryB2")],
                        continuation: nil
                    )
                ),
            ],
            suspendedCalls: [2]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.loadMore()
        try await repository.waitUntilCallCount(2)
        let supersededTask = try #require(model.taskSnapshotForTesting())
        model.deactivateRoute()
        await repository.releaseCall(2)
        await supersededTask.value

        #expect(
            model.state
                == .loaded(
                    items: [item("BV1HistoryA1")],
                    continuation: continuation,
                    loadMoreError: nil
                )
        )
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
    private let suspendedCalls: Set<Int>
    private var callCount = 0
    private var continuations: [WatchHistoryContinuation?] = []
    private let callEvents = TestEventCounter()
    private var releaseWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releasedCalls: Set<Int> = []

    init(
        results: [Result<WatchHistoryPage, WatchHistoryError>],
        suspendedCalls: Set<Int> = []
    ) {
        self.results = results
        self.suspendedCalls = suspendedCalls
    }

    func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage {
        callCount += 1
        let currentCall = callCount
        continuations.append(continuation)
        await callEvents.signal()
        guard !results.isEmpty else { throw WatchHistoryError.invalidResponse }
        let result = results.removeFirst()
        if suspendedCalls.contains(currentCall), !releasedCalls.contains(currentCall) {
            await withCheckedContinuation {
                releaseWaiters[currentCall, default: []].append($0)
            }
        }
        return try result.get()
    }

    func observedContinuations() -> [WatchHistoryContinuation?] {
        continuations
    }

    func waitUntilCallCount(_ expectedCount: Int) async throws {
        do {
            try await callEvents.wait(until: expectedCount)
        } catch {
            releaseAllCalls()
            throw error
        }
    }

    func releaseCall(_ call: Int) {
        releasedCalls.insert(call)
        let pending = releaseWaiters.removeValue(forKey: call) ?? []
        for waiter in pending {
            waiter.resume()
        }
    }

    private func releaseAllCalls() {
        releasedCalls.formUnion(suspendedCalls)
        let pending = releaseWaiters.values.flatMap { $0 }
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor TestEventCounter {
    private struct Waiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var count = 0
    private var waiters: [UUID: Waiter] = [:]

    func signal() {
        count += 1
        let ready = waiters.filter { count >= $0.value.expectedCount }
        for (id, waiter) in ready where waiters.removeValue(forKey: id) != nil {
            waiter.continuation.resume()
        }
    }

    func wait(until expectedCount: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if count >= expectedCount {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = Waiter(
                        expectedCount: expectedCount,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}
