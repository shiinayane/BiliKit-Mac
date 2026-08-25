import Foundation
import Testing

@testable import BiliApplication

@MainActor
struct WatchProgressSessionTests {
    @Test
    func emitsStartPeriodicPauseResumeAndNaturalEnd() async throws {
        let fixture = try makeFixture()
        fixture.session.start()
        fixture.session.setReportingAccess(signedIn: true)

        fixture.timeline.send(fixture.snapshot(state: .playing))
        let started = await fixture.repository.nextReport()
        #expect(started.event == .started)

        fixture.time.value = 15
        fixture.timeline.send(fixture.snapshot(position: 15, state: .playing))
        await fixture.resolutions.wait(for: 2)
        fixture.ticks.tick()
        let periodic = await fixture.repository.nextReport()
        #expect(periodic.event == .periodic)
        #expect(periodic.positionSeconds == 15)
        #expect(periodic.playedSeconds == 15)

        fixture.time.value = 18
        fixture.timeline.send(fixture.snapshot(position: 18, state: .paused))
        let paused = await fixture.repository.nextReport()
        #expect(paused.event == .paused)
        #expect(paused.positionSeconds == 18)
        #expect(paused.playedSeconds == 18)

        fixture.timeline.send(fixture.snapshot(position: 18, state: .playing))
        let resumed = await fixture.repository.nextReport()
        #expect(resumed.event == .resumed)
        #expect(fixture.ticks.intervals == [15, 15])

        fixture.time.value = 20
        fixture.timeline.send(fixture.snapshot(position: 20, state: .ended))
        let ended = await fixture.repository.nextReport()
        #expect(ended.event == .ended)
        #expect(ended.completed)
        #expect(ended.positionSeconds == 20)
    }

    @Test
    func exitAtEighteenUsesCurrentPositionInsteadOfLastPeriodic() async throws {
        let fixture = try makeFixture()
        fixture.session.start()
        fixture.session.setReportingAccess(signedIn: true)
        fixture.timeline.send(fixture.snapshot(state: .playing))
        _ = await fixture.repository.nextReport()

        fixture.time.value = 15
        fixture.timeline.send(fixture.snapshot(position: 15, state: .playing))
        await fixture.resolutions.wait(for: 2)
        fixture.ticks.tick()
        _ = await fixture.repository.nextReport()

        fixture.time.value = 18
        fixture.timeline.send(fixture.snapshot(position: 18, state: .playing))
        await fixture.resolutions.wait(for: 3)
        fixture.session.stop()

        let ended = await fixture.repository.nextReport()
        #expect(ended.event == .ended)
        #expect(ended.positionSeconds == 18)
        #expect(!ended.completed)
    }

    @Test
    func backwardSeekKeepsMaximumAndBufferingDoesNotAccumulatePlayedTime() async throws {
        let fixture = try makeFixture()
        fixture.session.start()
        fixture.session.setReportingAccess(signedIn: true)
        fixture.timeline.send(fixture.snapshot(state: .playing))
        _ = await fixture.repository.nextReport()

        fixture.time.value = 20
        fixture.timeline.send(fixture.snapshot(position: 20, state: .playing))
        fixture.timeline.send(fixture.snapshot(position: 5, state: .playing, discontinuity: 2))
        fixture.time.value = 21
        fixture.timeline.send(fixture.snapshot(position: 5, state: .buffering, discontinuity: 2))
        await fixture.resolutions.wait(for: 4)
        fixture.time.value = 31
        fixture.ticks.tick()

        let periodic = await fixture.repository.nextReport()
        #expect(periodic.positionSeconds == 5)
        #expect(periodic.maximumPositionSeconds == 20)
        #expect(periodic.playedSeconds == 21)
    }

    @Test
    func unresolvedAndGuestScopesNeverCreateWriteIntent() async throws {
        let fixture = try makeFixture()
        fixture.session.start()
        fixture.timeline.send(fixture.snapshot(state: .playing))
        fixture.ticks.tick()
        fixture.session.stop()
        #expect(await fixture.repository.reportCount == 0)

        fixture.session.setReportingAccess(signedIn: false)
        fixture.timeline.send(fixture.snapshot(state: .playing))
        fixture.ticks.tick()
        #expect(await fixture.repository.reportCount == 0)
    }

