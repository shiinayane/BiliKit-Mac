import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 起播位置：链接时间优先于续播且只用一次，登录续播先选记录的分 P，被取代的从头播放不能清掉提示或覆盖新的请求。
@Suite(.timeLimit(.minutes(1)))
struct VideoViewModelResumeTests {
    /// 链接给的起播秒数（`t=`）优先于续播位置，且不显示续播提示；超出该分 P 时长时忽略，照常续播。
    @Test(arguments: [(30, 30.0, false), (180, 42.5, true)] as [(Int, Double, Bool)])
    @MainActor
    func linkStartSecondsOverrideResumeWithoutTheNotice(
        startSeconds: Int,
        expectedStart: Double,
        showsResumeNotice: Bool
    ) async throws {
        let fixture = ContentFixtures()
        let metadata = try #require(
            PlaybackResumeMetadata(lastPlayedCID: 900_002, positionMilliseconds: 42_500)
        )
        let repository = VideoRepositoryStub(
            fixture,
            pages: fixture.twoPages,
            playback: { _, _ in fixture.playback(resuming: metadata) }
        )
        let player = PlayerStub(
            startOutcome: .resumed(positionSeconds: expectedStart, token: PlaybackResumeToken())
        )
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )

        model.loadVideo(fixture.bvid, startSeconds: startSeconds)
        await waitUntilSettled(model)

        #expect(model.presentedContext?.selectedPage.cid == 900_002)
        #expect(player.loadedStartPositions == [expectedStart])
        #expect((model.resumeNotice != nil) == showsResumeNotice)
    }

    /// 同一视频里换到链接给的分 P 时也从链接时间起播；应用内选分 P 不带起播秒数。
    @Test
    @MainActor
    func pageSelectionFromALinkStartsAtTheLinkTime() async {
        let fixture = ContentFixtures()
        let repository = VideoRepositoryStub(fixture, pages: fixture.twoPages)
        let player = PlayerStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )
        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)

        model.selectPage(cid: 900_002, startSeconds: 90)
        await waitUntilSettled(model)
        model.selectPage(cid: 900_001)
        await waitUntilSettled(model)

        #expect(player.loadedStartPositions.suffix(2) == [90, nil])
    }

    /// 开播后播放失败，重试从失败时的位置继续：不从头开始，也不跳回已经用过的链接时间。
    @Test
    @MainActor
    func retryAfterPlaybackStartedResumesAtTheFailurePosition() async throws {
        let fixture = ContentFixtures()
        let repository = VideoRepositoryStub(fixture, pages: fixture.twoPages)
        let player = PlayerStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )
        model.loadVideo(fixture.bvid, preferredCID: 900_002, startSeconds: 90)
        await waitUntilSettled(model)
        let identity = try #require(model.presentedPlaybackIdentity)

        await player.fail(identity, at: 123.4)
        await player.waitForStopCallCount(1)
        model.retry()
        await waitUntilSettled(model)

        #expect(player.loadedStartPositions == [90, 123])
    }

    /// 换源时重取 playurl 失败：停下播放器、在原视频上呈现分 P 失败，重试从换源时的位置继续。
    @Test
    @MainActor
    func failedSourceRefreshRetriesAtTheRefreshPosition() async throws {
        let fixture = ContentFixtures()
        let repository = VideoRepositoryStub(
            fixture,
            pages: fixture.twoPages,
            playback: { _, attempt in
                guard attempt != 2 else { throw ContentApplicationError.unavailable }
                return fixture.playback
            }
        )
        let player = PlayerStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )
        model.loadVideo(fixture.bvid, preferredCID: 900_002)
        await waitUntilSettled(model)
        let identity = try #require(model.presentedPlaybackIdentity)

        player.expireSource(identity, at: 75.8)
        await player.waitForStopCallCount(1)

        guard case .failedPage(_, let targetPage, .content(.unavailable)) = model.state else {
            Issue.record("换源失败没有呈现为分 P 失败")
            return
        }
        #expect(targetPage.cid == identity.cid)
        #expect(player.refreshedIdentities.isEmpty)
        model.retry()
        await waitUntilSettled(model)

        #expect(player.loadedStartPositions == [nil, 75])
        #expect(model.presentedPlaybackIdentity == identity)
    }

    /// 同一分 P 还在加载时收到带起播秒数的链接：取消在途加载，从链接时间重开，不被去重吞掉。
    @Test
    @MainActor
    func aLinkStartForThePartStillLoadingRestartsIt() async {
        let fixture = ContentFixtures()
        let repository = VideoRepositoryStub(fixture, pages: fixture.twoPages)
        let player = PlayerStub(heldLoad: 2)
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )
        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        model.selectPage(cid: 900_002)
        await player.waitForLoadCount(2)

        model.selectPage(cid: 900_002, startSeconds: 90)
        await waitUntilSettled(model)

        #expect(player.loadedStartPositions == [nil, nil, 90])
        #expect(model.presentedPlaybackIdentity?.cid == 900_002)
        player.releaseHeldLoad()
    }

    @Test
    @MainActor
    func authenticatedResumeSelectsRecordedPartBeforeStartingAndCanRestart()
        async throws
    {
        let fixture = ContentFixtures()
        let resumeToken = PlaybackResumeToken()
        let metadata = try #require(
            PlaybackResumeMetadata(
                lastPlayedCID: 900_002,
                positionMilliseconds: 42_500
            )
        )
        let repository = VideoRepositoryStub(
            fixture,
            pages: fixture.twoPages,
            playback: { _, _ in fixture.playback(resuming: metadata) }
        )
        let player = PlayerStub(
            startOutcome: .resumed(positionSeconds: 42.5, token: resumeToken),
            restartSucceeds: true
        )
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)

        #expect(model.presentedContext?.selectedPage.cid == 900_002)
        #expect(await repository.playbackRequests.map(\.cid) == [900_001, 900_002])
        #expect(player.loadedStartPositions == [42.5])
        #expect(
            model.resumeNotice
                == PlaybackResumeNotice(
                    positionSeconds: 42.5,
                    token: resumeToken
                )
        )

        model.restartFromBeginning()
        await waitForObservedState { model.resumeNotice == nil }

        #expect(player.restartTokens == [resumeToken])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func supersededRestartCannotClearNoticeOrNewerRestart() async throws {
        let fixture = ContentFixtures()
        let resumeToken = PlaybackResumeToken()
        let metadata = try #require(
            PlaybackResumeMetadata(
                lastPlayedCID: 900_001,
                positionMilliseconds: 42_500
            )
        )
        let repository = VideoRepositoryStub(
            fixture,
            playback: { _, _ in fixture.playback(resuming: metadata) }
        )
        let player = PlayerStub(
            startOutcome: .resumed(positionSeconds: 42.5, token: resumeToken),
            restartSucceeds: true,
            holdsRestarts: true
        )
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )
        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        #expect(model.resumeNotice != nil)

        model.restartFromBeginning()
        await player.waitForRestartCount(1)
        model.restartFromBeginning()
        await player.waitForRestartCount(2)

        player.releaseRestart(at: 0)
        // 替身在 main actor 上直接恢复旧动作；让出一次后，main executor 的 FIFO 保证旧动作已经跑完。
        await Task.yield()
        #expect(model.resumeNotice != nil)

        player.releaseRestart(at: 1)
        await waitForObservedState { model.resumeNotice == nil }
    }
}
