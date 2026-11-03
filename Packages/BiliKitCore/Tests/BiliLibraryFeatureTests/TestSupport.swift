import BiliApplication
import BiliModels
import Foundation

@testable import BiliLibraryFeature

/// 本 target 共用的等待替身；各测试文件不再各自复制。

/// 可等待的事件计数：记录端 `signal()`，等待端挂起到计数达到目标；等待所在 Task 被取消时抛出
/// `CancellationError`。
actor TestEventCounter {
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

/// 资料库字符串目录里 `key` 的译文；卡片格式化测试按简体中文构造展示，默认取简体中文。
func localized(
    _ key: String.LocalizationValue,
    locale: Locale = Locale(identifier: "zh-Hans")
) -> String {
    String(localized: key, bundle: LibraryFeatureStrings.bundle, locale: locale)
}

func token(_ value: Int) -> WatchHistoryContinuation {
    WatchHistoryContinuation(rawValue: "fixture-\(value)")
}

/// UseCase 跳过 3 个空页后把第 4 个空页的 continuation 交给用户显式继续。
func emptyPagesEnding(
    at manual: WatchHistoryContinuation
) -> [Result<WatchHistoryPage, any Error>] {
    [token(901), token(902), token(903), manual].map {
        .success(WatchHistoryPage(items: [], continuation: $0))
    }
}

func item(_ bvid: String) -> WatchHistoryItem {
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

/// 本 target 唯一的观看历史仓库替身：按序返回结果，可让指定调用挂起到测试放行。
actor HistoryRepositoryStub: WatchHistoryRepository {
    private var results: [Result<WatchHistoryPage, any Error>]
    private let suspendedCalls: Set<Int>
    private var callCount = 0
    private var continuations: [WatchHistoryContinuation?] = []
    private let callEvents = TestEventCounter()
    private let cancellationEvents = TestEventCounter()
    private var releaseWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releasedCalls: Set<Int> = []

    init(
        results: [Result<WatchHistoryPage, any Error>],
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
        guard !results.isEmpty else { throw ContentApplicationError.invalidResponse }
        let result = results.removeFirst()
        if suspendedCalls.contains(currentCall), !releasedCalls.contains(currentCall) {
            // 挂起期间忽略取消以模拟迟到结果，但记录取消事件供测试确认旧请求已被取消。
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    releaseWaiters[currentCall, default: []].append($0)
                }
            } onCancel: {
                Task { await self.cancellationEvents.signal() }
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

    func waitUntilCancellationCount(_ expectedCount: Int) async throws {
        do {
            try await cancellationEvents.wait(until: expectedCount)
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

func laterItem(
    _ bvid: String,
    unavailability: LibraryItemUnavailability? = nil
) -> WatchLaterItem {
    WatchLaterItem(
        bvid: bvid,
        title: "手写稍后再看条目",
        coverURL: nil,
        owner: VideoOwner(id: 1, name: "测试作者"),
        durationSeconds: 100,
        progress: .notStarted,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000),
        unavailability: unavailability
    )
}

func laterPage(
    _ bvids: [String],
    page: Int,
    next: Int?,
    total: Int = 0
) -> Result<WatchLaterPage, any Error> {
    .success(
        WatchLaterPage(
            items: bvids.map { laterItem($0) },
            pageNumber: page,
            nextPageNumber: next,
            totalCount: total
        )
    )
}

/// 本 target 唯一的稍后再看仓库替身：按序返回结果并记录请求，可让指定调用挂起到测试放行。
actor WatchLaterRepositoryStub: WatchLaterRepository {
    private var results: [Result<WatchLaterPage, any Error>]
    private let suspendedCalls: Set<Int>
    private var callCount = 0
    private(set) var requests: [WatchLaterRequest] = []
    var requestedPages: [Int] { requests.map(\.page) }
    private let callEvents = TestEventCounter()
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedCalls: Set<Int> = []

    init(results: [Result<WatchLaterPage, any Error>], suspendedCalls: Set<Int> = []) {
        self.results = results
        self.suspendedCalls = suspendedCalls
    }

    func watchLater(request: WatchLaterRequest) async throws -> WatchLaterPage {
        callCount += 1
        let currentCall = callCount
        requests.append(request)
        await callEvents.signal()
        guard !results.isEmpty else { throw ContentApplicationError.invalidResponse }
        let result = results.removeFirst()
        if suspendedCalls.contains(currentCall), !releasedCalls.contains(currentCall) {
            // 挂起期间忽略取消以模拟迟到结果。
            await withCheckedContinuation { releaseWaiters[currentCall] = $0 }
        }
        return try result.get()
    }

    func waitUntilCallCount(_ expectedCount: Int) async throws {
        try await callEvents.wait(until: expectedCount)
    }

    func releaseCall(_ call: Int) {
        releasedCalls.insert(call)
        releaseWaiters.removeValue(forKey: call)?.resume()
    }
}