    @Test(arguments: [
        WatchProgressError.authenticationInvalid,
        WatchProgressError.requestRestricted,
        WatchProgressError.unavailable,
    ])
    func reportingFailureClosesOnlyHeartbeatSession(
        error: WatchProgressError
    ) async throws {
        let fixture = try makeFixture(error: error)
        fixture.session.start()
        fixture.session.setReportingAccess(signedIn: true)
        fixture.timeline.send(fixture.snapshot(state: .playing))
        _ = await fixture.repository.nextReport()
        await fixture.session.waitForCurrentReportForTesting()

        fixture.time.value = 15
        fixture.ticks.tick()
        fixture.timeline.send(fixture.snapshot(position: 15, state: .playing))
        await fixture.resolutions.wait(for: 2)

        #expect(await fixture.repository.reportCount == 1)
        #expect(fixture.timeline.currentTimelineSnapshot.state == .playing)
    }

    @Test
    func slowStartedStillPreservesFinalExitWhenBoundariesSaturate() async throws {
        let repository = BlockingProgressRepository()
        let fixture = try makeFixture(repository: repository)
        fixture.session.start()
        fixture.session.setReportingAccess(signedIn: true)
        fixture.timeline.send(fixture.snapshot(state: .playing))
        var attempts = repository.startedReports().makeAsyncIterator()
        let started = await attempts.next()
        #expect(started?.event == .started)

        var resolutionTarget = 1
        for index in 1...24 {
            fixture.time.value = Double(index)
            let state: PlaybackTimelineState = index.isMultiple(of: 2) ? .playing : .paused
            fixture.timeline.send(
                fixture.snapshot(position: Double(index), state: state)
            )
            resolutionTarget += 1
        }
        fixture.timeline.send(fixture.snapshot(position: 24, state: .ended))
        resolutionTarget += 1
        await fixture.resolutions.wait(for: resolutionTarget)

        await repository.releaseNext()
        var terminal: WatchProgressReport?
        while terminal == nil {
            let next = await attempts.next()
            if next?.event == .ended {
                terminal = next
            }
            await repository.releaseNext()
        }
        #expect(terminal?.positionSeconds == 24)
    }

    @Test
    func periodicCoalescesBeforeBoundariesAndFinalEndRemainsLast() async throws {
        let repository = BlockingProgressRepository()
        let fixture = try makeFixture(repository: repository)
        fixture.session.start()
        fixture.session.setReportingAccess(signedIn: true)
        fixture.timeline.send(fixture.snapshot(state: .playing))
        var attempts = repository.startedReports().makeAsyncIterator()
        #expect(await attempts.next()?.event == .started)

        for position in [5.0, 10.0, 15.0] {
            fixture.time.value = position
            fixture.timeline.send(
                fixture.snapshot(position: position, state: .playing)
            )
            fixture.session.sendPeriodicHeartbeatForTesting()
        }
        let coalesced = fixture.session.pendingReportsForTesting()
        #expect(coalesced.count == 1)
        #expect(coalesced.first?.event == .periodic)
        #expect(coalesced.first?.positionSeconds == 15)

        fixture.timeline.send(fixture.snapshot(position: 16, state: .paused))
        fixture.timeline.send(fixture.snapshot(position: 16, state: .playing))
        fixture.timeline.send(fixture.snapshot(position: 18, state: .ended))

        let finalPending = fixture.session.pendingReportsForTesting()
        #expect(finalPending.map(\.event) == [.paused, .resumed, .ended])
        #expect(finalPending.count <= 8)
        #expect(finalPending.last?.positionSeconds == 18)
        #expect(finalPending.last?.completed == true)

        await repository.releaseNext()
        for expectedEvent in [
            WatchProgressEvent.paused, .resumed, .ended,
        ] {
            #expect(await attempts.next()?.event == expectedEvent)
            await repository.releaseNext()
        }
        await fixture.session.waitForCurrentReportForTesting()
    }

    @Test
    func suspensionFreezesTimerAndPlayedAccountingWithoutStorm() async throws {
        let fixture = try makeFixture()
        fixture.session.start()
        fixture.session.setReportingAccess(signedIn: true)
        fixture.timeline.send(fixture.snapshot(state: .playing))
        _ = await fixture.repository.nextReport()

        fixture.time.value = 5
        fixture.session.suspend()
        fixture.time.value = 105
        fixture.ticks.tick()
        #expect(await fixture.repository.reportCount == 1)

        fixture.session.resumeAfterSuspension()
        fixture.time.value = 110
        fixture.ticks.tick()
        let periodic = await fixture.repository.nextReport()
        #expect(periodic.playedSeconds == 10)
        #expect(fixture.ticks.intervals == [15, 15])
    }

