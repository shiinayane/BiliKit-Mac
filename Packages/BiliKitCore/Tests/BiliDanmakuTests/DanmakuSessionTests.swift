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
        let repository = ControlledPrefetchRepository()
        let timeline = SessionTimeline()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline
        )

        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: 0, generation: 1))
        try await repository.waitForRequestCount(2, identity: identity)

        #expect(await repository.requestedIndices().sorted() == [1, 2])
        #expect(await repository.maximumActiveRequests() == 2)
        await repository.releaseRequests(for: identity)
        await session.waitForLoads()
        #expect(session.state == .ready(identity))
    }

    @Test
    func replacingIdentityRejectsLateOldSegmentsAndStopReturnsIdle() async throws {
        let first = PlaybackItemIdentity(bvid: "BV1FirstFixture", cid: 1)
        let second = PlaybackItemIdentity(bvid: "BV1SecondFixture", cid: 2)
        let repository = ControlledPrefetchRepository()
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
            await repository.releaseAllRequests()
            Issue.record("首个 identity 未捕获到两项预取 Task")
            return
        }
        session.start(for: second)
        timeline.publish(snapshot(identity: second, position: 0, generation: 2))
        try await repository.waitForRequestCount(2, identity: second)
        await repository.releaseRequests(for: second)
        await session.waitForLoads()

        #expect(session.state == .ready(second))
        await repository.releaseRequests(for: first)
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
        let repository = ImmediateDanmakuRepository()
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
    func controlsClearOrStopPresentationSynchronously() {
        let repository = ImmediateDanmakuRepository()
        let timeline = SessionTimeline()
        let sink = SessionPresentationSink()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline,
            presentationSink: sink
        )

        session.setEnabled(false)
        #expect(sink.clearCount == 1)

        session.setFilter(
            DanmakuFilter(showsScrolling: false)
        )
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
        let repository = AlwaysFailingDanmakuRepository()
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
        await session.waitForLoads()

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
    func failedSegmentMemoryIsClearedForReplacementAndStop() async throws {
        let first = PlaybackItemIdentity(
            bvid: "BV1FirstFailureFixture",
            cid: 5
        )
        let second = PlaybackItemIdentity(
            bvid: "BV1SecondFailureFixture",
            cid: 6
        )
        let repository = AlwaysFailingDanmakuRepository()
        let timeline = SessionTimeline()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline
        )

        session.start(for: first)
        timeline.publish(snapshot(identity: first, position: 0, generation: 1))
        try await repository.waitForRequestCount(2, identity: first)
        await session.waitForLoads()

        session.start(for: second)
        timeline.publish(snapshot(identity: second, position: 0, generation: 2))
        try await repository.waitForRequestCount(2, identity: second)
        await session.waitForLoads()

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
        let repository = FailOncePerSegmentDanmakuRepository()
        let timeline = SessionTimeline()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline
        )

        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: 0, generation: 1))
        try await repository.waitForRequestCount(2, identity: identity)
        await session.waitForLoads()
        #expect(session.state == .failed(identity, .unavailable))

        session.stop()
        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: 0, generation: 2))
        try await repository.waitForRequestCount(4, identity: identity)
        await session.waitForLoads()

        #expect(await repository.requestCount(for: identity) == 4)
        #expect(session.state == .ready(identity))
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

    func publish(_ snapshot: PlaybackTimelineSnapshot) {
        self.snapshot = snapshot
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

private struct ImmediateDanmakuRepository: DanmakuSegmentRepository {
    func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment {
        DanmakuSegment(index: index, events: [])
    }
}

private actor AlwaysFailingDanmakuRepository: DanmakuSegmentRepository {
    private var counts: [PlaybackItemIdentity: Int] = [:]
    private var events: [PlaybackItemIdentity: TestEventCounter] = [:]

    func segment(
        index _: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment {
        counts[identity, default: 0] += 1
        await event(for: identity).signal()
        throw DanmakuApplicationError.unavailable
    }

    func requestCount(for identity: PlaybackItemIdentity) -> Int {
        counts[identity, default: 0]
    }

    func waitForRequestCount(
        _ expectedCount: Int,
        identity: PlaybackItemIdentity
    ) async throws {
        try await event(for: identity).wait(until: expectedCount)
    }

    private func event(for identity: PlaybackItemIdentity) -> TestEventCounter {
        if let event = events[identity] {
            return event
        }
        let event = TestEventCounter()
        events[identity] = event
        return event
    }
}

private actor FailOncePerSegmentDanmakuRepository: DanmakuSegmentRepository {
    private struct Request: Hashable {
        let identity: PlaybackItemIdentity
        let index: Int
    }

    private var counts: [PlaybackItemIdentity: Int] = [:]
    private var attempts: [Request: Int] = [:]
    private var events: [PlaybackItemIdentity: TestEventCounter] = [:]

    func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment {
        let request = Request(identity: identity, index: index)
        counts[identity, default: 0] += 1
        attempts[request, default: 0] += 1
        await event(for: identity).signal()
        guard attempts[request] != 1 else {
            throw DanmakuApplicationError.unavailable
        }
        return DanmakuSegment(index: index, events: [])
    }

    func requestCount(for identity: PlaybackItemIdentity) -> Int {
        counts[identity, default: 0]
    }

    func waitForRequestCount(
        _ expectedCount: Int,
        identity: PlaybackItemIdentity
    ) async throws {
        try await event(for: identity).wait(until: expectedCount)
    }

    private func event(for identity: PlaybackItemIdentity) -> TestEventCounter {
        if let event = events[identity] {
            return event
        }
        let event = TestEventCounter()
        events[identity] = event
        return event
    }
}

private actor ControlledPrefetchRepository: DanmakuSegmentRepository {
    private struct Request: Sendable {
        let index: Int
        let identity: PlaybackItemIdentity
    }

    private var requests: [Request] = []
    private var active = 0
    private var maximumActive = 0
    private var allRequestsReleased = false
    private var releasedIdentities: Set<PlaybackItemIdentity> = []
    private var requestEvents: [PlaybackItemIdentity: TestEventCounter] = [:]
    private var releaseWaiters: [PlaybackItemIdentity: [CheckedContinuation<Void, Never>]] = [:]

    func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment {
        requests.append(Request(index: index, identity: identity))
        active += 1
        maximumActive = max(maximumActive, active)
        await requestCounter(for: identity).signal()

        await withCheckedContinuation { continuation in
            if allRequestsReleased || releasedIdentities.contains(identity) {
                continuation.resume()
            } else {
                releaseWaiters[identity, default: []].append(continuation)
            }
        }

        active -= 1
        return DanmakuSegment(index: index, events: [])
    }

    func requestedIndices() -> [Int] { requests.map(\.index) }

    func maximumActiveRequests() -> Int { maximumActive }

    func waitForRequestCount(
        _ expectedCount: Int,
        identity: PlaybackItemIdentity
    ) async throws {
        let counter = requestCounter(for: identity)
        do {
            try await counter.wait(until: expectedCount)
        } catch {
            releaseAllRequests()
            throw error
        }
    }

    func releaseRequests(for identity: PlaybackItemIdentity) {
        releasedIdentities.insert(identity)
        let pending = releaseWaiters.removeValue(forKey: identity) ?? []
        for waiter in pending {
            waiter.resume()
        }
    }

    private func requestCounter(for identity: PlaybackItemIdentity) -> TestEventCounter {
        if let counter = requestEvents[identity] {
            return counter
        }
        let counter = TestEventCounter()
        requestEvents[identity] = counter
        return counter
    }

    func releaseAllRequests() {
        allRequestsReleased = true
        releasedIdentities.formUnion(releaseWaiters.keys)
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
