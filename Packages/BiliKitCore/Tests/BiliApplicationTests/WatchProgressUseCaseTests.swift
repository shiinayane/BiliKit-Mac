import Foundation
import Testing

@testable import BiliApplication

@Suite(.timeLimit(.minutes(1)))
struct WatchProgressUseCaseTests {
    @Test
    func authenticationGenerationCancelsQueuedOldSessionWithoutReplay() async throws {
        let base = ProgressRepositoryStub(blocking: .all)
        let writer = SerializedWatchProgressRepository(base: base)
        let first = try report(aid: 11, cid: 22, sequence: 1)
        let queued = try report(aid: 33, cid: 44, sequence: 2)
        let firstTask = await writer.enqueue(first)
        #expect(await base.nextReport() == first)
        let queuedTask = await writer.enqueue(queued)

        await writer.invalidateAuthenticatedSession()
        await base.releaseNext()
        await #expect(throws: CancellationError.self) { try await firstTask.value }
        await #expect(throws: CancellationError.self) { try await queuedTask.value }
        #expect(await base.reportCount == 1)
    }

    @Test @MainActor
    func simultaneousWindowExitsRemainSerializedAndBothReachWriter() async throws {
        let base = ProgressRepositoryStub(blocking: .all)
        let writer = SerializedWatchProgressRepository(base: base)
        let first = try WindowProgressHarness(aid: 11, cid: 22, writer: writer)
        let second = try WindowProgressHarness(aid: 33, cid: 44, writer: writer)

        first.start()
        second.start()
        _ = await base.nextReport()
        first.end()
        second.end()
        await first.waitUntilEndedConsumed()
        await second.waitUntilEndedConsumed()

        var terminalCount = 0
        for _ in 0..<3 {
            await base.releaseNext()
            if await base.nextReport().event == .ended { terminalCount += 1 }
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
    private let timeline = ProgressTimeline()
    private let probe = ResolutionProbe()
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