    @Test
    func productionTimelinePreservesSameTurnBoundariesAndNaturalEnd() async throws {
        let timeline = StoreProgressTimeline()
        let repository = ProgressRecordingRepository()
        let identity = PlaybackItemIdentity(bvid: "BV1STORETIMELINE", cid: 22)
        let loadIntent = PlaybackLoadIntent()
        let target = try #require(
            WatchProgressTarget(aid: 11, identity: identity, loadIntent: loadIntent)
        )
        let session = WatchProgressSession(
            useCase: WatchProgressUseCase(repository: repository),
            timeline: timeline,
            resolveTarget: { candidateIdentity, candidateIntent in
                candidateIdentity == identity && candidateIntent == loadIntent
                    ? target : nil
            },
            timestampProvider: { 1_777_777_700 },
            monotonicTimeProvider: { 0 },
            sessionIDProvider: { "0123456789abcdef0123456789abcdef" },
            periodicTicks: { _ in AsyncStream { _ in } }
        )
        session.start()
        session.setReportingAccess(signedIn: true)

        let token = timeline.store.beginItem(identity: identity, loadIntent: loadIntent)
        timeline.store.markReady(token: token, durationSeconds: 120)
        timeline.store.update(token: token, rate: 1, state: .playing)
        timeline.store.update(token: token, positionSeconds: 8, rate: 0, state: .paused)
        timeline.store.update(token: token, positionSeconds: 8, rate: 1, state: .playing)
        timeline.store.update(token: token, positionSeconds: 20, rate: 0, state: .ended)
        timeline.store.clear(token: token)

        let started = await repository.nextReport()
        let paused = await repository.nextReport()
        let resumed = await repository.nextReport()
        let ended = await repository.nextReport()
        let reports = [started, paused, resumed, ended]
        #expect(reports.map(\.event) == [.started, .paused, .resumed, .ended])
        #expect(reports.last?.completed == true)
        #expect(reports.last?.positionSeconds == 20)
        #expect(timeline.store.observerCount == 1)

        session.stop()
        #expect(timeline.store.observerCount == 0)
    }

    @Test(arguments: [
        WatchProgressError.authenticationInvalid,
        WatchProgressError.unavailable,
    ])
    func lateFailureCannotDisableOrReplayAcrossAThroughB(
        firstError: WatchProgressError
    ) async throws {
        let timeline = ProgressTimeline()
        let repository = DelayedFirstProgressRepository(firstError: firstError)
        let resolutions = ResolutionProbe()
        let identityA = PlaybackItemIdentity(bvid: "BV1FIXTUREA", cid: 22)
        let identityB = PlaybackItemIdentity(bvid: "BV1FIXTUREB", cid: 44)
        let intentA1 = PlaybackLoadIntent()
        let intentB = PlaybackLoadIntent()
        let intentA2 = PlaybackLoadIntent()
        let session = WatchProgressSession(
            useCase: WatchProgressUseCase(repository: repository),
            timeline: timeline,
            resolveTarget: { identity, intent in
                resolutions.observe()
                let aid: Int64? =
                    if identity == identityA,
                        intent == intentA1 || intent == intentA2
                    { 11 } else if identity == identityB, intent == intentB {
                        33
                    } else {
                        nil
                    }
                return aid.flatMap {
                    WatchProgressTarget(aid: $0, identity: identity, loadIntent: intent)
                }
            },
            timestampProvider: { 1_777_777_700 },
            monotonicTimeProvider: { 0 },
            sessionIDProvider: { "0123456789abcdef0123456789abcdef" },
            periodicTicks: { _ in AsyncStream { _ in } }
        )
        session.start()
        session.setReportingAccess(signedIn: true)
        timeline.send(snapshot(identity: identityA, intent: intentA1, state: .playing))
        var attempts = repository.attempts().makeAsyncIterator()
        #expect(await attempts.next()?.target.loadIntent == intentA1)

        timeline.send(snapshot(identity: identityB, intent: intentB, state: .playing))
        timeline.send(snapshot(identity: identityA, intent: intentA2, state: .playing))
        await resolutions.wait(for: 3)
        await repository.releaseFirst()

        var replacementStarted = false
        while !replacementStarted {
            let report = await attempts.next()
            replacementStarted =
                report?.event == .started
                && report?.target.loadIntent == intentA2
        }
        #expect(replacementStarted)
        #expect(timeline.currentTimelineSnapshot.state == .playing)
    }

    private func snapshot(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        state: PlaybackTimelineState
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: 0,
            durationSeconds: 120,
            rate: state == .playing ? 1 : 0,
            state: state,
            discontinuityGeneration: 1,
            loadIntent: intent
        )
    }

    private func makeFixture(
        error: WatchProgressError? = nil,
        repository suppliedRepository: (any WatchProgressRepository)? = nil
    ) throws -> ProgressFixture {
        let timeline = ProgressTimeline()
        let recording = ProgressRecordingRepository(error: error)
        let repository = suppliedRepository ?? recording
        let ticks = ManualProgressTicks()
        let time = TestMonotonicTime()
        let identity = PlaybackItemIdentity(bvid: "BV1FIXTURE", cid: 22)
        let loadIntent = PlaybackLoadIntent()
        let resolutions = ResolutionProbe()
        let target = try #require(
            WatchProgressTarget(
                aid: 11,
                identity: identity,
                loadIntent: loadIntent
            )
        )
        let session = WatchProgressSession(
            useCase: WatchProgressUseCase(repository: repository),
            timeline: timeline,
            resolveTarget: { candidateIdentity, candidateIntent in
                resolutions.observe()
                return candidateIdentity == identity && candidateIntent == loadIntent
                    ? target : nil
            },
            timestampProvider: { 1_777_777_700 },
            monotonicTimeProvider: { time.value },
            sessionIDProvider: { "0123456789abcdef0123456789abcdef" },
            periodicTicks: { ticks.stream(every: $0) }
        )
        return ProgressFixture(
            timeline: timeline,
            repository: recording,
            ticks: ticks,
            time: time,
            identity: identity,
            loadIntent: loadIntent,
            resolutions: resolutions,
            session: session
        )
    }
}

