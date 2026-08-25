import Foundation
import Testing

@testable import BiliApplication

struct WatchProgressUseCaseTests {
    @Test
    func processWriterNeverOverlapsMultipleWindows() async throws {
        let base = ProcessBlockingRepository()
        let writer = SerializedWatchProgressRepository(base: base)
        let first = try report(aid: 11, cid: 22, sequence: 1)
        let second = try report(aid: 33, cid: 44, sequence: 2)
        var starts = base.starts().makeAsyncIterator()

        let firstTask = Task { try await writer.report(first) }
        #expect(await starts.next() == first)
        let secondTask = Task { try await writer.report(second) }
        #expect(await base.maximumActiveCount == 1)
        await base.releaseNext()
        #expect(await starts.next() == second)
        #expect(await base.maximumActiveCount == 1)
        await base.releaseNext()
        try await firstTask.value
        try await secondTask.value
    }

    @Test
    func authenticationGenerationCancelsQueuedOldSessionWithoutReplay() async throws {
        let base = ProcessBlockingRepository()
        let writer = SerializedWatchProgressRepository(base: base)
        let first = try report(aid: 11, cid: 22, sequence: 1)
        let queued = try report(aid: 33, cid: 44, sequence: 2)
        var starts = base.starts().makeAsyncIterator()
        let firstTask = Task { try await writer.report(first) }
        #expect(await starts.next() == first)
        let queuedTask = Task { try await writer.report(queued) }
        await writer.waitForOperationCountForTesting(2)

        await writer.invalidateAuthenticatedSession()
        await base.releaseNext()
        await #expect(throws: CancellationError.self) { try await firstTask.value }
        await #expect(throws: CancellationError.self) { try await queuedTask.value }
        #expect(await base.startedCount == 1)
    }

    @Test @MainActor
    func simultaneousWindowExitsRemainSerializedAndBothReachWriter() async throws {
        let base = ProcessBlockingRepository()
        let writer = SerializedWatchProgressRepository(base: base)
        let first = try WindowProgressHarness(aid: 11, cid: 22, writer: writer)
        let second = try WindowProgressHarness(aid: 33, cid: 44, writer: writer)
        var starts = base.starts().makeAsyncIterator()

        first.start()
        second.start()
        _ = await starts.next()
        first.end()
        second.end()
        await first.waitUntilEndedConsumed()
        await second.waitUntilEndedConsumed()

        var terminalCount = 0
        for _ in 0..<3 {
            await base.releaseNext()
            guard let report = await starts.next() else { break }
            if report.event == .ended { terminalCount += 1 }
        }
        // Final release completes the last terminal request and has no successor event.
        await base.releaseNext()
        #expect(terminalCount == 2)
        #expect(await base.maximumActiveCount == 1)
    }

    private func report(aid: Int64, cid: Int64, sequence: UInt64) throws -> WatchProgressReport {
        let identity = PlaybackItemIdentity(bvid: "BV1FIXTURE", cid: cid)
        let target = try #require(
            WatchProgressTarget(
                aid: aid,
                identity: identity,
                loadIntent: PlaybackLoadIntent()
            )
        )
        return try #require(
            WatchProgressReport(
                target: target,
                event: .ended,
                sessionStartTimestamp: 1_777_777_700,
                sessionID: "0123456789abcdef0123456789abcdef",
                generation: 1,
                sequence: sequence,
                positionSeconds: 18,
                maximumPositionSeconds: 18,
                durationSeconds: 120,
                elapsedSeconds: 18,
                playedSeconds: 18,
                completed: false
            )
        )
    }
}

@MainActor
private final class WindowProgressHarness {
    private let timeline = WindowProgressTimeline()
    private let probe = WindowResolutionProbe()
    private let identity: PlaybackItemIdentity
    private let intent = PlaybackLoadIntent()
    private let session: WatchProgressSession

    init(
        aid: Int64,
        cid: Int64,
        writer: any WatchProgressRepository
    ) throws {
        identity = PlaybackItemIdentity(bvid: "BV1FIXTURE", cid: cid)
        let identity = identity
        let intent = intent
        let target = try #require(
            WatchProgressTarget(
                aid: aid,
                identity: identity,
                loadIntent: intent
            )
        )
        let probe = probe
        session = WatchProgressSession(
            useCase: WatchProgressUseCase(repository: writer),
            timeline: timeline,
            resolveTarget: { candidate, candidateIntent in
                probe.observe()
                return candidate == identity && candidateIntent == intent
                    ? target : nil
            },
            timestampProvider: { 1_777_777_700 },
            monotonicTimeProvider: { 0 },
            sessionIDProvider: { "0123456789abcdef0123456789abcdef" },
            periodicTicks: { _ in AsyncStream { _ in } }
        )
    }

    func start() {
        session.start()
        session.setReportingAccess(signedIn: true)
        timeline.send(snapshot(state: .playing))
    }

    func end() { timeline.send(snapshot(state: .ended)) }
    func waitUntilEndedConsumed() async { await probe.wait(for: 2) }

    private func snapshot(state: PlaybackTimelineState) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: 18,
            durationSeconds: 120,
            rate: state == .playing ? 1 : 0,
            state: state,
            discontinuityGeneration: 1,
            loadIntent: intent
        )
    }
}

@MainActor
private final class WindowProgressTimeline: PlaybackTimelineProviding {
    private(set) var currentTimelineSnapshot = PlaybackTimelineSnapshot.idle
    private var continuation: AsyncStream<PlaybackTimelineSnapshot>.Continuation?
    private var observers: [UUID: @MainActor (PlaybackTimelineSnapshot) -> Void] = [:]

    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        let pair = AsyncStream<PlaybackTimelineSnapshot>.makeStream()
        continuation = pair.continuation
        pair.continuation.yield(currentTimelineSnapshot)
        return pair.stream
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
        continuation?.yield(snapshot)
    }
}

@MainActor
private final class WindowResolutionProbe {
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func observe() {
        count += 1
        let ready = waiters.filter { count >= $0.0 }
        waiters.removeAll { count >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }

    func wait(for expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { waiters.append((expected, $0)) }
    }
}

private actor ProcessBlockingRepository: WatchProgressRepository {
    private let stream: AsyncStream<WatchProgressReport>
    private let continuation: AsyncStream<WatchProgressReport>.Continuation
    private var releases: [CheckedContinuation<Void, Never>] = []
    private var activeCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var startedCount = 0

    init() {
        let pair = AsyncStream<WatchProgressReport>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    nonisolated func starts() -> AsyncStream<WatchProgressReport> { stream }

    func report(_ progress: WatchProgressReport) async throws {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startedCount += 1
        continuation.yield(progress)
        await withTaskCancellationHandler {
            await withCheckedContinuation { releases.append($0) }
        } onCancel: {
        }
        activeCount -= 1
        try Task.checkCancellation()
    }

    func releaseNext() {
        guard !releases.isEmpty else { return }
        releases.removeFirst().resume()
    }
}
