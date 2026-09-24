import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuSessionTests {
    @Test
    func sessionPrefetchesCurrentAndNextWithBoundedConcurrency() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1DanmakuFixture", cid: 1)
        let repository = StubDanmakuRepository(.holdUntilReleased)
        let timeline = SessionTimeline()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline
        )

        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: 0, generation: 1))
        try await repository.waitForRequestCount(2, identity: identity)

        #expect(await repository.requestedIndices(for: identity).sorted() == [1, 2])
        #expect(await repository.maximumActiveRequests() == 2)
        await repository.release(identity)
        await waitForLoads(session)
        #expect(session.state == .ready(identity))
    }

    @Test
    func replacingIdentityRejectsLateOldSegmentsAndStopReturnsIdle() async throws {
        let first = PlaybackItemIdentity(bvid: "BV1FirstFixture", cid: 1)
        let second = PlaybackItemIdentity(bvid: "BV1SecondFixture", cid: 2)
        let repository = StubDanmakuRepository(.holdUntilReleased)
        let timeline = SessionTimeline()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline
        )

        session.start(for: first)
        timeline.publish(snapshot(identity: first, position: 0, generation: 1))
        try await repository.waitForRequestCount(2, identity: first)
        let supersededTasks = session.loadTaskSnapshotForTesting()
        guard supersededTasks.count == 2 else {
            await repository.releaseAll()
            Issue.record("首个 identity 未捕获到两项预取 Task")
            return
        }
        session.start(for: second)
        timeline.publish(snapshot(identity: second, position: 0, generation: 2))
        try await repository.waitForRequestCount(2, identity: second)
        await repository.release(second)
        await waitForLoads(session)

        #expect(session.state == .ready(second))
        await repository.release(first)
        for task in supersededTasks {
            await task.value
        }
        #expect(session.state == .ready(second))
        session.stop()
        #expect(session.state == .idle)
    }

    @Test
    func presentationSinkReceivesEveryAcceptedTimelineUpdate() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1PresentationFixture", cid: 3)
        let repository = StubDanmakuRepository()
        let timeline = SessionTimeline()
        let sink = SessionPresentationSink()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline,
            presentationSink: sink
        )

        session.start(for: identity)
        timeline.publish(
            snapshot(
                identity: identity,
                position: 1,
                generation: 7,
                rate: 0,
                state: .paused
            )
        )
        try await sink.waitForUpdateCount(1, identity: identity)
        timeline.publish(
            snapshot(
                identity: identity,
                position: 1,
                generation: 7,
                rate: 2,
                state: .playing
            )
        )
        try await sink.waitForUpdateCount(2, identity: identity)

        let accepted = sink.updates.filter {
            $0.snapshot.identity == identity
        }
        try #require(accepted.count == 2)
        #expect(accepted[0].snapshot.state == .paused)
        #expect(accepted[0].batch?.clearsExisting == true)
        #expect(accepted[1].snapshot.rate == 2)
        #expect(accepted[1].batch == nil)
    }

    @Test
    func controlsClearOrStopPresentationSynchronously() throws {
        let sink = SessionPresentationSink()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: StubDanmakuRepository()),
            timeline: SessionTimeline(),
            presentationSink: sink
        )

        session.setEnabled(false)
        #expect(sink.clearCount == 1)

        session.setModeVisibility(scrolling: false, top: true, bottom: true)
        #expect(sink.clearCount == 2)

        session.setSpeedLevel(.five)
        session.setOpacity(try #require(DanmakuOpacity(0.55)))
        session.setDisplayArea(.quarter)
        session.setDensity(.overlapping)
        #expect(sink.clearCount == 2)

        session.stop()
        #expect(sink.stopCount == 1)
    }

    @Test
    func failedSegmentsAreNotRetriedByEveryLaterTimelineUpdate() async throws {
        let identity = PlaybackItemIdentity(
            bvid: "BV1FailingDanmakuFixture",
            cid: 4
        )
        let repository = StubDanmakuRepository(.fail(.unavailable))
        let timeline = SessionTimeline()
        let sink = SessionPresentationSink()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline,
            presentationSink: sink
        )
        let updateCount = 128

        session.start(for: identity)
        timeline.publish(
            snapshot(
                identity: identity,
                position: 0,
                generation: 1
            )
        )
        try await repository.waitForRequestCount(2, identity: identity)
        await waitForLoads(session)

        for ordinal in 2...updateCount {
            timeline.publish(
                snapshot(
                    identity: identity,
                    position: 0,
                    generation: 1
                )
            )
            try await sink.waitForUpdateCount(
                ordinal,
                identity: identity
            )
        }

        let attempts = await repository.requestCount(for: identity)
        #expect(attempts == 2)
        #expect(session.state == .failed(identity, .unavailable))
    }

    @Test
    func authenticationInvalidationIsReportedOncePerSession() async throws {
        let identity = PlaybackItemIdentity(
            bvid: "BV1AuthDanmakuFixture",
            cid: 40
        )
        let repository = StubDanmakuRepository(.fail(.authenticationInvalid))
        let timeline = SessionTimeline()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline
        )
        var invalidationCount = 0
        session.setAuthenticationInvalidationHandler {
            invalidationCount += 1
        }

        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: 0, generation: 1))
        try await repository.waitForRequestCount(2, identity: identity)
        await waitForLoads(session)

        #expect(invalidationCount == 1)
        #expect(session.state == .failed(identity, .authenticationInvalid))

        session.stop()
        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: 0, generation: 2))
        try await repository.waitForRequestCount(4, identity: identity)
        await waitForLoads(session)

        #expect(invalidationCount == 2)
    }

    @Test
    func failedSegmentMemoryIsClearedForReplacementAndStop() async throws {
        let first = PlaybackItemIdentity(
            bvid: "BV1FirstFailureFixture",
            cid: 5
        )
        let second = PlaybackItemIdentity(
            bvid: "BV1SecondFailureFixture",
            cid: 6
        )
        let repository = StubDanmakuRepository(.fail(.unavailable))
        let timeline = SessionTimeline()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline
        )

        session.start(for: first)
        timeline.publish(snapshot(identity: first, position: 0, generation: 1))
        try await repository.waitForRequestCount(2, identity: first)
        await waitForLoads(session)

        session.start(for: second)
        timeline.publish(snapshot(identity: second, position: 0, generation: 2))
        try await repository.waitForRequestCount(2, identity: second)
        await waitForLoads(session)

        #expect(await repository.requestCount(for: first) == 2)
        #expect(await repository.requestCount(for: second) == 2)
        #expect(session.state == .failed(second, .unavailable))

        session.stop()
        await timeline.waitForSubscriberCount(0)
        timeline.publish(snapshot(identity: second, position: 0, generation: 2))
        #expect(await repository.requestCount(for: second) == 2)
        #expect(session.state == .idle)
    }

    @Test
    func restartingSessionAllowsFailedSegmentsToRecover() async throws {
        let identity = PlaybackItemIdentity(
            bvid: "BV1RecoveringDanmakuFixture",
            cid: 7
        )
        let repository = StubDanmakuRepository(.failFirstAttemptPerSegment)
        let timeline = SessionTimeline()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline
        )

        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: 0, generation: 1))
        try await repository.waitForRequestCount(2, identity: identity)
        await waitForLoads(session)
        #expect(session.state == .failed(identity, .unavailable))

        session.stop()
        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: 0, generation: 2))
        try await repository.waitForRequestCount(4, identity: identity)
        await waitForLoads(session)

        #expect(await repository.requestCount(for: identity) == 4)
        #expect(session.state == .ready(identity))
    }

    private func waitForLoads(_ session: DanmakuSession) async {
        for task in session.loadTaskSnapshotForTesting() {
            await task.value
        }
    }

    private func snapshot(
        identity: PlaybackItemIdentity,
        position: Double,
        generation: UInt64,
        rate: Double = 1,
        state: PlaybackTimelineState = .playing
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 900,
            rate: rate,
            state: state,
            discontinuityGeneration: generation
        )
    }
}