@MainActor
private struct ProgressFixture {
    let timeline: ProgressTimeline
    let repository: ProgressRecordingRepository
    let ticks: ManualProgressTicks
    let time: TestMonotonicTime
    let identity: PlaybackItemIdentity
    let loadIntent: PlaybackLoadIntent
    let resolutions: ResolutionProbe
    let session: WatchProgressSession

    func snapshot(
        position: Double = 0,
        state: PlaybackTimelineState,
        discontinuity: UInt64 = 1
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 120,
            rate: state == .playing ? 1 : 0,
            state: state,
            discontinuityGeneration: discontinuity,
            loadIntent: loadIntent
        )
    }
}

@MainActor
private final class TestMonotonicTime { var value = 0.0 }

@MainActor
private final class ResolutionProbe {
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

    func wait(for target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }
}

@MainActor
private final class ManualProgressTicks {
    private var continuations: [AsyncStream<Void>.Continuation] = []
    private(set) var intervals: [Double] = []

    func stream(every interval: Double) -> AsyncStream<Void> {
        intervals.append(interval)
        let stream = AsyncStream<Void>.makeStream()
        continuations.append(stream.continuation)
        return stream.stream
    }

    func tick() {
        for continuation in continuations {
            continuation.yield(())
        }
    }
}

@MainActor
private final class ProgressTimeline: PlaybackTimelineProviding {
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

@MainActor
private final class StoreProgressTimeline: PlaybackTimelineProviding {
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

private actor ProgressRecordingRepository: WatchProgressRepository {
    private let error: WatchProgressError?
    private var reports: [WatchProgressReport] = []
    private var queued: [WatchProgressReport] = []
    private var waiters: [CheckedContinuation<WatchProgressReport, Never>] = []

    init(error: WatchProgressError? = nil) { self.error = error }
    var reportCount: Int { reports.count }

    func report(_ progress: WatchProgressReport) async throws {
        reports.append(progress)
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: progress)
        } else {
            queued.append(progress)
        }
        if let error { throw error }
    }

    func nextReport() async -> WatchProgressReport {
        if !queued.isEmpty { return queued.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private actor BlockingProgressRepository: WatchProgressRepository {
    private let stream: AsyncStream<WatchProgressReport>
    private let continuation: AsyncStream<WatchProgressReport>.Continuation
    private var releases: [CheckedContinuation<Void, Never>] = []

    init() {
        let pair = AsyncStream<WatchProgressReport>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    nonisolated func startedReports() -> AsyncStream<WatchProgressReport> { stream }

    func report(_ progress: WatchProgressReport) async {
        continuation.yield(progress)
        await withCheckedContinuation { releases.append($0) }
    }

    func releaseNext() {
        guard !releases.isEmpty else { return }
        releases.removeFirst().resume()
    }
}

private actor DelayedFirstProgressRepository: WatchProgressRepository {
    private let firstError: WatchProgressError
    private let stream: AsyncStream<WatchProgressReport>
    private let continuation: AsyncStream<WatchProgressReport>.Continuation
    private var firstRelease: CheckedContinuation<Void, Never>?
    private var isFirst = true

    init(firstError: WatchProgressError) {
        self.firstError = firstError
        let pair = AsyncStream<WatchProgressReport>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    nonisolated func attempts() -> AsyncStream<WatchProgressReport> { stream }

    func report(_ progress: WatchProgressReport) async throws {
        continuation.yield(progress)
        guard isFirst else { return }
        isFirst = false
        await withCheckedContinuation { firstRelease = $0 }
        throw firstError
    }

    func releaseFirst() {
        firstRelease?.resume()
        firstRelease = nil
    }
}
