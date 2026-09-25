import Foundation

@testable import BiliApplication

/// WatchProgress 测试共用的时间线、解析探针、手动 tick 与写入 repository 替身。

@MainActor
final class ProgressTimeline: PlaybackTimelineProviding {
    private(set) var currentTimelineSnapshot = PlaybackTimelineSnapshot.idle
    private var continuations: [UUID: AsyncStream<PlaybackTimelineSnapshot>.Continuation] = [:]
    private var observers: [UUID: @MainActor (PlaybackTimelineSnapshot) -> Void] = [:]

    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        let id = UUID()
        let stream = AsyncStream<PlaybackTimelineSnapshot>.makeStream()
        continuations[id] = stream.continuation
        stream.continuation.yield(currentTimelineSnapshot)
        stream.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        return stream.stream
    }

    func observeTimeline(
        _ observer: @escaping @MainActor (PlaybackTimelineSnapshot) -> Void
    ) -> @MainActor @Sendable () -> Void {
        let id = UUID()
        observers[id] = observer
        observer(currentTimelineSnapshot)
        return { [weak self] in self?.observers[id] = nil }
    }

    func send(_ snapshot: PlaybackTimelineSnapshot) {
        currentTimelineSnapshot = snapshot
        for observer in Array(observers.values) {
            observer(snapshot)
        }
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
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
    private var continuations: [AsyncStream<Void>.Continuation] = []
    private var demandWaiters = CountWaiters()
    private var terminationWaiters = CountWaiters()
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

    private func recordDemand() {
        demandCount += 1
        demandWaiters.resume(reaching: demandCount)
    }

    private func recordTermination() {
        terminationCount += 1
        terminationWaiters.resume(reaching: terminationCount)
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
