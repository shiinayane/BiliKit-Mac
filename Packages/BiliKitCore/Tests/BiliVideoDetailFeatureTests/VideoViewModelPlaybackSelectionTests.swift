import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 播放选择策略：链接的分 P 序号与起播秒数落到当前视频上（就地换分 P、原地跳转或重新加载），失败后的重试由模型
/// 承担或交回导航。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct VideoViewModelPlaybackSelectionTests {
    private let fixture = ContentFixtures(bvid: "BV1PageRoute")
    private let initialPage = VideoPage(cid: 910_001, index: 1, title: "P1", durationSeconds: 60)
    private let secondPage = VideoPage(cid: 910_002, index: 2, title: "P2", durationSeconds: 60)
    private let thirdPage = VideoPage(cid: 910_003, index: 3, title: "P3", durationSeconds: 60)

    @Test
    func linkPageNumbersSelectTheirParts() async {
        let repository = makeRepository()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.select(PlaybackSelectionIntent(bvid: fixture.bvid, preferredPageNumber: 2))
        await waitUntilSettled(model)

        #expect(model.presentedPlaybackIdentity?.cid == secondPage.cid)
        #expect(model.requestedPreferredCID == secondPage.cid)

        model.select(PlaybackSelectionIntent(bvid: fixture.bvid, preferredPageNumber: 3))
        await waitUntilSettled(model)

        #expect(model.presentedPlaybackIdentity?.cid == thirdPage.cid)
        #expect(await repository.playbackRequests.map(\.cid) == [secondPage.cid, thirdPage.cid])
    }

    /// 链接带 `t=`：指向正在播放、已装好的分 P（没给分 P 视为当前分 P）时原地跳转；指向别的分 P 时换分 P 并从该
    /// 时间起播。
    @Test
    func linkStartSecondsSeekInPlaceOrStartTheOtherPart() async {
        let player = PlayerStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: makeRepository()),
            playback: player
        )
        model.select(PlaybackSelectionIntent(bvid: fixture.bvid, preferredPageNumber: 2))
        await waitUntilSettled(model)
        func inPlace(_ intent: PlaybackSelectionIntent, current: String? = nil) -> Int? {
            model.inPlaceStartSeconds(for: intent, currentPlaybackBVID: current ?? fixture.bvid)
        }

        #expect(
            inPlace(PlaybackSelectionIntent(bvid: fixture.bvid, preferredStartSeconds: 30)) == 30
        )
        #expect(
            inPlace(
                PlaybackSelectionIntent(
                    bvid: fixture.bvid,
                    preferredPageNumber: 2,
                    preferredStartSeconds: 30
                )
            ) == 30
        )
        #expect(
            inPlace(
                PlaybackSelectionIntent(
                    bvid: fixture.bvid,
                    preferredPageNumber: 3,
                    preferredStartSeconds: 30
                )
            ) == nil
        )
        #expect(inPlace(PlaybackSelectionIntent(bvid: fixture.bvid)) == nil)
        // 分 P 时长 60 秒：等于时长的起播秒数不在可跳转范围内，不原地跳转。
        #expect(
            inPlace(PlaybackSelectionIntent(bvid: fixture.bvid, preferredStartSeconds: 60)) == nil
        )
        #expect(
            inPlace(
                PlaybackSelectionIntent(bvid: fixture.bvid, preferredStartSeconds: 30),
                current: "BV1Other"
            ) == nil
        )

        model.select(
            PlaybackSelectionIntent(
                bvid: fixture.bvid,
                preferredPageNumber: 3,
                preferredStartSeconds: 30
            )
        )
        await waitUntilSettled(model)

        #expect(player.loadedIdentities.map(\.cid) == [secondPage.cid, thirdPage.cid])
        #expect(player.loadedStartPositions == [nil, 30])
    }

    /// 已经在看这个视频时，不带分 P 或分 P 序号超出范围的链接保持当前播放，不重新加载。
    @Test
    func linksToThePlayingVideoWithoutAResolvablePageKeepPlayback() async {
        let repository = makeRepository()
        let player = PlayerStub()
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )
        model.select(PlaybackSelectionIntent(bvid: fixture.bvid, preferredPageNumber: 2))
        await waitUntilSettled(model)

        model.select(PlaybackSelectionIntent(bvid: fixture.bvid))
        model.select(PlaybackSelectionIntent(bvid: fixture.bvid, preferredPageNumber: 99))

        #expect(player.loadedIdentities.map(\.cid) == [secondPage.cid])
        #expect(await repository.playbackRequests.map(\.cid) == [secondPage.cid])
    }

    /// 从带分 P 的链接打开后播放器准备失败：同一意图再次选择时重新加载同一分 P 并开播，不被同一播放身份的
    /// 去重吞掉。
    @Test
    func selectingAgainAfterAPlayerFailureFromAPageLinkReloads() async {
        let player = PlayerStub(failingLoads: [1])
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: makeRepository()),
            playback: player
        )
        let intent = PlaybackSelectionIntent(bvid: fixture.bvid, preferredPageNumber: 2)

        model.select(intent)
        await waitUntilSettled(model)
        guard case .failed = model.state else {
            Issue.record("播放器准备失败后应进入整体失败状态，实际为 \(model.state)")
            return
        }

        model.select(intent)
        await waitUntilSettled(model)

        guard case .ready = model.state else {
            Issue.record("再次选择后应开播，实际为 \(model.state)")
            return
        }
        #expect(model.presentedPlaybackIdentity?.cid == secondPage.cid)
        #expect(player.loadedIdentities.map(\.cid) == [secondPage.cid, secondPage.cid])
    }

    @Test
    func failedPageSelectionRoutesANewCIDInsteadOfRetryingTheOldTarget() async {
        let failingCID = secondPage.cid
        let repository = makeRepository(playback: { [fixture] identity, _ in
            if identity.cid == failingCID {
                throw ContentApplicationError.transportFailure
            }
            return fixture.playback
        })
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(fixture.bvid, preferredCID: initialPage.cid)
        await waitUntilSettled(model)
        model.selectPage(cid: secondPage.cid)
        await waitUntilSettled(model)
        guard case .failedPage(_, let failedPage, _) = model.state else {
            Issue.record("切换失败后应保留失败的分 P 目标")
            return
        }
        #expect(failedPage.cid == secondPage.cid)

        model.select(PlaybackSelectionIntent(bvid: fixture.bvid, preferredCID: thirdPage.cid))
        await waitUntilSettled(model)

        #expect(model.requestedPreferredCID == thirdPage.cid)
        #expect(model.presentedPlaybackIdentity?.cid == thirdPage.cid)
        #expect(
            await repository.playbackRequests.map(\.cid) == [
                initialPage.cid, secondPage.cid, thirdPage.cid
            ]
        )
    }

    /// 失败时由模型重试并告诉调用方已处理；不在失败状态时交回调用方重新发出导航意图。
    @Test
    func retryIfFailedRetriesOnlyFailures() async {
        let player = PlayerStub(failingBVID: fixture.bvid)
        let model = makeVideoViewModel(
            useCase: VideoUseCase(repository: makeRepository()),
            playback: player
        )
        #expect(!model.retryIfFailed())

        model.select(PlaybackSelectionIntent(bvid: fixture.bvid))
        await waitUntilSettled(model)
        guard case .failed = model.state else {
            Issue.record("播放器准备失败后应进入整体失败状态，实际为 \(model.state)")
            return
        }

        #expect(model.retryIfFailed())
        await player.waitForLoadCount(2)
        #expect(player.loadedIdentities.map(\.cid) == [initialPage.cid, initialPage.cid])
    }

    private func makeRepository(
        playback: ScriptedResponse<PlaybackItemIdentity, VideoPlayback>? = nil
    ) -> VideoRepositoryStub {
        VideoRepositoryStub(
            fixture,
            pages: [initialPage, secondPage, thirdPage],
            playback: playback
        )
    }
}
