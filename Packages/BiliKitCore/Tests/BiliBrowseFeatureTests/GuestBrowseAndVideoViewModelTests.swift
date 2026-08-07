//
//  BiliKitMacTests.swift
//  BiliKitMacTests
//
//  Created by shiinayane on 2026/07/21.
//

import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

@Suite(.timeLimit(.minutes(1)))
struct GuestBrowseAndVideoViewModelTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func newerPopularRequestPreventsOldSearchFromOverwritingFeed() async throws {
        let fixture = GuestFixtures()
        let repository = FeedSwitchingRepositoryStub(fixtures: fixture)
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(
                repository: repository
            )
        )

        model.search("旧搜索")
        try await repository.waitForSearchStart()
        let supersededTask = try #require(model.taskSnapshotForTesting())
        model.refreshPopular()
        await model.waitForCurrentTask()
        await repository.releaseSearch()
        await supersededTask.value

        #expect(
            model.state
                == .loaded(
                    .popular(
                        PopularPage(
                            videos: [fixture.popularVideo],
                            pageNumber: 1,
                            pageSize: 20
                        )
                    )
                )
        )
    }

    @Test
    @MainActor
    func failedSearchRetriesItsOriginalRequest() async {
        let fixture = GuestFixtures()
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(
                repository: RetryingSearchRepositoryStub(fixtures: fixture)
            )
        )

        model.search("macOS", page: 2)
        await model.waitForCurrentTask()
        #expect(
            model.state
                == .failed(
                    request: .search(query: "macOS", page: 2),
                    error: .requestRestricted
                )
        )

        model.retry(.search(query: "macOS", page: 2))
        await model.waitForCurrentTask()
        #expect(
            model.state
                == .loaded(
                    .search(
                        query: "macOS",
                        page: SearchPage(
                            videos: [fixture.searchVideo],
                            pageNumber: 2,
                            pageSize: 20,
                            totalResults: 1,
                            totalPages: 1
                        )
                    )
                )
        )
    }

    @Test
    @MainActor
    func tabRoundTripReusesPopularAndSearchWorksetsWithoutNewRequests() async {
        let fixture = GuestFixtures()
        let repository = WorksetRepositoryStub(fixtures: fixture)
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )
        let searchRequest = GuestFeedRequest.search(query: "macOS", page: 1)

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()

        model.activateSearch("macOS")
        await model.waitForCurrentTask()
        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()

        #expect(await repository.popularCallCount == 1)
        #expect(await repository.searchCallCount == 1)
        #expect(
            model.presentation(for: searchRequest).state
                == .loaded(
                    .search(
                        query: "macOS",
                        page: SearchPage(
                            videos: [fixture.searchVideo],
                            pageNumber: 1,
                            pageSize: 20,
                            totalResults: 1,
                            totalPages: 1
                        )
                    )
                )
        )
        #expect(
            model.state
                == .loaded(
                    .popular(
                        PopularPage(
                            videos: [fixture.popularVideo],
                            pageNumber: 1,
                            pageSize: 50
                        )
                    )
                )
        )
    }

    @Test
    @MainActor
    func failedRefreshKeepsMatchingLoadedContentVisible() async {
        let fixture = GuestFixtures()
        let repository = WorksetRepositoryStub(fixtures: fixture)
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        let loadedState = model.state
        await repository.failNextPopularRequest()

        model.refreshPopular(pageSize: 50)
        #expect(model.state == loadedState)
        #expect(model.isRefreshing)
        await model.waitForCurrentTask()

        #expect(model.state == loadedState)
        #expect(!model.isRefreshing)
        #expect(model.refreshError == .requestRestricted)
        #expect(await repository.popularCallCount == 2)
    }

    @Test
    @MainActor
    func resetClearsWorksetsAndRequiresANewLoad() async {
        let fixture = GuestFixtures()
        let repository = WorksetRepositoryStub(fixtures: fixture)
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )
        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        model.reset()

        #expect(
            model.presentation(
                for: .popular(page: 1, pageSize: 50)
            ).state == .idle
        )
        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        #expect(await repository.popularCallCount == 2)
    }

    @Test
    @MainActor
    func modelResolvesGuestFlowAndLoadsPlayerRequest() async {
        let fixture = GuestFixtures()
        let player = RecordingPlayerEngine()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: GuestRepositoryStub(fixtures: fixture)
            ),
            playback: player
        )

        model.loadVideo(fixture.detail.bvid)
        await model.waitForCurrentTask()

        let context = GuestVideoContext(
            detail: fixture.detail,
            pages: [fixture.page],
            selectedPage: fixture.page,
            playback: fixture.playback
        )
        #expect(model.state == .ready(context))
        #expect(model.presentedContext == context)
        #expect(player.loadedPlaybacks == [fixture.playback])
        #expect(
            player.loadedIdentities == [
                PlaybackItemIdentity(
                    bvid: fixture.detail.bvid,
                    cid: fixture.page.cid
                )
            ]
        )
    }

    @Test
    @MainActor
    func resettingVideoLoadClearsDetailAndStopsPlayer() async {
        let fixture = GuestFixtures()
        let player = RecordingPlayerEngine()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: GuestRepositoryStub(fixtures: fixture)
            ),
            playback: player
        )

        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()
        model.reset()

        #expect(model.state == .idle)
        #expect(model.presentedContext == nil)
        #expect(player.stopCallCount == 1)
    }

    @Test
    @MainActor
    func playbackFailureRetainsTheNewPresentedContext() async {
        let first = GuestFixtures(bvid: "BV1PresentedA", title: "视频 A")
        let replacement = GuestFixtures(
            bvid: "BV1PresentedB",
            title: "视频 B"
        )
        let repository = VideoOutcomeRepositoryStub(
            fixtures: [first, replacement]
        )
        let player = SelectiveFailingPlayerEngine(
            failingBVID: replacement.bvid
        )
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: player
        )

        model.loadVideo(first.bvid)
        await model.waitForCurrentTask()
        #expect(model.presentedContext?.detail.bvid == first.bvid)

        model.loadVideo(replacement.bvid)
        await model.waitForCurrentTask()

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
        let first = GuestFixtures(bvid: "BV1CancelA", title: "视频 A")
        let cancelled = GuestFixtures(bvid: "BV1CancelB", title: "视频 B")
        let repository = VideoOutcomeRepositoryStub(
            fixtures: [first, cancelled],
            cancelledBVID: cancelled.bvid
        )
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )

        model.loadVideo(first.bvid)
        await model.waitForCurrentTask()
        #expect(model.presentedContext?.detail.bvid == first.bvid)

        model.loadVideo(cancelled.bvid)
        #expect(model.presentedContext?.detail.bvid == first.bvid)
        await model.waitForCurrentTask()

        #expect(model.state == .idle)
        #expect(model.presentedContext == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func newerVideoLoadPreventsOldVideoFromLoadingPlayer() async throws {
        let slow = GuestFixtures(bvid: "BV1SlowFixture", title: "旧视频")
        let fast = GuestFixtures(bvid: "BV1FastFixture", title: "新视频")
        let player = RecordingPlayerEngine()
        let repository = SwitchingGuestRepositoryStub(slow: slow, fast: fast)
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: repository
            ),
            playback: player
        )

        model.loadVideo(slow.detail.bvid)
        try await repository.waitForSlowRequestCount(2)
        let supersededTask = try #require(model.taskSnapshotForTesting())
        model.loadVideo(fast.detail.bvid)
        await model.waitForCurrentTask()
        await repository.releaseSlowRequests()
        await supersededTask.value

        guard case .ready(let context) = model.state else {
            Issue.record("最新视频未进入就绪状态")
            return
        }
        #expect(context.detail.bvid == fast.detail.bvid)
        #expect(model.presentedContext?.detail.bvid == fast.detail.bvid)
        #expect(player.loadedPlaybacks.count == 1)
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
        let fixture = GuestFixtures()
        let repository = PartSwitchRepositoryStub(fixtures: fixture)
        let player = RecordingPlayerEngine()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: player
        )

        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()
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
        await model.waitForCurrentTask()

        #expect(model.presentedContext?.selectedPage.cid == 900_002)
        #expect(model.presentedPlaybackIdentity == secondIdentity)
        #expect(player.loadedIdentities == [firstIdentity, secondIdentity])
        #expect(player.stopCallCount == 1)

        model.selectPage(cid: 900_002)
        #expect(player.loadedIdentities == [firstIdentity, secondIdentity])
        model.reset()
        #expect(model.presentedContext == nil)
        #expect(model.requestedPlaybackIdentity == nil)
        #expect(model.presentedPlaybackIdentity == nil)
        #expect(player.stopCallCount == 2)
    }

    @Test
    @MainActor
    func failedPageSelectionRetriesOnlyTheTargetCID() async {
        let fixture = GuestFixtures()
        let repository = PartSwitchRepositoryStub(
            fixtures: fixture,
            failingCIDOnce: 900_002
        )
        let player = RecordingPlayerEngine()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: player
        )
        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()

        model.selectPage(cid: 900_002)
        await model.waitForCurrentTask()
        guard case .failedPage(_, let targetPage, .content) = model.state else {
            Issue.record("目标分 P 未进入内容失败状态")
            return
        }
        #expect(targetPage.cid == 900_002)
        #expect(model.presentedPlaybackIdentity == nil)
        #expect(model.requestedPlaybackIdentity?.cid == 900_002)

        model.retry()
        await model.waitForCurrentTask()

        #expect(model.presentedContext?.selectedPage.cid == 900_002)
        #expect(model.presentedPlaybackIdentity?.cid == 900_002)
        #expect(await repository.playbackCIDs() == [900_001, 900_002, 900_002])
        #expect(player.loadedIdentities.map(\.cid) == [900_001, 900_002])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func postReadyFailureClearsPresentedIdentityAndRetriesCurrentCID()
        async throws
    {
        let fixture = GuestFixtures()
        let repository = PartSwitchRepositoryStub(fixtures: fixture)
        let player = PostReadyFailurePlayer()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: player
        )
        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()
        let identity = try #require(model.presentedPlaybackIdentity)

        player.fail(identity)
        await player.waitForStopCallCount(1)

        guard case .failedPage(_, let targetPage, .playback) = model.state else {
            Issue.record("ready 后失败未进入当前 CID 的失败状态")
            return
        }
        #expect(targetPage.cid == identity.cid)
        #expect(model.requestedPlaybackIdentity == identity)
        #expect(model.presentedPlaybackIdentity == nil)

        model.retry()
        await model.waitForCurrentTask()

        #expect(model.presentedPlaybackIdentity == identity)
        #expect(player.loadedIdentities == [identity, identity])
        #expect(player.stopCallCount == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func failureBeforeLoadReturnsCannotRestoreReadyState() async throws {
        let fixture = GuestFixtures()
        let repository = PartSwitchRepositoryStub(fixtures: fixture)
        let player = FailureBeforeLoadReturnsPlayer()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: player
        )

        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()
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
        await model.waitForCurrentTask()

        #expect(model.presentedPlaybackIdentity == identity)
        #expect(player.loadedIdentities == [identity, identity])
        #expect(player.stopCallCount == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func delayedOldSameCIDFailureCannotStopNewABAIntent() async throws {
        let fixture = GuestFixtures()
        let repository = PartSwitchRepositoryStub(fixtures: fixture)
        let player = DelayedABAPlayback()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: player
        )

        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()
        let firstIdentity = PlaybackItemIdentity(
            bvid: fixture.bvid,
            cid: 900_001
        )
        let oldIntent = try #require(player.loadedIntents.first)

        model.selectPage(cid: 900_002)
        await model.waitForCurrentTask()
        model.selectPage(cid: 900_001)
        await player.waitForThirdLoad()

        await player.publishFailure(
            PlaybackFailureEvent(identity: firstIdentity, intent: oldIntent)
        )
        await player.waitForFailureRequestCount(2)
        guard case .preparingPlayback = model.state else {
            Issue.record("旧 A failure 错误停止了新 A intent")
            return
        }
        #expect(player.stopCallCount == 2)

        player.releaseThirdLoad()
        await model.waitForCurrentTask()
        await player.finishFailures()

        #expect(model.presentedPlaybackIdentity == firstIdentity)
        #expect(player.loadedIdentities.map(\.cid) == [900_001, 900_002, 900_001])
        #expect(player.loadedIntents[0] != player.loadedIntents[2])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func rapidPageABARejectsTheLateSupersededResult() async throws {
        let fixture = GuestFixtures()
        let repository = ABAPartRepositoryStub(fixtures: fixture)
        let player = RecordingPlayerEngine()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: player
        )
        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()

        model.selectPage(cid: 900_002)
        try await repository.waitForRequest(cid: 900_002)
        let supersededP2 = try #require(model.taskSnapshotForTesting())

        model.selectPage(cid: 900_001)
        try await repository.waitForRequest(cid: 900_001)
        await repository.release(cid: 900_001)
        await model.waitForCurrentTask()
        await repository.release(cid: 900_002)
        await supersededP2.value

        #expect(model.presentedContext?.selectedPage.cid == 900_001)
        #expect(model.presentedPlaybackIdentity?.cid == 900_001)
        #expect(player.loadedIdentities.map(\.cid) == [900_001, 900_001])
        #expect(player.stopCallCount == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func relatedVideoABARejectsOldSameBVIDResult() async throws {
        let fixture = GuestFixtures()
        let relatedRepository = RelatedVideoABARepositoryStub()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: GuestRepositoryStub(fixtures: fixture)
            ),
            playback: RecordingPlayerEngine(),
            relatedVideoUseCase: RelatedVideoUseCase(
                repository: relatedRepository
            )
        )

        model.loadVideo("BV1RelatedAA")
        try await relatedRepository.waitForRequestCount(1)
        let oldA = try #require(model.relatedVideoTaskSnapshotForTesting())
        model.loadVideo("BV1RelatedBB")
        try await relatedRepository.waitForRequestCount(2)
        model.loadVideo("BV1RelatedAA")
        try await relatedRepository.waitForRequestCount(3)

        let newResult = RelatedVideo.testFixture(bvid: "BV1CurrentAA1")
        await relatedRepository.releaseRequest(2, videos: [newResult])
        await model.waitForCurrentRelatedVideoTask()
        #expect(
            model.relatedVideoState
                == .loaded(bvid: "BV1RelatedAA", videos: [newResult])
        )

        await relatedRepository.releaseRequest(
            0,
            videos: [.testFixture(bvid: "BV1StaleAAA1")]
        )
        await oldA.value
        await relatedRepository.releaseRequest(1, videos: [])

        #expect(
            model.relatedVideoState
                == .loaded(bvid: "BV1RelatedAA", videos: [newResult])
        )
    }

    @Test
    @MainActor
    func relatedVideoFailureRetriesWithoutReloadingPlayback() async {
        let fixture = GuestFixtures()
        let relatedRepository = RetryingRelatedVideoRepositoryStub()
        let player = RecordingPlayerEngine()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: GuestRepositoryStub(fixtures: fixture)
            ),
            playback: player,
            relatedVideoUseCase: RelatedVideoUseCase(
                repository: relatedRepository
            )
        )

        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()
        await model.waitForCurrentRelatedVideoTask()
        #expect(
            model.relatedVideoState
                == .failed(bvid: fixture.bvid, error: .transportFailure)
        )

        model.retryRelatedVideos()
        await model.waitForCurrentRelatedVideoTask()

        #expect(
            model.relatedVideoState
                == .loaded(
                    bvid: fixture.bvid,
                    videos: [.testFixture(bvid: "BV1RetryVid1")]
                )
        )
        #expect(player.loadedPlaybacks.count == 1)
        #expect(await relatedRepository.callCount == 2)
    }
}