@MainActor
private final class SessionPresentationSink: DanmakuPresentationSink {
    private(set) var updates: [DanmakuPresentationUpdate] = []
    private(set) var clearCount = 0
    private(set) var stopCount = 0
    private var updateWaiters:
        [UUID: (
            identity: PlaybackItemIdentity,
            count: Int,
            continuation: CheckedContinuation<Void, any Error>
        )] = [:]

    func apply(_ update: DanmakuPresentationUpdate) {
        updates.append(update)
        let ready = updateWaiters.filter {
            updateCount(for: $0.value.identity) >= $0.value.count
        }
        for (id, waiter) in ready where updateWaiters.removeValue(forKey: id) != nil {
            waiter.continuation.resume()
        }
    }

    func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {}
    func setOpacity(_ opacity: DanmakuOpacity) {}
    func setDisplayArea(_ displayArea: DanmakuDisplayArea) {}
    func setDensity(_ density: DanmakuDensity) {}

    func clearPresentation() {
        clearCount += 1
    }

    func stopPresentation() {
        stopCount += 1
    }

    func waitForUpdateCount(
        _ expectedCount: Int,
        identity: PlaybackItemIdentity
    ) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if updateCount(for: identity) >= expectedCount {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    updateWaiters[id] = (identity, expectedCount, continuation)
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

    private func updateCount(for identity: PlaybackItemIdentity) -> Int {
        updates.lazy.filter { $0.snapshot.identity == identity }.count
    }
}

@MainActor
private final class SessionTimeline: PlaybackTimelineProviding {
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

/// 本 target 唯一的 `DanmakuSegmentRepository` 替身；按 behavior 立即成功、失败、每段首次失败
/// 或挂起到测试显式释放，并按 identity 记录请求与并发峰值。
private actor StubDanmakuRepository: DanmakuSegmentRepository {
    enum Behavior: Sendable {
        case succeed
        case fail(DanmakuApplicationError)
        case failFirstAttemptPerSegment
        case holdUntilReleased
    }

    private struct Request: Hashable {
        let identity: PlaybackItemIdentity
        let index: Int
    }

    private let behavior: Behavior
    private var requests: [Request] = []
    private var active = 0
    private var maximumActive = 0
    private var releasedIdentities: Set<PlaybackItemIdentity> = []
    private var releasesAll = false
    private var releaseWaiters: [PlaybackItemIdentity: [CheckedContinuation<Void, Never>]] = [:]
    private var requestEvents: [PlaybackItemIdentity: TestEventCounter] = [:]

    init(_ behavior: Behavior = .succeed) {
        self.behavior = behavior
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
        await requestCounter(for: identity).signal()

        switch behavior {
        case .succeed:
            break
        case .fail(let error):
            throw error
        case .failFirstAttemptPerSegment:
            if isFirstAttempt { throw DanmakuApplicationError.unavailable }
        case .holdUntilReleased:
            await withCheckedContinuation { continuation in
                if releasesAll || releasedIdentities.contains(identity) {
                    continuation.resume()
                } else {
                    releaseWaiters[identity, default: []].append(continuation)
                }
            }
        }
        return DanmakuSegment(index: index, events: [])
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
            try await requestCounter(for: identity).wait(until: expectedCount)
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

    private func requestCounter(
        for identity: PlaybackItemIdentity
    ) -> TestEventCounter {
        if let counter = requestEvents[identity] {
            return counter
        }
        let counter = TestEventCounter()
        requestEvents[identity] = counter
        return counter
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
