import BiliApplication
import BiliDanmaku
import BiliModels
import Foundation
import Testing

@MainActor
@Suite
struct DanmakuSessionTests {
    @Test
    func sessionPrefetchesCurrentAndNextWithBoundedConcurrency() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1DanmakuFixture", cid: 1)
        let repository = SessionRecordingRepository(delay: .milliseconds(20))
        let timeline = SessionTimeline()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline
        )

        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: 0, generation: 1))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await repository.requestedIndices().count < 2,
              clock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(5))
        }
        await session.waitForLoads()

        #expect(await repository.requestedIndices().sorted() == [1, 2])
        #expect(await repository.maximumActiveRequests() == 2)
        #expect(session.state == .ready(identity))
    }

    @Test
    func replacingIdentityRejectsLateOldSegmentsAndStopReturnsIdle() async throws {
        let first = PlaybackItemIdentity(bvid: "BV1FirstFixture", cid: 1)
        let second = PlaybackItemIdentity(bvid: "BV1SecondFixture", cid: 2)
        let repository = SessionRecordingRepository(
            delay: .milliseconds(40),
            ignoresCancellation: true
        )
        let timeline = SessionTimeline()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline
        )

        session.start(for: first)
        timeline.publish(snapshot(identity: first, position: 0, generation: 1))
        try await Task.sleep(for: .milliseconds(5))
        session.start(for: second)
        timeline.publish(snapshot(identity: second, position: 0, generation: 2))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while session.state != .ready(second),
              clock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(session.state == .ready(second))
        session.stop()
        #expect(session.state == .idle)
    }

    @Test
    func presentationSinkReceivesEveryAcceptedTimelineUpdate() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1PresentationFixture", cid: 3)
        let repository = SessionRecordingRepository(delay: .milliseconds(5))
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
        try await waitUntil {
            sink.updates.contains {
                $0.snapshot.identity == identity
                    && $0.snapshot.state == .paused
            }
        }
        timeline.publish(
            snapshot(
                identity: identity,
                position: 1,
                generation: 7,
                rate: 2,
                state: .playing
            )
        )
        try await waitUntil {
            sink.updates.filter {
                $0.snapshot.identity == identity
            }.count >= 2
        }

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
        let repository = SessionRecordingRepository(delay: .milliseconds(5))
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

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition())
    }
}

@MainActor
private final class SessionPresentationSink: DanmakuPresentationSink {
    private(set) var updates: [DanmakuPresentationUpdate] = []
    private(set) var clearCount = 0
    private(set) var stopCount = 0

    func apply(_ update: DanmakuPresentationUpdate) {
        updates.append(update)
    }

    func clearPresentation() {
        clearCount += 1
    }

    func stopPresentation() {
        stopCount += 1
    }
}

@MainActor
private final class SessionTimeline: PlaybackTimelineProviding {
    private var snapshot = PlaybackTimelineSnapshot.idle
    private var continuations: [
        UUID: AsyncStream<PlaybackTimelineSnapshot>.Continuation
    ] = [:]

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
        continuations.values.forEach { $0.yield(snapshot) }
    }
}

private actor SessionRecordingRepository: DanmakuSegmentRepository {
    private let delay: Duration
    private let ignoresCancellation: Bool
    private var requested: [Int] = []
    private var active = 0
    private var maximumActive = 0

    init(delay: Duration, ignoresCancellation: Bool = false) {
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
    }

    func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment {
        requested.append(index)
        active += 1
        maximumActive = max(maximumActive, active)
        do {
            try await Task.sleep(for: delay)
        } catch where !ignoresCancellation {
            active -= 1
            throw CancellationError()
        } catch {}
        active -= 1
        return DanmakuSegment(index: index, events: [])
    }

    func requestedIndices() -> [Int] { requested }
    func maximumActiveRequests() -> Int { maximumActive }
}