private actor RelatedVideoABARepositoryStub: RelatedVideoRepository {
    private var continuations: [CheckedContinuation<[RelatedVideo], Never>?] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func relatedVideos(to bvid: String) async throws -> [RelatedVideo] {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            let waiters = requestWaiters
            requestWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitForRequestCount(_ count: Int) async throws {
        while continuations.count < count {
            await withCheckedContinuation { continuation in
                requestWaiters.append(continuation)
            }
        }
    }

    func releaseRequest(_ index: Int, videos: [RelatedVideo]) {
        continuations[index]?.resume(returning: videos)
        continuations[index] = nil
    }
}

private actor RetryingRelatedVideoRepositoryStub: RelatedVideoRepository {
    private(set) var callCount = 0

    func relatedVideos(to bvid: String) async throws -> [RelatedVideo] {
        callCount += 1
        guard callCount > 1 else {
            throw GuestApplicationError.transportFailure
        }
        return [.testFixture(bvid: "BV1RetryVid1")]
    }
}

extension RelatedVideo {
    fileprivate static func testFixture(bvid: String) -> RelatedVideo {
        RelatedVideo(
            bvid: bvid,
            title: "合成相关推荐",
            coverURL: nil,
            ownerName: "测试作者",
            viewCount: 100,
            danmakuCount: 10,
            durationSeconds: 120
        )
    }
}

private actor WorksetRepositoryStub: GuestContentRepository {
    let fixtures: GuestFixtures
    private(set) var popularCallCount = 0
    private(set) var searchCallCount = 0
    private var shouldFailNextPopular = false

    init(fixtures: GuestFixtures) {
        self.fixtures = fixtures
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        popularCallCount += 1
        if shouldFailNextPopular {
            shouldFailNextPopular = false
            throw GuestApplicationError.requestRestricted
        }
        return PopularPage(
            videos: [fixtures.popularVideo],
            pageNumber: page,
            pageSize: pageSize
        )
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        searchCallCount += 1
        return SearchPage(
            videos: [fixtures.searchVideo],
            pageNumber: page,
            pageSize: 20,
            totalResults: 1,
            totalPages: 1
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        fixtures.detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [fixtures.page]
    }

    func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        fixtures.playback
    }

    func failNextPopularRequest() {
        shouldFailNextPopular = true
    }
}

private struct GuestFixtures: Sendable {
    let bvid: String
    let title: String
    let owner = VideoOwner(id: 10_001, name: "测试 UP 主")

    init(
        bvid: String = "BV1FixtureA1",
        title: String = "测试视频"
    ) {
        self.bvid = bvid
        self.title = title
    }

    var popularVideo: PopularVideo {
        PopularVideo(
            bvid: bvid,
            title: title,
            coverURL: nil,
            owner: owner,
            statistics: VideoStatistics(viewCount: 10, danmakuCount: 2, likeCount: 3),
            durationSeconds: 120,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    var detail: VideoDetail {
        VideoDetail(
            bvid: popularVideo.bvid,
            title: popularVideo.title,
            summary: "脱敏详情",
            coverURL: nil,
            owner: owner,
            statistics: popularVideo.statistics,
            durationSeconds: popularVideo.durationSeconds,
            publishedAt: popularVideo.publishedAt
        )
    }

    var searchVideo: SearchVideo {
        SearchVideo(
            bvid: bvid,
            title: title,
            coverURL: nil,
            owner: owner,
            statistics: popularVideo.statistics,
            durationSeconds: popularVideo.durationSeconds,
            publishedAt: popularVideo.publishedAt
        )
    }

    let page = VideoPage(
        cid: 900_001,
        index: 1,
        title: "P1",
        durationSeconds: 120
    )

    var playback: VideoPlayback {
        VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: [],
                audioRepresentations: []
            ),
            mediaHeaders: [
                "Referer": "https://www.bilibili.com/video/\(bvid)/",
                "User-Agent": "BiliKitMacTests",
            ]
        )
    }
}

private actor GuestRepositoryStub: GuestContentRepository {
    let fixtures: GuestFixtures

    init(fixtures: GuestFixtures) {
        self.fixtures = fixtures
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(
            videos: [fixtures.popularVideo],
            pageNumber: page,
            pageSize: pageSize
        )
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        SearchPage(
            videos: [fixtures.searchVideo],
            pageNumber: page,
            pageSize: 20,
            totalResults: 1,
            totalPages: 1
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        fixtures.detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [fixtures.page]
    }

    func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        fixtures.playback
    }
}

private actor PartSwitchRepositoryStub: GuestContentRepository {
    let fixtures: GuestFixtures
    private var failingCIDOnce: Int64?
    private var observedPlaybackCIDs: [Int64] = []

    init(fixtures: GuestFixtures, failingCIDOnce: Int64? = nil) {
        self.fixtures = fixtures
        self.failingCIDOnce = failingCIDOnce
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [], pageNumber: page, pageSize: pageSize)
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        SearchPage(
            videos: [],
            pageNumber: page,
            pageSize: 20,
            totalResults: 0,
            totalPages: 0
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        fixtures.detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [
            fixtures.page,
            VideoPage(
                cid: 900_002,
                index: 2,
                title: "P2",
                durationSeconds: 180
            ),
        ]
    }

    func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        observedPlaybackCIDs.append(cid)
        if failingCIDOnce == cid {
            failingCIDOnce = nil
            throw GuestApplicationError.transportFailure
        }
        return fixtures.playback
    }

    func playbackCIDs() -> [Int64] {
        observedPlaybackCIDs
    }
}

