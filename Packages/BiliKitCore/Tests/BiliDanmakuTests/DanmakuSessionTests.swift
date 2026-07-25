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
                self?.continuations.removeValue(forKey: id)
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
}

private struct ImmediateDanmakuRepository: DanmakuSegmentRepository {
    func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment {
        DanmakuSegment(index: index, events: [])
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
