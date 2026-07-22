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
        try await Task.sleep(for: .milliseconds(80))

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
        try await Task.sleep(for: .milliseconds(100))

        #expect(session.state == .ready(second))
        session.stop()
        #expect(session.state == .idle)
    }

    private func snapshot(
        identity: PlaybackItemIdentity,
        position: Double,
        generation: UInt64
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 900,
            rate: 1,
            state: .playing,
            discontinuityGeneration: generation
        )
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