private actor ABAPartRepositoryStub: GuestContentRepository {
    let fixtures: GuestFixtures
    private var initialRequestCompleted = false
    private var requestEvents: [Int64: TestEventCounter] = [:]
    private var waiters: [Int64: [CheckedContinuation<Void, Never>]] = [:]

    init(fixtures: GuestFixtures) {
        self.fixtures = fixtures
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [], pageNumber: page, pageSize: pageSize)
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        SearchPage(
            videos: [],
            pageNumber: page,
            pageSize: 20,
            totalResults: 0,
            totalPages: 0
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        fixtures.detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [
            fixtures.page,
            VideoPage(
                cid: 900_002,
                index: 2,
                title: "P2",
                durationSeconds: 180
            ),
        ]
    }

    func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        if !initialRequestCompleted {
            initialRequestCompleted = true
            return fixtures.playback
        }
        let event = requestEvents[cid] ?? TestEventCounter()
        requestEvents[cid] = event
        await event.signal()
        await withCheckedContinuation { continuation in
            waiters[cid, default: []].append(continuation)
        }
        return fixtures.playback
    }

    func waitForRequest(cid: Int64) async throws {
        let event = requestEvents[cid] ?? TestEventCounter()
        requestEvents[cid] = event
        try await event.wait(until: 1)
    }

    func release(cid: Int64) {
        let pending = waiters.removeValue(forKey: cid) ?? []
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor VideoOutcomeRepositoryStub: GuestContentRepository {
    private let fixturesByBVID: [String: GuestFixtures]
    private let cancelledBVID: String?

    init(
        fixtures: [GuestFixtures],
        cancelledBVID: String? = nil
    ) {
        fixturesByBVID = Dictionary(
            uniqueKeysWithValues: fixtures.map { ($0.bvid, $0) }
        )
        self.cancelledBVID = cancelledBVID
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [], pageNumber: page, pageSize: pageSize)
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        SearchPage(
            videos: [],
            pageNumber: page,
            pageSize: 20,
            totalResults: 0,
            totalPages: 0
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        if bvid == cancelledBVID {
            throw CancellationError()
        }
        return try fixture(for: bvid).detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [try fixture(for: bvid).page]
    }

    func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        try fixture(for: bvid).playback
    }

    private func fixture(for bvid: String) throws -> GuestFixtures {
        guard let fixture = fixturesByBVID[bvid] else {
            throw GuestApplicationError.invalidResponse
        }
        return fixture
    }
}

