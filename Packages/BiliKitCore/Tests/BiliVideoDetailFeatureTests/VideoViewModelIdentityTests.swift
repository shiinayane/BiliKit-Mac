import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 视频与分 P 的意图隔离：只有最新的 BVID／CID 意图能写回状态或驱动播放器，失败只重试目标分 P，只有凭据失效请求窗口复核。
@Suite(.timeLimit(.minutes(1)))
struct VideoViewModelIdentityTests {
    @Test(arguments: [
        ContentApplicationError.authenticationInvalid,
        .authenticationRequired,
        .authenticationUnavailable,
        .requestRestricted
    ])
    @MainActor
    func onlyInvalidAuthenticationRequestsAppRevalidation(
        error: ContentApplicationError
    ) async {
        let fixture = ContentFixtures()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(
                    fixture,
                    playback: { _, _ in throw error }
                )
            ),
            playback: PlayerStub()
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)

        #expect(
            model.authenticationRevalidationGeneration
                == (error == .authenticationInvalid ? 1 : 0)
        )
        #expect(
            model.state
                == VideoLoadState.failed(
                    bvid: fixture.bvid,
                    failure: VideoLoadFailure.content(error)
                )
        )
    }

    @Test
    @MainActor
    func playbackFailureRetainsTheNewPresentedContext() async {
        let first = ContentFixtures(bvid: "BV1PresentedA", title: "视频 A")
        let replacement = ContentFixtures(
            bvid: "BV1PresentedB",
            title: "视频 B"
        )
        let repository = VideoRepositoryStub(fixtures: [first, replacement])
        let player = PlayerStub(
            failingBVID: replacement.bvid
        )
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )

        model.loadVideo(first.bvid)
        await waitUntilSettled(model)
        #expect(model.presentedContext?.detail.bvid == first.bvid)

        model.loadVideo(replacement.bvid)
        await waitUntilSettled(model)

        #expect(
            model.state
                == .failed(
                    bvid: replacement.bvid,
                    failure: .playback
                )
        )
        #expect(model.presentedContext?.detail.bvid == replacement.bvid)
    }

    @Test
    @MainActor
    func currentCancellationClearsPresentedContextWhenReturningToIdle() async {
        let first = ContentFixtures(bvid: "BV1CancelA", title: "视频 A")
        let cancelled = ContentFixtures(bvid: "BV1CancelB", title: "视频 B")
        let repository = VideoRepositoryStub(
            fixtures: [first, cancelled],
            cancelledBVID: cancelled.bvid
        )
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(first.bvid)
        await waitUntilSettled(model)
        #expect(model.presentedContext?.detail.bvid == first.bvid)

        model.loadVideo(cancelled.bvid)
        #expect(model.presentedContext?.detail.bvid == first.bvid)
        await waitUntilSettled(model)

        #expect(model.state == .idle)
        #expect(model.presentedContext == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func newerVideoLoadPreventsOldVideoFromLoadingPlayer() async throws {
        let slow = ContentFixtures(bvid: "BV1SlowFixture", title: "旧视频")
        let fast = ContentFixtures(bvid: "BV1FastFixture", title: "新视频")
        let player = PlayerStub()
        let slowGate = TestGate()
        let repository = VideoRepositoryStub(
            detail: { bvid, _ in
                guard bvid == slow.bvid else { return fast.detail }
                await slowGate.pass()
                return slow.detail
            },
            pages: { bvid, _ in
                guard bvid == slow.bvid else { return [fast.page] }
                await slowGate.pass()
                return [slow.page]
            },
            playback: { identity, _ in
                identity.bvid == slow.bvid ? slow.playback : fast.playback
            }
        )
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: repository
            ),
            playback: player
        )

        model.loadVideo(slow.detail.bvid)
        // 旧请求停在自带分 P 的 `/view` 上，此时只有 detail 在飞行。
        try await slowGate.waitForEntries(1)
        model.loadVideo(fast.detail.bvid)
        try await slowGate.waitForCancellations()
        await waitUntilSettled(model)
        await slowGate.open()

        guard case .ready(let context) = model.state else {
            Issue.record("最新视频未进入就绪状态")
            return
        }
        #expect(context.detail.bvid == fast.detail.bvid)
        #expect(model.presentedContext?.detail.bvid == fast.detail.bvid)
        #expect(player.loadedPlaybacks.count == 1)
        #expect(player.startedIdentities.count == 1)
        #expect(player.startedIdentities.first?.bvid == fast.detail.bvid)
        #expect(player.stopCallCount == 1)
        #expect(
            player.loadedPlaybacks.first?.mediaHeaders["Referer"]?.contains(
                fast.detail.bvid
            ) == true
        )
    }

    @Test
    @MainActor
    func pageSelectionReplacesCIDAndResetClearsBothIdentities() async {
        let fixture = ContentFixtures()
        let repository = VideoRepositoryStub(fixture, pages: fixture.twoPages)
        let player = PlayerStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        let firstIdentity = PlaybackItemIdentity(
            bvid: fixture.bvid,
            cid: 900_001
        )
        let secondIdentity = PlaybackItemIdentity(
            bvid: fixture.bvid,
            cid: 900_002
        )
        #expect(model.presentedPlaybackIdentity == firstIdentity)

        model.selectPage(cid: 900_002)
        #expect(model.requestedPlaybackIdentity == secondIdentity)
        #expect(model.presentedPlaybackIdentity == nil)
        await waitUntilSettled(model)

        #expect(model.presentedContext?.selectedPage.cid == 900_002)
        #expect(model.presentedPlaybackIdentity == secondIdentity)
        #expect(player.loadedIdentities == [firstIdentity, secondIdentity])
        #expect(player.startedIdentities == [firstIdentity, secondIdentity])
        #expect(player.stopCallCount == 1)

        model.selectPage(cid: 900_002)
        #expect(player.loadedIdentities == [firstIdentity, secondIdentity])
        #expect(player.startedIdentities == [firstIdentity, secondIdentity])
        model.reset()
        #expect(model.presentedContext == nil)
        #expect(model.requestedPlaybackIdentity == nil)
        #expect(model.presentedPlaybackIdentity == nil)
        #expect(player.stopCallCount == 2)
    }

    @Test
    @MainActor
    func failedPageSelectionRetriesOnlyTheTargetCID() async {
        let fixture = ContentFixtures()
        let repository = VideoRepositoryStub(
            fixture,
            pages: fixture.twoPages,
            playback: { identity, attempt in
                if identity.cid == 900_002, attempt == 1 {
                    throw ContentApplicationError.transportFailure
                }
                return fixture.playback
            }
        )
        let player = PlayerStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )
        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)

        model.selectPage(cid: 900_002)
        await waitUntilSettled(model)
        guard case .failedPage(_, let targetPage, .content) = model.state else {
            Issue.record("目标分 P 未进入内容失败状态")
            return
        }
        #expect(targetPage.cid == 900_002)
        #expect(model.presentedPlaybackIdentity == nil)
        #expect(model.requestedPlaybackIdentity?.cid == 900_002)

        #expect(model.retryIfFailed())
        await waitUntilSettled(model)

        #expect(model.presentedContext?.selectedPage.cid == 900_002)
        #expect(model.presentedPlaybackIdentity?.cid == 900_002)
        #expect(
            await repository.playbackRequests.map(\.cid)
                == [900_001, 900_002, 900_002]
        )
        #expect(player.loadedIdentities.map(\.cid) == [900_001, 900_002])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func postReadyFailureClearsPresentedIdentityAndRetriesCurrentCID()
        async throws
    {
        let fixture = ContentFixtures()
        let repository = VideoRepositoryStub(fixture, pages: fixture.twoPages)
        let player = PlayerStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )
        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        let identity = try #require(model.presentedPlaybackIdentity)

        await player.fail(identity)
        await player.waitForStopCallCount(1)

        guard case .failedPage(_, let targetPage, .playback) = model.state else {
            Issue.record("ready 后失败未进入当前 CID 的失败状态")
            return
        }
        #expect(targetPage.cid == identity.cid)
        #expect(model.requestedPlaybackIdentity == identity)
        #expect(model.presentedPlaybackIdentity == nil)

        model.retry()
        await waitUntilSettled(model)

        #expect(model.presentedPlaybackIdentity == identity)
        #expect(player.loadedIdentities == [identity, identity])
        #expect(player.stopCallCount == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func failureBeforeLoadReturnsCannotRestoreReadyState() async throws {
        let fixture = ContentFixtures()
        let repository = VideoRepositoryStub(fixture, pages: fixture.twoPages)
        let player = PlayerStub(failsFirstLoadUntilStopped: true)
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        let identity = PlaybackItemIdentity(
            bvid: fixture.bvid,
            cid: 900_001
        )

        guard case .failedPage(_, let targetPage, .playback) = model.state else {
            Issue.record("load 返回前的 item failure 被错误恢复为 ready")
            return
        }
        #expect(targetPage.cid == identity.cid)
        #expect(model.requestedPlaybackIdentity == identity)
        #expect(model.presentedPlaybackIdentity == nil)
        #expect(player.stopCallCount == 1)

        model.retry()
        await waitUntilSettled(model)

        #expect(model.presentedPlaybackIdentity == identity)
        #expect(player.loadedIdentities == [identity, identity])
        #expect(player.stopCallCount == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func delayedOldSameCIDFailureCannotStopNewABAIntent() async throws {
        let fixture = ContentFixtures()
        let repository = VideoRepositoryStub(fixture, pages: fixture.twoPages)
        let player = PlayerStub(heldLoad: 3)
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        let firstIdentity = PlaybackItemIdentity(
            bvid: fixture.bvid,
            cid: 900_001
        )
        let oldIntent = try #require(player.loadedIntents.first)

        model.selectPage(cid: 900_002)
        await waitUntilSettled(model)
        model.selectPage(cid: 900_001)
        await player.waitForLoadCount(3)

        await player.publishFailure(
            PlaybackFailureEvent(identity: firstIdentity, intent: oldIntent)
        )
        await player.waitForFailureRequestCount(2)
        guard case .preparingPlayback = model.state else {
            Issue.record("旧 A failure 错误停止了新 A intent")
            return
        }
        #expect(player.stopCallCount == 2)

        player.releaseHeldLoad()
        await waitUntilSettled(model)

        #expect(model.presentedPlaybackIdentity == firstIdentity)
        #expect(player.loadedIdentities.map(\.cid) == [900_001, 900_002, 900_001])
        #expect(player.loadedIntents[0] != player.loadedIntents[2])
        #expect(player.startedIdentities.map(\.cid) == [900_001, 900_002, 900_001])
        #expect(player.startedIntents == player.loadedIntents)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func lateSupersededAuthenticationFailureCannotRequestRevalidation()
        async throws
    {
        let fixture = ContentFixtures()
        let secondPageGate = TestGate()
        let repository = VideoRepositoryStub(
            fixture,
            pages: fixture.twoPages,
            playback: { identity, _ in
                guard identity.cid == 900_002 else { return fixture.playback }
                await secondPageGate.pass()
                throw ContentApplicationError.authenticationInvalid
            }
        )
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )
        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)

        model.selectPage(cid: 900_002)
        try await secondPageGate.waitForEntries()
        model.selectPage(cid: 900_001)
        try await secondPageGate.waitForCancellations()
        await waitUntilSettled(model)
        await secondPageGate.open()

        #expect(model.authenticationRevalidationGeneration == 0)
        #expect(model.presentedPlaybackIdentity?.cid == 900_001)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func rapidPageABARejectsTheLateSupersededResult() async throws {
        let fixture = ContentFixtures()
        let firstPageGate = TestGate()
        let secondPageGate = TestGate()
        let repository = VideoRepositoryStub(
            fixture,
            pages: fixture.twoPages,
            playback: { identity, attempt in
                if identity.cid == 900_002 {
                    await secondPageGate.pass()
                } else if attempt > 1 {
                    await firstPageGate.pass()
                }
                return fixture.playback
            }
        )
        let player = PlayerStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )
        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)

        model.selectPage(cid: 900_002)
        try await secondPageGate.waitForEntries()

        model.selectPage(cid: 900_001)
        try await secondPageGate.waitForCancellations()
        try await firstPageGate.waitForEntries()
        await firstPageGate.open()
        await waitUntilSettled(model)
        await secondPageGate.open()

        #expect(model.presentedContext?.selectedPage.cid == 900_001)
        #expect(model.presentedPlaybackIdentity?.cid == 900_001)
        #expect(player.loadedIdentities.map(\.cid) == [900_001, 900_001])
        #expect(player.stopCallCount == 2)
    }

    /// 字幕目录等播放附带读取发现凭据失效：播放照常，只请求窗口复核。
    @Test
    @MainActor
    func playbackAuthenticationInvalidationRequestsRevalidation() async {
        let (invalidations, continuation) = AsyncStream<Void>.makeStream()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: VideoRepositoryStub(ContentFixtures())),
            playback: PlayerStub(),
            playbackAuthenticationInvalidations: invalidations
        )

        continuation.yield()
        await waitForObservedState { model.authenticationRevalidationGeneration == 1 }

        #expect(model.state == .idle)
    }
}
