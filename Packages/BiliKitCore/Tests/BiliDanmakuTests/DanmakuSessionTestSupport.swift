import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 弹幕会话测试的时间线快照：时长固定 30 分钟，足够覆盖需要上一分段的分段开头位置；`generation`
/// 是不连续代号。
func snapshot(
    identity: PlaybackItemIdentity,
    position: Double,
    generation: UInt64,
    rate: Double = 1,
    state: PlaybackTimelineState = .playing
) -> PlaybackTimelineSnapshot {
    PlaybackTimelineSnapshot(
        identity: identity,
        positionSeconds: position,
        durationSeconds: 1_800,
        rate: rate,
        state: state,
        discontinuityGeneration: generation
    )
}

/// 接上本 target 的 repository、时间线与呈现端替身的弹幕会话。
///
/// 会话只弱持有呈现端：要经呈现端判断的测试必须留住返回的 sink，丢掉它就等于没有呈现端。
@MainActor
func makeDanmakuSession(
    repository: StubDanmakuRepository
) -> (DanmakuSession, SessionTimeline, SessionPresentationSink) {
    let timeline = SessionTimeline()
    let sink = SessionPresentationSink()
    let session = DanmakuSession(
        useCase: DanmakuSegmentUseCase(repository: repository),
        commandUseCase: DanmakuCommandUseCase(repository: repository),
        timeline: timeline,
        presentationSink: sink
    )
    return (session, timeline, sink)
}

/// 弹幕会话测试唯一的呈现端替身：记录收到的快照、分段、开关、过滤与停止次数，每收到一个快照或分段
/// 检查一次等待条件；显示时间由测试设定；不渲染任何弹幕。
@MainActor
final class SessionPresentationSink: DanmakuPresentationSink {
    private(set) var snapshots: [PlaybackTimelineSnapshot] = []
    /// 每次收到的整份分段缓存，按到达顺序。
    private(set) var segmentDeliveries:
        [(identity: PlaybackItemIdentity, segments: [Int: [DanmakuEvent]])] =
            []
    private(set) var enabledChanges: [Bool] = []
    private(set) var filters: [DanmakuFilter] = []
    private(set) var stopCount = 0
    private var updateWaiters:
        [UUID: (
            isSatisfied: @MainActor () -> Bool,
            continuation: CheckedContinuation<Void, any Error>
        )] = [:]

    func apply(_ snapshot: PlaybackTimelineSnapshot) {
        snapshots.append(snapshot)
        resumeSatisfiedWaiters()
    }

    /// 呈现端此刻的显示时间，由测试设定；默认读不到。
    var currentDisplayTime: Double?

    func displayTime() -> Double? {
        currentDisplayTime
    }

    func setSegments(
        _ segments: [Int: [DanmakuEvent]],
        for identity: PlaybackItemIdentity
    ) {
        segmentDeliveries.append((identity, segments))
        resumeSatisfiedWaiters()
    }

    /// 每次收到的互动弹幕卡片，按到达顺序。
    private(set) var commandCardDeliveries:
        [(identity: PlaybackItemIdentity, cards: [DanmakuCommandCard])] = []

    func setCommandCards(_ cards: [DanmakuCommandCard], for identity: PlaybackItemIdentity) {
        commandCardDeliveries.append((identity, cards))
        resumeSatisfiedWaiters()
    }

    func setEnabled(_ enabled: Bool) {
        enabledChanges.append(enabled)
    }

    func setFilter(_ filter: DanmakuFilter) {
        filters.append(filter)
    }

    func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {}
    func setOpacity(_ opacity: DanmakuOpacity) {}
    func setDisplayArea(_ displayArea: DanmakuDisplayArea) {}
    func setDensity(_ density: DanmakuDensity) {}

    func stopPresentation() {
        stopCount += 1
    }

    private func resumeSatisfiedWaiters() {
        let ready = updateWaiters.filter { $0.value.isSatisfied() }
        for (id, waiter) in ready where updateWaiters.removeValue(forKey: id) != nil {
            waiter.continuation.resume()
        }
    }