private actor FeedSwitchingRepositoryStub: GuestContentRepository {
    let fixtures: GuestFixtures
    private var searchReleased = false
    private let searchEvents = TestEventCounter()
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(fixtures: GuestFixtures) {
        self.fixtures = fixtures
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(
            videos: [fixtures.popularVideo],
            pageNumber: page,
            pageSize: pageSize
        )
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        await searchEvents.signal()
        await withCheckedContinuation { continuation in
            if searchReleased {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
        return SearchPage(
            videos: [fixtures.searchVideo],
            pageNumber: page,
            pageSize: 20,
            totalResults: 1,
            totalPages: 1
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        fixtures.detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [fixtures.page]
    }

    func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        fixtures.playback
    }

    func waitForSearchStart() async throws {
        do {
            try await searchEvents.wait(until: 1)
        } catch {
            releaseSearch()
            throw error
        }
    }

    func releaseSearch() {
        searchReleased = true
        resume(&releaseWaiters)
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor RetryingSearchRepositoryStub: GuestContentRepository {
    let fixtures: GuestFixtures
    private var searchAttempts = 0

    init(fixtures: GuestFixtures) {
        self.fixtures = fixtures
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(
            videos: [fixtures.popularVideo],
            pageNumber: page,
            pageSize: pageSize
        )
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        searchAttempts += 1
        if searchAttempts == 1 {
            throw GuestApplicationError.requestRestricted
        }
        return SearchPage(
            videos: [fixtures.searchVideo],
            pageNumber: page,
            pageSize: 20,
            totalResults: 1,
            totalPages: 1
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        fixtures.detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [fixtures.page]
    }

    func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        fixtures.playback
    }
}

private actor SwitchingGuestRepositoryStub: GuestContentRepository {
    let slow: GuestFixtures
    let fast: GuestFixtures
    private var slowRequestsReleased = false
    private let slowRequestEvents = TestEventCounter()
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(slow: GuestFixtures, fast: GuestFixtures) {
        self.slow = slow
        self.fast = fast
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [fast.popularVideo], pageNumber: page, pageSize: pageSize)
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        SearchPage(
            videos: [],
            pageNumber: page,
            pageSize: 20,
            totalResults: 0,
            totalPages: 0
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        try await delayIfSlow(bvid)
        return fixture(for: bvid).detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        try await delayIfSlow(bvid)
        return [fixture(for: bvid).page]
    }

    func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        fixture(for: bvid).playback
    }

    private func delayIfSlow(_ bvid: String) async throws {
        guard bvid == slow.bvid else { return }
        await slowRequestEvents.signal()
        await withCheckedContinuation { continuation in
            if slowRequestsReleased {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    private func fixture(for bvid: String) -> GuestFixtures {
        bvid == slow.bvid ? slow : fast
    }

    func waitForSlowRequestCount(_ expectedCount: Int) async throws {
        do {
            try await slowRequestEvents.wait(until: expectedCount)
        } catch {
            releaseSlowRequests()
            throw error
        }
    }

    func releaseSlowRequests() {
        slowRequestsReleased = true
        let pending = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor TestEventCounter {
    private struct Waiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var count = 0
    private var waiters: [UUID: Waiter] = [:]

    func signal() {
        count += 1
        let ready = waiters.filter { count >= $0.value.expectedCount }
        for (id, waiter) in ready where waiters.removeValue(forKey: id) != nil {
            waiter.continuation.resume()
        }
    }

    func wait(until expectedCount: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if count >= expectedCount {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = Waiter(
                        expectedCount: expectedCount,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}

@MainActor
private final class RecordingPlayerEngine: PlaybackControlling {
    private(set) var loadedPlaybacks: [VideoPlayback] = []
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var pauseCallCount = 0
    private(set) var stopCallCount = 0

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        finishedPlaybackFailureEvents()
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        loadedPlaybacks.append(playback)
        loadedIdentities.append(identity)
    }

    func pause() {
        pauseCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }
}

@MainActor
private final class SelectiveFailingPlayerEngine: PlaybackControlling {
    let failingBVID: String

    init(failingBVID: String) {
        self.failingBVID = failingBVID
    }

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        finishedPlaybackFailureEvents()
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        if identity.bvid == failingBVID {
            throw SelectivePlaybackFailure()
        }
    }

    func pause() {}

    func stop() {}
}

@MainActor
private final class PostReadyFailurePlayer: PlaybackControlling {
    private struct StopWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let failures: AsyncStream<PlaybackFailureEvent>
    private let failureContinuation: AsyncStream<PlaybackFailureEvent>.Continuation
    private var stopWaiters: [StopWaiter] = []
    private var loadedIntents: [PlaybackItemIdentity: PlaybackLoadIntent] = [:]
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCallCount = 0

    init() {
        let stream = AsyncStream<PlaybackFailureEvent>.makeStream()
        failures = stream.stream
        failureContinuation = stream.continuation
    }

    deinit {
        failureContinuation.finish()
    }

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        failures
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        loadedIdentities.append(identity)
        loadedIntents[identity] = intent
    }

    func pause() {}

    func stop() {
        stopCallCount += 1
        let ready = stopWaiters.filter {
            stopCallCount >= $0.expectedCount
        }
        stopWaiters.removeAll {
            stopCallCount >= $0.expectedCount
        }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func fail(_ identity: PlaybackItemIdentity) {
        guard let intent = loadedIntents[identity] else { return }
        failureContinuation.yield(
            PlaybackFailureEvent(identity: identity, intent: intent)
        )
    }

    func waitForStopCallCount(_ expectedCount: Int) async {
        guard stopCallCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append(
                StopWaiter(
                    expectedCount: expectedCount,
                    continuation: continuation
                )
            )
        }
    }
}

@MainActor
private final class FailureBeforeLoadReturnsPlayer: PlaybackControlling {
    private let failures: AsyncStream<PlaybackFailureEvent>
    private let failureContinuation: AsyncStream<PlaybackFailureEvent>.Continuation
    private var blockedLoad: CheckedContinuation<Void, Never>?
    private var shouldFailNextLoad = true
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCallCount = 0

    init() {
        let stream = AsyncStream<PlaybackFailureEvent>.makeStream()
        failures = stream.stream
        failureContinuation = stream.continuation
    }

    deinit {
        failureContinuation.finish()
    }

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        failures
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        loadedIdentities.append(identity)
        guard shouldFailNextLoad else { return }
        shouldFailNextLoad = false
        failureContinuation.yield(
            PlaybackFailureEvent(identity: identity, intent: intent)
        )
        await withCheckedContinuation { continuation in
            blockedLoad = continuation
        }
    }

    func pause() {}

    func stop() {
        stopCallCount += 1
        blockedLoad?.resume()
        blockedLoad = nil
    }
}

@MainActor
private final class DelayedABAPlayback: PlaybackControlling {
    private let failureSource: FailureEventSource
    private let failures: AsyncStream<PlaybackFailureEvent>
    private var thirdLoadContinuation: CheckedContinuation<Void, Never>?
    private var thirdLoadWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var loadedIntents: [PlaybackLoadIntent] = []
    private(set) var stopCallCount = 0

    init() {
        let source = FailureEventSource()
        failureSource = source
        failures = AsyncStream(unfolding: {
            await source.next()
        })
    }

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        failures
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        loadedIdentities.append(identity)
        loadedIntents.append(intent)
        guard loadedIdentities.count == 3 else { return }
        let waiters = thirdLoadWaiters
        thirdLoadWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            thirdLoadContinuation = continuation
        }
    }

    func pause() {}

    func stop() {
        stopCallCount += 1
    }

    func waitForThirdLoad() async {
        guard loadedIdentities.count < 3 else { return }
        await withCheckedContinuation { continuation in
            thirdLoadWaiters.append(continuation)
        }
    }

    func releaseThirdLoad() {
        thirdLoadContinuation?.resume()
        thirdLoadContinuation = nil
    }

    func publishFailure(_ event: PlaybackFailureEvent) async {
        await failureSource.send(event)
    }

    func waitForFailureRequestCount(_ expectedCount: Int) async {
        await failureSource.waitForRequestCount(expectedCount)
    }

    func finishFailures() async {
        await failureSource.finish()
    }
}

private actor FailureEventSource {
    private var queuedEvents: [PlaybackFailureEvent] = []
    private var pendingNext: CheckedContinuation<PlaybackFailureEvent?, Never>?
    private var requestCount = 0
    private var requestWaiters:
        [(expectedCount: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isFinished = false

    func next() async -> PlaybackFailureEvent? {
        requestCount += 1
        resumeSatisfiedRequestWaiters()
        if !queuedEvents.isEmpty {
            return queuedEvents.removeFirst()
        }
        guard !isFinished else { return nil }
        return await withCheckedContinuation { continuation in
            pendingNext = continuation
        }
    }

    func send(_ event: PlaybackFailureEvent) {
        guard !isFinished else { return }
        if let pendingNext {
            self.pendingNext = nil
            pendingNext.resume(returning: event)
        } else {
            queuedEvents.append(event)
        }
    }

    func waitForRequestCount(_ expectedCount: Int) async {
        guard requestCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((expectedCount, continuation))
        }
    }

    func finish() {
        isFinished = true
        queuedEvents.removeAll()
        pendingNext?.resume(returning: nil)
        pendingNext = nil
    }

    private func resumeSatisfiedRequestWaiters() {
        let satisfied = requestWaiters.filter {
            requestCount >= $0.expectedCount
        }
        requestWaiters.removeAll {
            requestCount >= $0.expectedCount
        }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}

private struct SelectivePlaybackFailure: Error {}

private func finishedPlaybackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
    AsyncStream { continuation in
        continuation.finish()
    }
}
