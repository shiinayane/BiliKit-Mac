import Foundation
import Testing

@testable import BiliApplication

/// 进程级观看进度写入一次只发一个，多个窗口同时退出的写入都会送达，登出后在途与排队的旧会话写入被取消、不再重放。
@Suite(.timeLimit(.minutes(1)))
struct SerializedWatchProgressRepositoryTests {
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
        // 最后一次放行让最后那个 ended 请求完成；它之后不再有事件。
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
    private let timeline = StoreProgressTimeline()
    private let probe = ResolutionProbe()
    private let token: PlaybackTimelineItemToken
    private let session: WatchProgressSession

    init(
        aid: Int64,
        cid: Int64,
        writer: any WatchProgressRepository
    ) throws {
        let identity = PlaybackItemIdentity(bvid: "BV1FIXTURE", cid: cid)
        let intent = PlaybackLoadIntent()
        let target = try #require(
            WatchProgressTarget(
                aid: aid,
                identity: identity,
                loadIntent: intent
            )
        )
        session = WatchProgressSession.fixture(
            repository: writer,
            timeline: timeline,
            targets: [target],
            resolutions: probe
        )
        token = timeline.store.beginItem(identity: identity, loadIntent: intent)
        timeline.store.markReady(token: token, durationSeconds: 120)
    }

    func start() {
        session.start()
        session.setReportingAccess(signedIn: true)
        timeline.store.update(token: token, positionSeconds: 18, rate: 1, state: .playing)
    }

    func end() { timeline.store.update(token: token, rate: 0, state: .ended) }
    /// 依次解析就绪、播放、结束三个快照。
    func waitUntilEndedConsumed() async { await probe.wait(for: 3) }
}
