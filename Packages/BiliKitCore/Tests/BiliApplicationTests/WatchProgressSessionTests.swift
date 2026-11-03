import Foundation
import Testing

@testable import BiliApplication

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct WatchProgressSessionTests {
    @Test
    func emitsStartPeriodicPauseResumeAndNaturalEnd() async throws {
        let fixture = try makeFixture()
        fixture.session.start()
        fixture.session.setReportingAccess(signedIn: true)

        fixture.send(state: .playing)
        let started = await fixture.repository.nextReport()
        #expect(started.event == .started)

        fixture.time.value = 15
        fixture.send(position: 15, state: .playing)
        await fixture.resolutions.wait(for: 3)
        fixture.ticks.tick()
        let periodic = await fixture.repository.nextReport()
        #expect(periodic.event == .periodic)
        #expect(periodic.positionSeconds == 15)
        #expect(periodic.playedSeconds == 15)

        fixture.time.value = 18
        fixture.send(position: 18, state: .paused)
        let paused = await fixture.repository.nextReport()
        #expect(paused.event == .paused)
        #expect(paused.positionSeconds == 18)
        #expect(paused.playedSeconds == 18)

        fixture.send(position: 18, state: .playing)
        let resumed = await fixture.repository.nextReport()
        #expect(resumed.event == .resumed)
        #expect(fixture.ticks.intervals == [15, 15])

        fixture.time.value = 20
        fixture.send(position: 20, state: .ended)
        let ended = await fixture.repository.nextReport()
        #expect(ended.event == .ended)
        #expect(ended.completed)
        #expect(ended.positionSeconds == 20)
    }

    /// 播完之后跳回开头（单集循环的重播）再播放是新的一次观看：起播时的缓冲不让旧会话再报 resumed，真正播放时
    /// 另起会话，第二轮播完照常报完成。
    @Test
    func replayAfterTheEndStartsANewCompletedSession() async throws {
        let fixture = try makeFixture()
        fixture.session.start()
        fixture.session.setReportingAccess(signedIn: true)

        fixture.send(state: .playing)
        let first = await fixture.repository.nextReport()
        fixture.time.value = 120
        fixture.send(position: 120, state: .ended)
        let firstEnded = await fixture.repository.nextReport()
        #expect(firstEnded.event == .ended)
        #expect(firstEnded.completed)

        fixture.seek(to: 0)
        fixture.send(position: 0, state: .buffering)
        fixture.send(position: 0, state: .playing)
        let second = await fixture.repository.nextReport()
        #expect(second.event == .started)
        #expect(second.generation != first.generation)
        #expect(second.playedSeconds == 0)

        fixture.time.value = 240
        fixture.send(position: 120, state: .ended)
        let secondEnded = await fixture.repository.nextReport()
        #expect(secondEnded.event == .ended)
        #expect(secondEnded.completed)
        #expect(secondEnded.generation == second.generation)
    }

    @Test
    func exitAtEighteenUsesCurrentPositionInsteadOfLastPeriodic() async throws {
        let fixture = try makeFixture()
        fixture.session.start()
        fixture.session.setReportingAccess(signedIn: true)
        fixture.send(state: .playing)
        _ = await fixture.repository.nextReport()

        fixture.time.value = 15
        fixture.send(position: 15, state: .playing)
        await fixture.resolutions.wait(for: 3)
        fixture.ticks.tick()
        _ = await fixture.repository.nextReport()

        fixture.time.value = 18
        fixture.send(position: 18, state: .playing)
        await fixture.resolutions.wait(for: 4)
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
        fixture.send(state: .playing)
        _ = await fixture.repository.nextReport()

        fixture.time.value = 20
        fixture.send(position: 20, state: .playing)
        fixture.seek(to: 5)
        fixture.time.value = 21
        fixture.send(position: 5, state: .buffering)
        await fixture.resolutions.wait(for: 5)
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
        fixture.send(state: .playing)
        fixture.ticks.tick()

        fixture.session.setReportingAccess(signedIn: false)
        fixture.send(position: 10, state: .playing)
        fixture.ticks.tick()
        fixture.session.stop()

        // 写入经异步 Task 才到 repository，此刻直接数次数证明不了什么。session 一次只有一个在途写入、待发队列先进
        // 先出，所以打开写入后造一份可辨认的报告：它是 repository 收到的第一份，就说明之前没有任何写入。
        fixture.send(position: 42, state: .playing)
        fixture.session.setReportingAccess(signedIn: true)
        let first = await fixture.repository.nextReport()
        #expect(first.event == .started)
        #expect(first.positionSeconds == 42)
    }

    @Test(arguments: [
        WatchProgressError.authenticationInvalid,
        WatchProgressError.requestRestricted,
        WatchProgressError.unavailable
    ])
    func reportingFailureClosesOnlyHeartbeatSession(
        error: WatchProgressError
    ) async throws {
        let fixture = try makeFixture(repository: ProgressRepositoryStub(firstFailure: error))
        fixture.session.start()
        fixture.session.setReportingAccess(signedIn: true)
        fixture.send(state: .playing)
        let failed = await fixture.repository.nextReport()
        await fixture.ticks.waitForTermination(1)

        fixture.time.value = 15
        fixture.ticks.tick()
        fixture.send(position: 15, state: .playing)

        #expect(fixture.ticks.intervals == [15])
        #expect(fixture.timeline.currentTimelineSnapshot.state == .playing)

        // 失败的会话里，暂停与播完本该各报一次边界。播完再播是新会话，必然上报 started：写入串行且先进先出，
        // 它是失败之后 repository 收到的第一份，就说明失败的会话没有再上报。
        fixture.send(position: 16, state: .paused)
        fixture.send(position: 20, state: .ended)
        fixture.send(position: 0, state: .playing)
        let next = await fixture.repository.nextReport()
        #expect(next.event == .started)
        #expect(next.generation != failed.generation)
    }

    @Test
    func slowStartedStillPreservesFinalExitWhenBoundariesSaturate() async throws {
        let repository = ProgressRepositoryStub(blocking: .all)
        let fixture = try makeFixture(repository: repository)
        fixture.session.start()
        fixture.session.setReportingAccess(signedIn: true)
        fixture.send(state: .playing)
        #expect(await repository.nextReport().event == .started)

        var resolutionTarget = 2
        for index in 1...24 {
            fixture.time.value = Double(index)
            let state: PlaybackTimelineState = index.isMultiple(of: 2) ? .playing : .paused
            fixture.send(position: Double(index), state: state)
            resolutionTarget += 1
        }
        fixture.send(position: 24, state: .ended)
        resolutionTarget += 1
        await fixture.resolutions.wait(for: resolutionTarget)

        await repository.releaseNext()
        var terminal: WatchProgressReport?
        while terminal == nil {
            let next = await repository.nextReport()
            if next.event == .ended {
                terminal = next
            }
            await repository.releaseNext()
        }
        #expect(terminal?.positionSeconds == 24)
    }

    @Test
    func periodicCoalescesBeforeBoundariesAndFinalEndRemainsLast() async throws {
        let repository = ProgressRepositoryStub(blocking: .all)
        let fixture = try makeFixture(repository: repository)
        fixture.session.start()
        fixture.session.setReportingAccess(signedIn: true)
        fixture.send(state: .playing)
        #expect(await repository.nextReport().event == .started)

        // started 仍在途时，三次 tick 只保留同会话最新的 periodic。
        for (index, position) in [5.0, 10.0, 15.0].enumerated() {
            fixture.time.value = position
            fixture.send(position: position, state: .playing)
            fixture.ticks.tick()
            await fixture.ticks.waitForDemand(index + 2)
        }
        await repository.releaseNext()
        let periodic = await repository.nextReport()
        #expect(periodic.event == .periodic)
        #expect(periodic.positionSeconds == 15)

        // periodic 在途时再排队的 periodic 被后续边界挤掉；ended 最后且完成。
        fixture.ticks.tick()
        await fixture.ticks.waitForDemand(5)
        fixture.send(position: 16, state: .paused)
        fixture.send(position: 16, state: .playing)
        fixture.send(position: 18, state: .ended)

        var boundaries: [WatchProgressReport] = []
        for _ in 0..<3 {
            await repository.releaseNext()
            boundaries.append(await repository.nextReport())
        }
        await repository.releaseNext()
        #expect(boundaries.map(\.event) == [.paused, .resumed, .ended])
        #expect(boundaries.last?.positionSeconds == 18)
        #expect(boundaries.last?.completed == true)
        #expect(await repository.reportCount == 5)
    }

    @Test
    func suspensionFreezesTimerAndPlayedAccountingWithoutStorm() async throws {
        let fixture = try makeFixture()
        fixture.session.start()
        fixture.session.setReportingAccess(signedIn: true)
        fixture.send(state: .playing)
        _ = await fixture.repository.nextReport()

        fixture.time.value = 5
        fixture.session.suspend()
        fixture.time.value = 105
        fixture.ticks.tick()
        // 挂起期间的 tick 要么已被处理完（请求数到 2），要么因计时器已停止再也不会被处理；落定后再恢复，挂起期间
        // 若有写入就排在下面的 periodic 之前，被它的断言抓住。只数写入次数不行：tick 可能拖到恢复之后才处理。
        await fixture.ticks.waitUntilTickSettles(demand: 2, termination: 1)

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
        let repository = ProgressRepositoryStub()
        let resolutions = ResolutionProbe()
        let identity = PlaybackItemIdentity(bvid: "BV1STORETIMELINE", cid: 22)
        let loadIntent = PlaybackLoadIntent()
        let target = try #require(
            WatchProgressTarget(aid: 11, identity: identity, loadIntent: loadIntent)
        )
        let session = WatchProgressSession(
            useCase: WatchProgressUseCase(repository: repository),
            timeline: timeline,
            resolveTarget: { candidateIdentity, candidateIntent in
                resolutions.observe()
                return candidateIdentity == identity && candidateIntent == loadIntent
                    ? target : nil
            },
            environment: .fixture()
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

        // stop 之后 session 不再消费时间线，也就不会再解析写入目标。
        session.stop()
        let resolvedBeforeStop = resolutions.count
        timeline.store.beginItem(identity: identity, loadIntent: loadIntent)
        #expect(resolutions.count == resolvedBeforeStop)
    }

    @Test(arguments: [
        WatchProgressError.authenticationInvalid,
        WatchProgressError.unavailable
    ])
    func lateFailureCannotDisableOrReplayAcrossAThroughB(
        firstError: WatchProgressError
    ) async throws {
        let timeline = StoreProgressTimeline()
        let repository = ProgressRepositoryStub(firstFailure: firstError, blocking: .first)
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
            environment: .fixture()
        )
        session.start()
        session.setReportingAccess(signedIn: true)
        beginPlaying(identity: identityA, intent: intentA1, on: timeline)
        #expect(await repository.nextReport().target.loadIntent == intentA1)

        beginPlaying(identity: identityB, intent: intentB, on: timeline)
        beginPlaying(identity: identityA, intent: intentA2, on: timeline)
        // 每个 item 先发布 loading 再进入播放，各解析两次。
        await resolutions.wait(for: 6)
        await repository.releaseNext()

        var replacementStarted = false
        while !replacementStarted {
            let report = await repository.nextReport()
            replacementStarted =
                report.event == .started
                && report.target.loadIntent == intentA2
        }
        #expect(replacementStarted)
        #expect(timeline.currentTimelineSnapshot.state == .playing)
    }

    /// 在真实时间线上换到新的播放 item 并开始播放。
    private func beginPlaying(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        on timeline: StoreProgressTimeline
    ) {
        let token = timeline.store.beginItem(identity: identity, loadIntent: intent)
        timeline.store.update(token: token, rate: 1, state: .playing)
    }

    /// 时间线已就绪于唯一 item，session 尚未订阅；打开报告权限时 session 会先解析一次这个就绪快照。
    private func makeFixture(
        repository: ProgressRepositoryStub = ProgressRepositoryStub()
    ) throws -> ProgressFixture {
        let timeline = StoreProgressTimeline()
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
            environment: .fixture(
                monotonicTime: { time.value },
                periodicTicks: { ticks.stream(every: $0) }
            )
        )
        let token = timeline.store.beginItem(identity: identity, loadIntent: loadIntent)
        timeline.store.markReady(token: token, durationSeconds: 120)
        return ProgressFixture(
            timeline: timeline,
            token: token,
            repository: repository,
            ticks: ticks,
            time: time,
            resolutions: resolutions,
            session: session
        )
    }
}

@MainActor
private struct ProgressFixture {
    let timeline: StoreProgressTimeline
    let token: PlaybackTimelineItemToken
    let repository: ProgressRepositoryStub
    let ticks: ManualProgressTicks
    let time: TestMonotonicTime
    let resolutions: ResolutionProbe
    let session: WatchProgressSession

    func send(position: Double = 0, state: PlaybackTimelineState) {
        timeline.store.update(
            token: token,
            positionSeconds: position,
            rate: state == .playing ? 1 : 0,
            state: state
        )
    }

    func seek(to position: Double) {
        timeline.store.markDiscontinuity(token: token, positionSeconds: position)
    }
}

@MainActor
private final class TestMonotonicTime { var value = 0.0 }