    func waitForUpdateCount(
        _ expectedCount: Int,
        identity: PlaybackItemIdentity
    ) async throws {
        try await waitForUpdates { [unowned self] in
            updateCount(for: identity) >= expectedCount
        }
    }

    /// 等到收到的快照与分段满足 `isSatisfied`；每收到一个检查一次，取消时抛出 `CancellationError`。
    func waitForUpdates(
        where isSatisfied: @escaping @MainActor () -> Bool
    ) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if isSatisfied() {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    updateWaiters[id] = (isSatisfied, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelUpdateWaiter(id)
            }
        }
    }

    private func cancelUpdateWaiter(_ id: UUID) {
        updateWaiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }

    func updateCount(for identity: PlaybackItemIdentity) -> Int {
        snapshots.lazy.filter { $0.identity == identity }.count
    }
}

/// 记录认证失效回调；回调在 MainActor 上同步发生，次数可直接断言，也可等到达某个次数。
@MainActor
final class InvalidationRecorder {
    private(set) var count = 0
    private var waiters: [UUID: (count: Int, continuation: CheckedContinuation<Void, any Error>)] =
        [:]

    func record() {
        count += 1
        let ready = waiters.filter { $0.value.count <= count }
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
                    waiters[id] = (expectedCount, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelWaiter(id)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}

/// 弹幕会话测试唯一的时间线替身：由测试发布快照，同时推给 stream 订阅者与同步 observer；
/// 订阅者结束时移除，可等订阅者数降到指定值以确认会话已退订。
@MainActor
final class SessionTimeline: PlaybackTimelineProviding {
    private var snapshot = PlaybackTimelineSnapshot.idle
    private var continuations: [UUID: AsyncStream<PlaybackTimelineSnapshot>.Continuation] = [:]
    private var observers: [UUID: @MainActor (PlaybackTimelineSnapshot) -> Void] = [:]
    private var subscriberCountWaiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var currentTimelineSnapshot: PlaybackTimelineSnapshot { snapshot }

    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        let id = UUID()
        let stream = AsyncStream<PlaybackTimelineSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[id] = stream.continuation
        stream.continuation.yield(snapshot)
        stream.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.removeContinuation(id)
            }
        }
        return stream.stream
    }

    func observeTimeline(
        _ observer: @escaping @MainActor (PlaybackTimelineSnapshot) -> Void
    ) -> @MainActor @Sendable () -> Void {
        let id = UUID()
        observers[id] = observer
        observer(snapshot)
        return { [weak self] in self?.observers[id] = nil }
    }

    func publish(_ snapshot: PlaybackTimelineSnapshot) {
        self.snapshot = snapshot
        for observer in Array(observers.values) {
            observer(snapshot)
        }
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    func waitForSubscriberCount(_ count: Int) async {
        guard continuations.count != count else { return }
        await withCheckedContinuation { continuation in
            subscriberCountWaiters.append((count, continuation))
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
        let ready = subscriberCountWaiters.filter {
            continuations.count == $0.count
        }
        subscriberCountWaiters.removeAll {
            continuations.count == $0.count
        }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

/// 本 target 唯一的 `DanmakuSegmentRepository` 与 `DanmakuCommandRepository` 替身；分段按 behavior 立即成功、失败、
/// 每段首次失败或挂起到测试显式释放，并按 identity 记录请求与并发峰值。成功的分段带上按分段号配置的弹幕，
/// 未配置的分段为空；互动弹幕立即返回配置的结果（默认没有互动弹幕）。
actor StubDanmakuRepository: DanmakuSegmentRepository, DanmakuCommandRepository {
    enum Behavior: Sendable {
        case succeed
        case fail(DanmakuApplicationError)
        case failFirstAttemptPerSegment(DanmakuApplicationError)
        case holdUntilReleased
    }

    private struct Request: Hashable {
        let identity: PlaybackItemIdentity
        let index: Int
    }

    private let behavior: Behavior
    private let eventsBySegment: [Int: [DanmakuEvent]]
    private let commandsResult: Result<DanmakuCommands, DanmakuApplicationError>
    private var requests: [Request] = []
    private var active = 0
    private var maximumActive = 0
    private var releasedIdentities: Set<PlaybackItemIdentity> = []
    private var releasesAll = false
    private var releaseWaiters: [PlaybackItemIdentity: [CheckedContinuation<Void, Never>]] = [:]
    private var requestEvents: [PlaybackItemIdentity: TestEventCounter] = [:]
    private var cancellationEvents: [PlaybackItemIdentity: TestEventCounter] = [:]

    init(
        _ behavior: Behavior = .succeed,
        eventsBySegment: [Int: [DanmakuEvent]] = [:],
        commands: Result<DanmakuCommands, DanmakuApplicationError> = .success(.empty)
    ) {
        self.behavior = behavior
        self.eventsBySegment = eventsBySegment
        commandsResult = commands
    }

    func commands(for identity: PlaybackItemIdentity) async throws -> DanmakuCommands {
        try commandsResult.get()
    }

    func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment {
        let request = Request(identity: identity, index: index)
        let isFirstAttempt = !requests.contains(request)
        requests.append(request)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        await counter(for: identity, in: &requestEvents).signal()

        switch behavior {
        case .succeed:
            break
        case .fail(let error):
            throw error
        case .failFirstAttemptPerSegment(let error):
            if isFirstAttempt { throw error }
        case .holdUntilReleased:
            // 挂起期间忽略取消以模拟迟到结果，但记录取消事件供测试确认旧会话已取消加载。
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if releasesAll || releasedIdentities.contains(identity) {
                        continuation.resume()
                    } else {
                        releaseWaiters[identity, default: []].append(continuation)
                    }
                }
            } onCancel: {
                Task { await self.recordCancellation(identity) }
            }
        }
        return DanmakuSegment(index: index, events: eventsBySegment[index] ?? [])
    }

    func requestedIndices(for identity: PlaybackItemIdentity) -> [Int] {
        requests.filter { $0.identity == identity }.map(\.index)
    }

    func requestCount(for identity: PlaybackItemIdentity) -> Int {
        requests.lazy.filter { $0.identity == identity }.count
    }

    func maximumActiveRequests() -> Int { maximumActive }

    func waitForRequestCount(
        _ expectedCount: Int,
        identity: PlaybackItemIdentity
    ) async throws {
        do {
            try await counter(for: identity, in: &requestEvents).wait(until: expectedCount)
        } catch {
            releaseAll()
            throw error
        }
    }

    func waitForCancellationCount(
        _ expectedCount: Int,
        identity: PlaybackItemIdentity
    ) async throws {
        do {
            try await counter(for: identity, in: &cancellationEvents).wait(until: expectedCount)
        } catch {
            releaseAll()
            throw error
        }
    }

    func release(_ identity: PlaybackItemIdentity) {
        releasedIdentities.insert(identity)
        for waiter in releaseWaiters.removeValue(forKey: identity) ?? [] {
            waiter.resume()
        }
    }

    func releaseAll() {
        releasesAll = true
        let pending = releaseWaiters.values.flatMap { $0 }
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }

    private func recordCancellation(_ identity: PlaybackItemIdentity) async {
        await counter(for: identity, in: &cancellationEvents).signal()
    }

    private func counter(
        for identity: PlaybackItemIdentity,
        in events: inout [PlaybackItemIdentity: TestEventCounter]
    ) -> TestEventCounter {
        if let counter = events[identity] {
            return counter
        }
        let counter = TestEventCounter()
        events[identity] = counter
        return counter
    }
}

/// 按次计数的事件信号：测试可等计数达到某个值；等待期间取消则抛出 `CancellationError`。
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
