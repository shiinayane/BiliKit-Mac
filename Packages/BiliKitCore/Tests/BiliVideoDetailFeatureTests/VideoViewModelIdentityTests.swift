import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 视频与分 P 的意图隔离：只有最新的 BVID／CID 意图能写回状态或驱动播放器，失败只重试目标分 P，只有凭据失效请求窗口复核。
///
/// 分 P 已定时详情一到就呈现页面，播放清单到达之前不算开播；之后取播放清单失败时页面保留但不可操作。
@Suite(.timeLimit(.minutes(1)))
struct VideoViewModelIdentityTests {
    @Test(arguments: [
        ContentApplicationError.authenticationInvalid,
        .authenticationRequired,
        .authenticationUnavailable,
        .requestRestricted(.httpStatus412)
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

    @Test(arguments: [false, true])
    @MainActor
    func detailIsPresentedBeforePlaybackOnlyWhenThePartIsDecided(multiPart: Bool) async throws {
        let fixture = ContentFixtures()
        let gate = TestGate()
        let player = PlayerStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(
                    fixture,
                    pages: multiPart ? fixture.twoPages : nil,
                    playback: { _, _ in
                        await gate.pass()
                        return fixture.playback
                    }
                )
            ),
            playback: player
        )

        model.loadVideo(fixture.bvid)
        try await gate.waitForEntries()

        if multiPart {
            #expect(model.state == .loading(bvid: fixture.bvid))
            #expect(model.presentedContext == nil)
        } else {
            #expect(model.state == .preparingPlayback(makeVideoContext(detail: fixture.detail)))
            #expect(model.presentedContext?.detail.bvid == fixture.bvid)
        }
        #expect(model.playableVideo == nil)
        #expect(model.presentedPlaybackIdentity == nil)
        #expect(player.loadedPlaybacks.isEmpty)

        await gate.open()
        await waitUntilSettled(model)
        #expect(model.playableVideo?.context.detail.bvid == fixture.bvid)
    }

