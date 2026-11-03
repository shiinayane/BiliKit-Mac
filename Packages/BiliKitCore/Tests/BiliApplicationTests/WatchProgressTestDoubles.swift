import Foundation

@testable import BiliApplication

/// WatchProgress 测试共用的时间线、会话环境、解析探针、手动 tick 与写入 repository 替身。

/// 本 target 唯一的 `PlaybackTimelineProviding` 替身：包装生产 `PlaybackTimelineStore`，
/// 快照只能经 store 的 item token 操作发布，广播、去重与 generation 语义与 App 一致。
@MainActor
final class StoreProgressTimeline: PlaybackTimelineProviding {
    let store = PlaybackTimelineStore()

    var currentTimelineSnapshot: PlaybackTimelineSnapshot {
        store.currentSnapshot
    }

    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        store.updates()
    }

    func observeTimeline(
        _ observer: @escaping @MainActor (PlaybackTimelineSnapshot) -> Void
    ) -> @MainActor @Sendable () -> Void {
        store.observe(observer)
    }
}

extension WatchProgressSession.Environment {
    /// 固定的会话起始时间戳与会话 ID；单调时间与周期 tick 由测试控制，默认时间冻结且从不 tick。
    static func fixture(
        monotonicTime: @escaping @MainActor @Sendable () -> Double = { 0 },
        periodicTicks: @escaping @MainActor @Sendable (Double) -> AsyncStream<Void> = { _ in
            AsyncStream { _ in }
        }
    ) -> Self {
        Self(
            timestamp: { 1_777_777_700 },
            monotonicTime: monotonicTime,
            sessionID: { "0123456789abcdef0123456789abcdef" },
            periodicTicks: periodicTicks
        )
    }
}

/// 在 target resolver 内同步计数，证明某个时间线快照已被 session 消费。
@MainActor
final class ResolutionProbe {
    private(set) var count = 0
    private var waiters = CountWaiters()

    func observe() {
        count += 1
        waiters.resume(reaching: count)
    }

    func wait(for target: Int) async {
        await withCheckedContinuation { waiters.add($0, until: target, current: count) }
    }
}

/// 手动 periodic tick：记录消费者每次回到 `for await` 的请求与计时器停止，
/// 让测试以事件而不是等待时长确认上一 tick 已同步处理完。
@MainActor
final class ManualProgressTicks {
    private typealias SettleWaiter = (
        demand: Int, termination: Int, continuation: CheckedContinuation<Void, Never>
    )

    private var continuations: [AsyncStream<Void>.Continuation] = []
    private var demandWaiters = CountWaiters()
    private var terminationWaiters = CountWaiters()
    private var settleWaiters: [SettleWaiter] = []
    private(set) var intervals: [Double] = []
    private var demandCount = 0
    private var terminationCount = 0

    func stream(every interval: Double) -> AsyncStream<Void> {
        intervals.append(interval)
        let pair = AsyncStream<Void>.makeStream()
        continuations.append(pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.recordTermination() }
        }
        let source = TickSource(pair.stream.makeAsyncIterator())
        return AsyncStream { [weak self] in
            await self?.recordDemand()
            return await source.next()
        }
    }

    func tick() {
        for continuation in continuations {
            continuation.yield(())
        }
    }

    /// 第 1 次请求来自计时器启动；之后每处理完一个 tick 再加 1。
    func waitForDemand(_ expected: Int) async {
        await withCheckedContinuation {
            demandWaiters.add($0, until: expected, current: demandCount)
        }
    }

    func waitForTermination(_ expected: Int) async {
        await withCheckedContinuation {
            terminationWaiters.add($0, until: expected, current: terminationCount)
        }
    }

    /// 刚发出的 tick 落定为止：请求数到达 `demand`（消费者处理完它并回到 `for await`），或停止数到达
    /// `termination`（计时器已停止，它不会再被处理），以先到者为准。
    ///
    /// 计时器本该停止却没有停时，单独等停止会永远挂起（continuation 不响应取消，`timeLimit` 也结束不了），
    /// 所以两种结局都要能放行。
    func waitUntilTickSettles(demand: Int, termination: Int) async {
        guard demandCount < demand, terminationCount < termination else { return }
        await withCheckedContinuation { settleWaiters.append((demand, termination, $0)) }
    }

    private func recordDemand() {
        demandCount += 1
        demandWaiters.resume(reaching: demandCount)
        resumeSettledWaiters()
    }

    private func recordTermination() {
        terminationCount += 1
        terminationWaiters.resume(reaching: terminationCount)
        resumeSettledWaiters()
    }

    private func resumeSettledWaiters() {
        let isSettled = { [demandCount, terminationCount] (waiter: SettleWaiter) in
            demandCount >= waiter.demand || terminationCount >= waiter.termination
        }
        let ready = settleWaiters.filter(isSettled)
        settleWaiters.removeAll(where: isSettled)
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

@MainActor
private final class TickSource {
    private var iterator: AsyncStream<Void>.Iterator

    init(_ iterator: AsyncStream<Void>.Iterator) {
        self.iterator = iterator
    }

    func next() async -> Void? {
        var iterator = iterator
        defer { self.iterator = iterator }
        return await iterator.next(isolation: MainActor.shared)
    }
}

/// 唯一的 WatchProgressRepository 替身：按顺序暴露每次写入，可让首个写入失败，
/// 并可阻塞首个或全部写入直到测试释放，同时统计并发写入峰值。
actor ProgressRepositoryStub: WatchProgressRepository {
    enum Blocking: Sendable {
        case none
        case first
        case all
    }

    private let firstFailure: WatchProgressError?
    private let blocking: Blocking
    private var queued: [WatchProgressReport] = []
    private var reportWaiters: [CheckedContinuation<WatchProgressReport, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []
    private var activeCount = 0
    private(set) var reportCount = 0
    private(set) var maximumActiveCount = 0

    init(firstFailure: WatchProgressError? = nil, blocking: Blocking = .none) {
        self.firstFailure = firstFailure
        self.blocking = blocking
    }

    func report(_ progress: WatchProgressReport) async throws {
        reportCount += 1
        let isFirst = reportCount == 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        if reportWaiters.isEmpty {
            queued.append(progress)
        } else {
            reportWaiters.removeFirst().resume(returning: progress)
        }
        if blocking == .all || (blocking == .first && isFirst) {
            await withCheckedContinuation { releases.append($0) }
        }
        activeCount -= 1
        if isFirst, let firstFailure { throw firstFailure }
        try Task.checkCancellation()
    }

    func nextReport() async -> WatchProgressReport {
        if !queued.isEmpty { return queued.removeFirst() }
        return await withCheckedContinuation { reportWaiters.append($0) }
    }

    func releaseNext() {
        guard !releases.isEmpty else { return }
        releases.removeFirst().resume()
    }
}