    /// 取播放清单失败时页面保留但不可操作；重试仍按链接的分 P 序号打开，照常续播。
    @Test
    @MainActor
    func playbackRequestFailureAfterEarlyDetailKeepsTheDetailBlocked() async throws {
        let fixture = ContentFixtures()
        let resumed = fixture.playback(
            resuming: try #require(
                PlaybackResumeMetadata(
                    lastPlayedCID: fixture.page.cid,
                    positionMilliseconds: 42_500
                )
            )
        )
        let player = PlayerStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(
                    fixture,
                    playback: { _, attempt in
                        guard attempt > 1 else {
                            throw ContentApplicationError.playbackUnavailable
                        }
                        return resumed
                    }
                )
            ),
            playback: player
        )

        model.loadVideo(fixture.bvid, preferredPageNumber: 1)
        await waitUntilSettled(model)

        #expect(
            model.state == .failed(bvid: fixture.bvid, failure: .content(.playbackUnavailable))
        )
        #expect(model.presentedContext?.detail.bvid == fixture.bvid)
        #expect(model.blocksPresentedContext)
        #expect(model.operableBVID == nil)

        model.retry()
        await waitUntilSettled(model)

        #expect(model.playableVideo?.context.detail.bvid == fixture.bvid)
        #expect(player.loadedStartPositions == [42.5])
    }

    @Test
    @MainActor
    func leavingWhileThePlaybackListLoadsNeverLoadsThePlayer() async throws {
        let fixture = ContentFixtures()
        let gate = TestGate()
        let player = PlayerStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(
                    fixture,
                    playback: { _, _ in
                        await gate.pass()
                        return fixture.playback
                    }
                )
            ),
            playback: player
        )

        let load = SpawnedTasks { model.loadVideo(fixture.bvid) }
        try await gate.waitForEntries()
        #expect(model.presentedContext?.detail.bvid == fixture.bvid)
        model.reset()
        await gate.open()
        await load.finished()

        #expect(model.state == .idle)
        #expect(model.presentedContext == nil)
        #expect(player.loadedPlaybacks.isEmpty)
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

        let stale = SpawnedTasks { model.loadVideo(slow.detail.bvid) }
        // 旧请求停在自带分 P 的 `/view` 上，此时只有 detail 在飞行。
        try await slowGate.waitForEntries(1)
        model.loadVideo(fast.detail.bvid)
        try await slowGate.waitForCancellations()
        await waitUntilSettled(model)
        await slowGate.open()
        await stale.finished()

        guard case .ready(let playable) = model.state else {
            Issue.record("最新视频未进入就绪状态")
            return
        }
        #expect(playable.context.detail.bvid == fast.detail.bvid)
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
            PlaybackFailureEvent(identity: firstIdentity, intent: oldIntent, positionSeconds: 0)
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

    /// 地址过期的换源只重取当前分 P 的 playurl，把新数据交给播放器；页面全程停在 ready、不停播放器，换源进行中
    /// 重复的事件不再重取。
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func sourceExpiryRefetchesOnlyThePresentedPageAndStaysReady() async throws {
        let fixture = ContentFixtures()
        let repository = VideoRepositoryStub(
            fixture,
            pages: fixture.twoPages,
            playback: { identity, attempt in
                VideoPlayback(
                    media: fixture.playback.media,
                    mediaHeaders: ["Attempt": "\(identity.cid)-\(attempt)"]
                )
            }
        )
        let player = PlayerStub(holdsRefreshes: true)
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )
        model.loadVideo(fixture.bvid, preferredCID: 900_002)
        await waitUntilSettled(model)
        let identity = try #require(model.presentedPlaybackIdentity)
        let initialRequestCount = await repository.playbackRequests.count

        player.expireSource(identity, at: 40)
        await player.waitForRefreshCount(1)
        guard case .ready = model.state else {
            Issue.record("换源期间页面离开了 ready")
            return
        }
        player.expireSource(identity, at: 41)
        await player.waitForSourceExpiryRequestCount(3)

        #expect(await repository.playbackRequests.dropFirst(initialRequestCount) == [identity])
        #expect(player.refreshedIdentities == [identity])
        #expect(player.refreshedPlaybacks.map(\.mediaHeaders) == [["Attempt": "900002-2"]])
        #expect(model.presentedPlaybackIdentity == identity)
        #expect(player.stopCallCount == 0)
        player.releaseHeldRefresh()
    }

    /// 同一 CID 换成新的 load intent（A→B→A）后，旧 intent 迟到的换源事件被丢弃：不重取、不换源、不停播放器。
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func lateSourceExpiryFromAnEarlierIntentIsIgnored() async throws {
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
        let oldIntent = try #require(player.loadedIntents.first)
        model.selectPage(cid: 900_002)
        await waitUntilSettled(model)
        model.selectPage(cid: identity.cid)
        await waitUntilSettled(model)
        let requestCount = await repository.playbackRequests.count
        let stopCount = player.stopCallCount

        player.publishSourceExpiry(
            PlaybackSourceExpiryEvent(identity: identity, intent: oldIntent, positionSeconds: 30)
        )
        await player.waitForSourceExpiryRequestCount(2)

        guard case .ready = model.state else {
            Issue.record("旧 intent 的换源事件改变了页面状态")
            return
        }
        #expect(player.refreshedIdentities.isEmpty)
        #expect(await repository.playbackRequests.count == requestCount)
        #expect(player.stopCallCount == stopCount)
        #expect(model.presentedPlaybackIdentity == identity)
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

        let stale = SpawnedTasks { model.selectPage(cid: 900_002) }
        try await secondPageGate.waitForEntries()
        model.selectPage(cid: 900_001)
        try await secondPageGate.waitForCancellations()
        await waitUntilSettled(model)
        await secondPageGate.open()
        await stale.finished()

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

        let stale = SpawnedTasks { model.selectPage(cid: 900_002) }
        try await secondPageGate.waitForEntries()

        model.selectPage(cid: 900_001)
        try await secondPageGate.waitForCancellations()
        try await firstPageGate.waitForEntries()
        await firstPageGate.open()
        await waitUntilSettled(model)
        await secondPageGate.open()
        await stale.finished()

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
