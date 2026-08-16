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
    @Test(arguments: [
        GuestApplicationError.authenticationInvalid,
        .authenticationUnavailable,
        .requestRestricted,
    ])
    @MainActor
    func onlyInvalidAuthenticationRequestsAppRevalidation(
        error: GuestApplicationError
    ) async {
        let fixture = GuestFixtures()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: PlaybackFailureRepositoryStub(
                    fixtures: fixture,
                    error: error
                )
            ),
            playback: RecordingPlayerEngine()
        )

        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()

        #expect(
            model.authenticationRevalidationGeneration
                == (error == .authenticationInvalid ? 1 : 0)
        )
        #expect(
            model.state
                == GuestVideoState.failed(
                    bvid: fixture.bvid,
                    failure: GuestVideoFailure.content(error)
                )
        )
    }

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
    func popularNearEndAppendsDeduplicatesAndBackpressuresSameTail() async {
        let first = GuestFixtures(bvid: "BV1PopularA1", title: "热门第一页")
        let second = GuestFixtures(bvid: "BV1PopularB2", title: "热门第二页")
        let repository = PopularPaginationRepositoryStub(
            first: first,
            second: second
        )
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )
        let request = GuestFeedRequest.popular(page: 1, pageSize: 50)

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        let firstTail = model.popularPagination(for: request)
        #expect(firstTail.canLoadMore)
        #expect(firstTail.tailIdentity?.contains("|1|") == true)

        model.loadMorePopular()
        model.loadMorePopular()
        await model.waitForCurrentTask()

        guard case .loaded(.popular(let page)) = model.state else {
            Issue.record("热门结果应保持 loaded")
            return
        }
        #expect(page.videos.map(\.bvid) == [first.bvid, second.bvid])
        #expect(page.pageNumber == 2)
        #expect(!page.hasMore)
        #expect(await repository.popularCallCount == 2)
        #expect(!model.popularPagination(for: request).canLoadMore)
    }

    @Test
    @MainActor
    func failedPopularAppendKeepsCardsAndRetriesOnlyNextPage() async {
        let first = GuestFixtures(bvid: "BV1PopularC3", title: "保留热门卡片")
        let second = GuestFixtures(bvid: "BV1PopularD4", title: "重试热门追加")
        let repository = PopularPaginationRepositoryStub(
            first: first,
            second: second,
            failFirstSecondPage: true
        )
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )
        let request = GuestFeedRequest.popular(page: 1, pageSize: 50)

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        let loadedState = model.state

        model.loadMorePopular()
        await model.waitForCurrentTask()
        #expect(model.state == loadedState)
        #expect(
            model.popularPagination(for: request).loadMoreError
                == .requestRestricted
        )
        #expect(!model.popularPagination(for: request).canLoadMore)
        #expect(model.popularPagination(for: request).tailIdentity == nil)

        model.retryPopularLoadMore()
        await model.waitForCurrentTask()
        guard case .loaded(.popular(let page)) = model.state else {
            Issue.record("热门重试后应保持 loaded")
            return
        }
        #expect(page.videos.map(\.bvid) == [first.bvid, second.bvid])
        #expect(await repository.popularCallCount == 3)
    }

    @Test
    @MainActor
    func duplicateOnlyPopularPageStopsNonProgressingPagination() async {
        let fixture = GuestFixtures(bvid: "BV1PopularE5", title: "重复热门卡片")
        let repository = DuplicateOnlyPopularRepositoryStub(fixtures: fixture)
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )
        let request = GuestFeedRequest.popular(page: 1, pageSize: 50)

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        model.loadMorePopular()
        await model.waitForCurrentTask()

        guard case .loaded(.popular(let page)) = model.state else {
            Issue.record("全重复分页后应保持 loaded")
            return
        }
        #expect(page.videos.map(\.bvid) == [fixture.bvid])
        #expect(page.pageNumber == 2)
        #expect(!page.hasMore)
        #expect(!model.popularPagination(for: request).canLoadMore)
        #expect(await repository.popularCallCount == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func popularRefreshCancelsAndRejectsLateAppend() async throws {
        let old = GuestFixtures(bvid: "BV1PopularF6", title: "旧热门榜单")
        let fresh = GuestFixtures(bvid: "BV1PopularG7", title: "刷新热门榜单")
        let repository = BlockingPopularAppendRepositoryStub(old: old, fresh: fresh)
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        model.loadMorePopular()
        try await repository.waitForAppendStart()
        let oldAppendTask = try #require(model.taskSnapshotForTesting())

        model.refreshPopular(pageSize: 50)
        await model.waitForCurrentTask()
        await repository.releaseAppend()
        await oldAppendTask.value

        guard case .loaded(.popular(let page)) = model.state else {
            Issue.record("刷新后的热门榜单应保持 loaded")
            return
        }
        #expect(page.videos.map(\.bvid) == [fresh.bvid])
        #expect(page.pageNumber == 1)
        #expect(!page.hasMore)
        #expect(model.popularSuccessfulRefreshGeneration == 1)
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

        model.search("macOS")
        await model.waitForCurrentTask()
        #expect(
            model.state
                == .failed(
                    request: .search(query: "macOS", page: 1),
                    error: .requestRestricted
                )
        )

        model.retry(.search(query: "macOS", page: 1))
        await model.waitForCurrentTask()
        #expect(
            model.state
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
    }

    @Test
    @MainActor
    func searchNearEndAppendsDeduplicatesAndBackpressuresSameTail() async {
        let first = GuestFixtures(bvid: "BV1SearchA01", title: "第一页")
        let second = GuestFixtures(bvid: "BV1SearchB02", title: "第二页")
        let repository = SearchPaginationRepositoryStub(
            first: first,
            second: second
        )
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.search("macOS")
        await model.waitForCurrentTask()
        let firstTail = model.searchPagination(for: "macOS")
        #expect(firstTail.canLoadMore)
        #expect(firstTail.tailIdentity?.contains("|1|") == true)

        model.loadMoreSearch()
        model.loadMoreSearch()
        await model.waitForCurrentTask()

        guard case .loaded(.search(_, let page)) = model.state else {
            Issue.record("搜索结果应保持 loaded")
            return
        }
        #expect(page.videos.map(\.bvid) == [first.bvid, second.bvid])
        #expect(page.pageNumber == 2)
        #expect(await repository.searchCallCount == 2)
        #expect(!model.searchPagination(for: "macOS").canLoadMore)
    }

    @Test
    @MainActor
    func failedSearchAppendKeepsCardsAndRetriesOnlyNextPage() async {
        let first = GuestFixtures(bvid: "BV1SearchC03", title: "保留卡片")
        let second = GuestFixtures(bvid: "BV1SearchD04", title: "重试追加")
        let repository = SearchPaginationRepositoryStub(
            first: first,
            second: second,
            failFirstSecondPage: true
        )
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.search("Swift")
        await model.waitForCurrentTask()
        let loadedState = model.state

        model.loadMoreSearch()
        await model.waitForCurrentTask()
        #expect(model.state == loadedState)
        #expect(
            model.searchPagination(for: "Swift").loadMoreError
                == .transportFailure
        )
        #expect(!model.searchPagination(for: "Swift").canLoadMore)
        #expect(model.searchPagination(for: "Swift").tailIdentity == nil)

        model.retrySearchLoadMore()
        await model.waitForCurrentTask()
        guard case .loaded(.search(_, let page)) = model.state else {
            Issue.record("重试后搜索结果应保持 loaded")
            return
        }
        #expect(page.videos.map(\.bvid) == [first.bvid, second.bvid])
        #expect(await repository.searchCallCount == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func newQueryCancelsAndRejectsLateSearchAppend() async throws {
        let old = GuestFixtures(bvid: "BV1SearchE05", title: "旧查询")
        let fresh = GuestFixtures(bvid: "BV1SearchF06", title: "新查询")
        let repository = BlockingSearchAppendRepositoryStub(old: old, fresh: fresh)
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.search("旧查询")
        await model.waitForCurrentTask()
        model.loadMoreSearch()
        try await repository.waitForOldAppendStart()
        let oldAppendTask = try #require(model.taskSnapshotForTesting())

        model.search("新查询")
        await model.waitForCurrentTask()
        await repository.releaseOldAppend()
        await oldAppendTask.value

        guard case .loaded(.search(let query, let page)) = model.state else {
            Issue.record("新查询应保持 loaded")
            return
        }
        #expect(query == "新查询")
        #expect(page.videos.map(\.bvid) == [fresh.bvid])
        #expect(page.pageNumber == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func authenticationEpochRestartsSearchAndRejectsLateOldResult() async throws {
        let old = GuestFixtures(bvid: "BV1SearchG07", title: "旧账户结果")
        let fresh = GuestFixtures(bvid: "BV1SearchH08", title: "新账户结果")
        let repository = AuthenticationEpochSearchRepositoryStub()
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.search("macOS")
        try await repository.waitForRequestCount(1)
        let oldTask = try #require(model.taskSnapshotForTesting())

        model.synchronizeAuthenticationSession(generation: 1)
        try await repository.waitForRequestCount(2)
        await repository.releaseRequest(1, fixture: fresh)
        await model.waitForCurrentTask()

        model.synchronizeAuthenticationSession(generation: 1)
        await repository.releaseRequest(0, fixture: old)
        await oldTask.value

        guard case .loaded(.search(let query, let page)) = model.state else {
            Issue.record("账户切换后的搜索结果应保持 loaded")
            return
        }
        #expect(query == "macOS")
        #expect(page.videos.map(\.bvid) == [fresh.bvid])
        #expect(await repository.requestCount == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func authenticationEpochRestartsPopularAndRejectsLateOldResult() async throws {
        let old = GuestFixtures(bvid: "BV1PopularOld", title: "旧账户热门")
        let fresh = GuestFixtures(bvid: "BV1PopularNew", title: "新账户热门")
        let repository = AuthenticationEpochPopularRepositoryStub()
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        try await repository.waitForRequestCount(1)
        let oldTask = try #require(model.taskSnapshotForTesting())

        model.synchronizeAuthenticationSession(generation: 1)
        try await repository.waitForRequestCount(2)
        await repository.releaseRequest(1, fixture: fresh)
        await model.waitForCurrentTask()

        model.synchronizeAuthenticationSession(generation: 1)
        await repository.releaseRequest(0, fixture: old)
        await oldTask.value

        guard case .loaded(.popular(let page)) = model.state else {
            Issue.record("账户切换后的热门结果应保持 loaded")
            return
        }
        #expect(page.videos.map(\.bvid) == [fresh.bvid])
        #expect(await repository.requestCount == 2)
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
    func tabRoundTripPreservesAppendedPopularWorkset() async {
        let first = GuestFixtures(bvid: "BV1PopularH8", title: "热门第一页")
        let second = GuestFixtures(bvid: "BV1PopularJ9", title: "热门第二页")
        let repository = PopularPaginationRepositoryStub(
            first: first,
            second: second
        )
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        model.loadMorePopular()
        await model.waitForCurrentTask()

        model.activateSearch("macOS")
        await model.waitForCurrentTask()
        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()

        guard case .loaded(.popular(let page)) = model.state else {
            Issue.record("返回热门时应恢复已追加工作集")
            return
        }
        #expect(page.videos.map(\.bvid) == [first.bvid, second.bvid])
        #expect(page.pageNumber == 2)
        #expect(await repository.popularCallCount == 2)
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
        let successfulRefreshGeneration =
            model.popularSuccessfulRefreshGeneration
        await repository.failNextPopularRequest()

        model.refreshPopular(pageSize: 50)
        #expect(model.state == loadedState)
        #expect(model.isRefreshing)
        await model.waitForCurrentTask()

        #expect(model.state == loadedState)
        #expect(!model.isRefreshing)
        #expect(model.refreshError == .requestRestricted)
        #expect(
            model.popularSuccessfulRefreshGeneration
                == successfulRefreshGeneration
        )
        #expect(await repository.popularCallCount == 2)
    }

    @Test
    @MainActor
    func onlySuccessfulSameQueryRefreshAdvancesSearchGeneration() async {
        let fixture = GuestFixtures()
        let repository = WorksetRepositoryStub(fixtures: fixture)
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.search("macOS")
        await model.waitForCurrentTask()
        #expect(model.searchSuccessfulRefreshGeneration == 0)

        model.search("macOS")
        await model.waitForCurrentTask()
        #expect(model.searchSuccessfulRefreshGeneration == 1)

        await repository.failNextSearchRequest()
        model.search("macOS")
        #expect(model.isRefreshing)
        await model.waitForCurrentTask()

        #expect(model.searchSuccessfulRefreshGeneration == 1)
        #expect(model.refreshError == .requestRestricted)
        #expect(await repository.searchCallCount == 3)
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
        #expect(player.startedIdentities == player.loadedIdentities)
        #expect(player.startedIntents.count == 1)
    }

    @Test
    @MainActor
    func authenticatedResumeSelectsRecordedPartBeforeStartingAndCanRestart()
        async throws
    {
        let fixture = GuestFixtures()
        let resumeToken = PlaybackResumeToken()
        let repository = ResumeRepositoryStub(
            fixtures: fixture,
            metadata: try #require(
                PlaybackResumeMetadata(
                    lastPlayedCID: 900_002,
                    positionMilliseconds: 42_500
                )
            )
        )
        let player = RecordingPlayerEngine(
            startOutcome: .resumed(
                positionSeconds: 42.5,
                token: resumeToken,
                discontinuityGeneration: 3
            ),
            restartSucceeds: true
        )
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: player
        )

        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()

        #expect(model.presentedContext?.selectedPage.cid == 900_002)
        #expect(await repository.playbackCIDs == [900_001, 900_002])
        #expect(player.startedInitialPositions == [42.5])
        #expect(
            model.resumeNotice
                == PlaybackResumeNotice(
                    positionSeconds: 42.5,
                    token: resumeToken
                )
        )

        model.restartFromBeginning()
        await model.waitForResumeActionForTesting()

        #expect(model.resumeNotice == nil)
        #expect(player.restartTokens == [resumeToken])
    }

    @Test
    @MainActor
    func resumePreparationFailureUsesExistingPlaybackRetryState() async {
        let fixture = GuestFixtures()
        let player = RecordingPlayerEngine(
            startOutcome: .preparationFailed
        )
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: GuestRepositoryStub(fixtures: fixture)
            ),
            playback: player
        )

        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()

        #expect(
            model.state
                == .failed(bvid: fixture.bvid, failure: .playback)
        )
        #expect(model.resumeNotice == nil)
    }

    @Test(arguments: [0, 115_000, 120_000, 900_000])
    func zeroCompletedAndOutOfRangeResumePositionsStartAtBeginning(
        positionMilliseconds: Int64
    ) async throws {
        let fixture = GuestFixtures()
        let repository = ResumeRepositoryStub(
            fixtures: fixture,
            metadata: try #require(
                PlaybackResumeMetadata(
                    lastPlayedCID: 900_001,
                    positionMilliseconds: positionMilliseconds
                )
            ),
            includesSecondPage: false
        )

        let context = try await GuestVideoUseCase(
            repository: repository
        ).prepareVideo(bvid: fixture.bvid)

        #expect(context.selectedPage.cid == 900_001)
        #expect(context.resumePositionSeconds == nil)
    }

    @Test
    func explicitPartSelectionDoesNotBounceToServerRecordedPart() async throws {
        let fixture = GuestFixtures()
        let repository = ResumeRepositoryStub(
            fixtures: fixture,
            metadata: try #require(
                PlaybackResumeMetadata(
                    lastPlayedCID: 900_002,
                    positionMilliseconds: 42_500
                )
            )
        )
        let useCase = GuestVideoUseCase(repository: repository)
        let initial = try await useCase.prepareVideo(bvid: fixture.bvid)

        let selected = try await useCase.preparePage(in: initial, cid: 900_002)

        #expect(selected.selectedPage.cid == 900_002)
        #expect(selected.resumePositionSeconds == nil)
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
        // `/view` 先返回后才决定是否需要 pagelist，因此旧请求此时只有 detail 在飞行。
        try await repository.waitForSlowRequestCount(1)
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
        #expect(player.startedIdentities.map(\.cid) == [900_001, 900_002, 900_001])
        #expect(player.startedIntents == player.loadedIntents)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func lateSupersededAuthenticationFailureCannotRequestRevalidation()
        async throws
    {
        let fixture = GuestFixtures()
        let repository = LateAuthenticationFailureRepositoryStub(
            fixtures: fixture
        )
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )
        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()

        model.selectPage(cid: 900_002)
        try await repository.waitForBlockedRequest()
        let supersededTask = try #require(model.taskSnapshotForTesting())
        model.selectPage(cid: 900_001)
        await model.waitForCurrentTask()
        await repository.failBlockedRequest()
        await supersededTask.value

        #expect(model.authenticationRevalidationGeneration == 0)
        #expect(model.presentedPlaybackIdentity?.cid == 900_001)
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

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func uploaderSignatureLoadsWithoutBlockingReadyDetail() async throws {
        let fixture = GuestFixtures()
        let signatureRepository = SequencedUploaderSignatureRepository()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: GuestRepositoryStub(fixtures: fixture)
            ),
            playback: RecordingPlayerEngine(),
            uploaderSignatureUseCase: UploaderSignatureUseCase(
                repository: signatureRepository
            )
        )

        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()
        try await signatureRepository.waitForRequestCount(1)

        #expect(model.presentedContext?.detail == fixture.detail)
        #expect(model.uploaderSignatureState == .loading)

        await signatureRepository.releaseRequest(0, signature: "公开签名")
        await model.waitForCurrentUploaderSignatureTask()

        #expect(model.uploaderSignatureState == .loaded("公开签名"))
    }

    @Test
    @MainActor
    func uploaderSignatureFailureHidesOnlyEnhancement() async {
        let fixture = GuestFixtures()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: GuestRepositoryStub(fixtures: fixture)
            ),
            playback: RecordingPlayerEngine(),
            uploaderSignatureUseCase: UploaderSignatureUseCase(
                repository: FailingUploaderSignatureRepository()
            )
        )

        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()
        await model.waitForCurrentUploaderSignatureTask()

        #expect(
            model.state
                == .ready(
                    GuestVideoContext(
                        detail: fixture.detail,
                        pages: [fixture.page],
                        selectedPage: fixture.page,
                        playback: fixture.playback
                    )
                )
        )
        #expect(model.uploaderSignatureState == .loaded(nil))
    }

    @Test
    @MainActor
    func pageSwitchDoesNotReloadUploaderSignature() async {
        let fixture = GuestFixtures()
        let signatureRepository = CountingUploaderSignatureRepositoryStub()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: PartSwitchRepositoryStub(fixtures: fixture)
            ),
            playback: RecordingPlayerEngine(),
            uploaderSignatureUseCase: UploaderSignatureUseCase(
                repository: signatureRepository
            )
        )

        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()
        await model.waitForCurrentUploaderSignatureTask()
        model.selectPage(cid: 900_002)
        await model.waitForCurrentTask()

        #expect(model.uploaderSignatureState == .loaded("公开签名"))
        #expect(await signatureRepository.callCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func uploaderSignatureABARejectsOldSameOwnerResult() async throws {
        let first = GuestFixtures(bvid: "BV1SignatureA", title: "视频 A")
        let second = GuestFixtures(bvid: "BV1SignatureB", title: "视频 B")
        let signatureRepository = SequencedUploaderSignatureRepository()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: VideoOutcomeRepositoryStub(
                    fixtures: [first, second]
                )
            ),
            playback: RecordingPlayerEngine(),
            uploaderSignatureUseCase: UploaderSignatureUseCase(
                repository: signatureRepository
            )
        )

        model.loadVideo(first.bvid)
        await model.waitForCurrentTask()
        try await signatureRepository.waitForRequestCount(1)
        let oldA = try #require(
            model.uploaderSignatureTaskSnapshotForTesting()
        )

        model.loadVideo(second.bvid)
        await model.waitForCurrentTask()
        try await signatureRepository.waitForRequestCount(2)
        model.loadVideo(first.bvid)
        await model.waitForCurrentTask()
        try await signatureRepository.waitForRequestCount(3)

        await signatureRepository.releaseRequest(2, signature: "新 A 签名")
        await model.waitForCurrentUploaderSignatureTask()
        await signatureRepository.releaseRequest(0, signature: "旧 A 签名")
        await oldA.value
        await signatureRepository.releaseRequest(1, signature: "旧 B 签名")

        #expect(model.presentedContext?.detail.bvid == first.bvid)
        #expect(model.uploaderSignatureState == .loaded("新 A 签名"))
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func resetCancelsAndIsolatesLateUploaderSignature() async throws {
        let fixture = GuestFixtures()
        let signatureRepository = SequencedUploaderSignatureRepository()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: GuestRepositoryStub(fixtures: fixture)
            ),
            playback: RecordingPlayerEngine(),
            uploaderSignatureUseCase: UploaderSignatureUseCase(
                repository: signatureRepository
            )
        )

        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()
        try await signatureRepository.waitForRequestCount(1)
        let cancelledTask = try #require(
            model.uploaderSignatureTaskSnapshotForTesting()
        )
        model.reset()
        await signatureRepository.releaseRequest(0, signature: "迟到签名")
        await cancelledTask.value

        #expect(model.state == .idle)
        #expect(model.presentedContext == nil)
        #expect(model.uploaderSignatureState == .loaded(nil))
    }

    @Test
    @MainActor
    func crossBVIDExplicitCIDLoadsOnlyTheAtomicTarget() async {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(fixtures: fixtures)
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )

        model.loadVideo(
            fixtures.episodeBVID,
            preferredCID: fixtures.episodePages[1].cid
        )
        #expect(model.requestedSelectionBVID == fixtures.episodeBVID)
        #expect(model.requestedPreferredCID == fixtures.episodePages[1].cid)
        #expect(model.presentedPlaybackIdentity == nil)
        await model.waitForCurrentTask()

        #expect(model.presentedPlaybackIdentity?.bvid == fixtures.episodeBVID)
        #expect(model.presentedPlaybackIdentity?.cid == fixtures.episodePages[1].cid)
        #expect(await repository.playbackBVIDs() == [fixtures.episodeBVID])
        #expect(await repository.playbackCIDs() == [fixtures.episodePages[1].cid])
    }

    @Test
    @MainActor
    func crossBVIDFailureRetryRetainsExplicitCID() async {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(
            fixtures: fixtures,
            failsFirstEpisodeDetail: true
        )
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )

        model.loadVideo(
            fixtures.episodeBVID,
            preferredCID: fixtures.episodePages[1].cid
        )
        await model.waitForCurrentTask()
        #expect(model.requestedPreferredCID == fixtures.episodePages[1].cid)
        #expect(model.presentedPlaybackIdentity == nil)

        model.retry()
        await model.waitForCurrentTask()

        #expect(model.presentedPlaybackIdentity?.cid == fixtures.episodePages[1].cid)
        #expect(await repository.playbackBVIDs() == [fixtures.episodeBVID])
        #expect(await repository.playbackCIDs() == [fixtures.episodePages[1].cid])
    }

    @Test
    @MainActor
    func unknownEpisodePagesStayPendingThenResolveOneValidatedIntent() async {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(
            fixtures: fixtures,
            blocksEpisodeDetail: true
        )
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )
        model.loadVideo(fixtures.rootBVID)
        await model.waitForCurrentTask()
        var resolved: [(String, Int64?)] = []

        model.selectCollectionEpisode(fixtures.lazyEpisode) {
            resolved.append(($0, $1))
        }
        await repository.waitForEpisodeDetailRequest()

        #expect(model.selectedCollectionEpisode == fixtures.lazyEpisode.id)
        #expect(model.collectionEpisodePageStates[fixtures.lazyEpisode.id] == .loading)
        #expect(resolved.isEmpty)

        await repository.releaseEpisodeDetail()
        await model.waitForCurrentCollectionEpisodeTask()

        #expect(resolved.count == 1)
        #expect(resolved.first?.0 == fixtures.episodeBVID)
        #expect(resolved.first?.1 == fixtures.episodePages.first?.cid)
    }

    @Test
    @MainActor
    func embeddedCollectionPagesLoadWithoutAnotherDetailRequest() async throws {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(fixtures: fixtures)
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )

        model.loadVideo(fixtures.rootBVID)
        await model.waitForCurrentTask()
        var resolvedSelection: (String, Int64?)?
        model.selectCollectionEpisode(fixtures.embeddedEpisode) {
            resolvedSelection = ($0, $1)
        }

        #expect(
            model.collectionEpisodePageStates[fixtures.embeddedEpisode.id]
                == .loaded(bvid: fixtures.rootBVID)
        )
        #expect(
            model.collectionEpisodePages(for: fixtures.embeddedEpisode.id) == fixtures.rootPages
        )
        #expect(await repository.episodeDetailRequestCount() == 0)
        #expect(resolvedSelection?.0 == fixtures.rootBVID)
    }

    @Test
    @MainActor
    func explicitDuplicateBVIDOccurrenceSurvivesContextReconciliation() async {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(fixtures: fixtures)
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )

        model.loadVideo(fixtures.rootBVID)
        await model.waitForCurrentTask()
        model.selectCollectionEpisode(fixtures.rootSummaryEpisode) { _, _ in }
        #expect(model.selectedCollectionEpisode == fixtures.rootSummaryEpisode.id)

        model.loadVideo(
            fixtures.rootBVID,
            preferredCID: fixtures.rootPages[1].cid
        )
        await model.waitForCurrentTask()

        #expect(model.selectedCollectionEpisode == fixtures.rootSummaryEpisode.id)
    }

    @Test
    @MainActor
    func duplicateBVIDEpisodeSelectionsShareOneDetailRequest() async throws {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(
            fixtures: fixtures,
            blocksEpisodeDetail: true
        )
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )

        model.loadVideo(fixtures.rootBVID)
        await model.waitForCurrentTask()
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        model.selectCollectionEpisode(fixtures.duplicateLazyEpisode) { _, _ in }
        await repository.waitForEpisodeDetailRequest()
        await repository.releaseEpisodeDetail()
        await model.waitForCurrentCollectionEpisodeTask()

        #expect(await repository.episodeDetailRequestCount() == 1)
        #expect(
            model.collectionEpisodePageStates[fixtures.lazyEpisode.id] == .idle
        )
        #expect(
            model.collectionEpisodePageStates[fixtures.duplicateLazyEpisode.id]
                == .loaded(bvid: fixtures.episodeBVID)
        )
    }

    @Test
    @MainActor
    func replacingDuplicateBVIDSelectionKeepsTheSharedRequestAlive() async throws {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(
            fixtures: fixtures,
            blocksEpisodeDetail: true
        )
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )

        model.loadVideo(fixtures.rootBVID)
        await model.waitForCurrentTask()
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        await repository.waitForEpisodeDetailRequest()
        model.selectCollectionEpisode(fixtures.duplicateLazyEpisode) { _, _ in }
        await repository.releaseEpisodeDetail()
        await model.waitForCurrentCollectionEpisodeTask()

        #expect(await repository.episodeDetailRequestCount() == 1)
        #expect(
            model.collectionEpisodePageStates[fixtures.lazyEpisode.id]
                == .idle
        )
        #expect(
            model.collectionEpisodePageStates[fixtures.duplicateLazyEpisode.id]
                == .loaded(bvid: fixtures.episodeBVID)
        )
    }

    @Test
    @MainActor
    func replacingDifferentBVIDSelectionStartsANewGeneration() async throws {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(
            fixtures: fixtures,
            blocksEpisodeDetail: true
        )
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )

        model.loadVideo(fixtures.rootBVID)
        await model.waitForCurrentTask()
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        await repository.waitForEpisodeDetailRequest(count: 1)
        model.selectCollectionEpisode(fixtures.thirdLazyEpisode) { _, _ in }
        await repository.waitForEpisodeDetailRequest(count: 2)
        await repository.releaseEpisodeDetail()
        await model.waitForCurrentCollectionEpisodeTask()

        #expect(await repository.episodeDetailRequestCount() == 2)
        #expect(model.selectedCollectionEpisode == fixtures.thirdLazyEpisode.id)
        #expect(
            model.collectionEpisodePageStates[fixtures.thirdLazyEpisode.id]
                == .loaded(bvid: fixtures.thirdBVID)
        )
    }

    @Test
    @MainActor
    func cancelledEpisodeFailureDoesNotRevalidateAuthentication() async throws {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(
            fixtures: fixtures,
            blocksEpisodeDetail: true,
            episodeFailureAfterRelease: .authenticationInvalid
        )
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )

        model.loadVideo(fixtures.rootBVID)
        await model.waitForCurrentTask()
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        await repository.waitForEpisodeDetailRequest()
        let cancelledTask = try #require(
            model.collectionEpisodeTaskSnapshotForTesting()
        )
        model.selectCollectionEpisode(fixtures.embeddedEpisode) { _, _ in }
        await repository.releaseEpisodeDetail()
        await cancelledTask.value

        #expect(model.authenticationRevalidationGeneration == 0)
        #expect(model.collectionEpisodePageStates[fixtures.lazyEpisode.id] == .idle)
    }

    @Test
    @MainActor
    func episodeFailureIsLocalAndRetryCanRecover() async throws {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(
            fixtures: fixtures,
            failsFirstEpisodeDetail: true
        )
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )

        model.loadVideo(fixtures.rootBVID)
        await model.waitForCurrentTask()
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        await model.waitForCurrentCollectionEpisodeTask()

        #expect(
            model.collectionEpisodePageStates[fixtures.lazyEpisode.id]
                == .failed(.transportFailure)
        )
        #expect(model.presentedContext?.detail.bvid == fixtures.rootBVID)

        model.retryCollectionEpisodePages(fixtures.lazyEpisode)
        await model.waitForCurrentCollectionEpisodeTask()

        #expect(
            model.collectionEpisodePageStates[fixtures.lazyEpisode.id]
                == .loaded(bvid: fixtures.episodeBVID)
        )
        #expect(await repository.episodeDetailRequestCount() == 2)
    }

    @Test
    @MainActor
    func resetRejectsLateCollectionEpisodePages() async throws {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(
            fixtures: fixtures,
            blocksEpisodeDetail: true
        )
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )

        model.loadVideo(fixtures.rootBVID)
        await model.waitForCurrentTask()
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        await repository.waitForEpisodeDetailRequest()
        let lateTask = try #require(
            model.collectionEpisodeTaskSnapshotForTesting()
        )

        model.reset()
        await repository.releaseEpisodeDetail()
        await lateTask.value

        #expect(model.selectedCollectionEpisode == nil)
        #expect(model.collectionEpisodePageStates.isEmpty)
        #expect(model.presentedContext == nil)
    }

    @Test
    @MainActor
    func differentBVIDSelectionCancelsOldRequestAndRejectsItsLateResult() async throws {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(
            fixtures: fixtures,
            blocksEpisodeDetail: true
        )
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )

        model.loadVideo(fixtures.rootBVID)
        await model.waitForCurrentTask()
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        await repository.waitForEpisodeDetailRequest(count: 1)
        model.selectCollectionEpisode(fixtures.thirdLazyEpisode) { _, _ in }

        await repository.waitForEpisodeDetailRequest(count: 2)
        #expect(await repository.episodeDetailRequestCount() == 2)
        #expect(model.collectionEpisodePageStates[fixtures.lazyEpisode.id] == .idle)
        #expect(model.collectionEpisodePageStates[fixtures.thirdLazyEpisode.id] == .loading)

        await repository.releaseEpisodeDetail()
        await model.waitForCurrentCollectionEpisodeTask()

        #expect(await repository.episodeDetailRequestCount() == 2)
        #expect(
            model.collectionEpisodePageStates[fixtures.lazyEpisode.id] == .idle
        )
        #expect(
            model.collectionEpisodePageStates[fixtures.thirdLazyEpisode.id]
                == .loaded(bvid: fixtures.thirdBVID)
        )
    }

    @Test
    @MainActor
    func knownEpisodePagesResolveSelectionsWithoutRemoteDetail() async {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(fixtures: fixtures)
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )

        model.loadVideo(fixtures.rootBVID)
        await model.waitForCurrentTask()
        model.selectCollectionEpisode(fixtures.rootSummaryEpisode) { _, _ in }
        model.selectCollectionEpisode(fixtures.embeddedRemoteEpisode) { _, _ in }
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }

        #expect(await repository.episodeDetailRequestCount() == 0)
        #expect(
            model.collectionEpisodePages(for: fixtures.lazyEpisode.id)
                == fixtures.episodePages
        )
    }

    @Test
    @MainActor
    func episodePageCacheEvictsAndReleasesTheThirteenthBVID() async {
        let fixtures = BoundedCollectionCacheFixtures()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: StaticCollectionRepositoryStub(fixtures: fixtures)
            ),
            playback: RecordingPlayerEngine()
        )

        model.loadVideo(fixtures.rootBVID)
        await model.waitForCurrentTask()
        for episode in fixtures.episodes {
            model.selectCollectionEpisode(episode) { _, _ in }
        }

        let first = fixtures.episodes[0]
        let last = fixtures.episodes[12]
        #expect(model.selectedCollectionEpisode == last.id)
        #expect(model.collectionEpisodePageStates[first.id] == .idle)
        #expect(model.collectionEpisodePages(for: first.id) == nil)
        #expect(model.collectionEpisodePageStates[last.id] == .loaded(bvid: last.bvid!))
        #expect(model.collectionEpisodePages(for: last.id) == last.knownPages)
    }
}

private struct BoundedCollectionCacheFixtures: Sendable {
    let rootBVID = "BV1CacheRoot"

    var episodes: [VideoCollectionEpisode] {
        (1...13).map { value in
            let bvid = String(format: "BV1Cache%04d", value)
            let page = VideoPage(
                cid: Int64(930_000 + value),
                index: 1,
                title: "P1",
                durationSeconds: 10
            )
            return VideoCollectionEpisode(
                id: VideoCollectionEpisodeIdentity(
                    seasonID: 801,
                    sectionID: 802,
                    episodeID: Int64(8_100 + value)
                ),
                ordinal: value - 1,
                aid: Int64(9_100 + value),
                bvid: bvid,
                title: "缓存视频 \(value)",
                coverURL: nil,
                durationSeconds: 10,
                defaultCID: page.cid,
                knownPages: [page]
            )
        }
    }

    var detail: VideoDetail {
        let rootPage = VideoPage(
            cid: 939_999,
            index: 1,
            title: "当前 P1",
            durationSeconds: 10
        )
        return VideoDetail(
            bvid: rootBVID,
            title: "缓存边界",
            summary: "脱敏详情",
            coverURL: nil,
            owner: VideoOwner(id: 10_001, name: "测试 UP 主"),
            statistics: VideoStatistics(viewCount: 1, danmakuCount: 1, likeCount: 1),
            durationSeconds: 10,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pages: [rootPage],
            collection: VideoCollection(
                id: 801,
                title: "缓存合集",
                reportedEpisodeCount: 13,
                sections: [
                    VideoCollectionSection(
                        id: VideoCollectionSectionIdentity(
                            seasonID: 801,
                            sectionID: 802
                        ),
                        ordinal: 0,
                        title: "分部",
                        episodes: episodes
                    )
                ]
            )
        )
    }

    var playback: VideoPlayback {
        VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: [],
                originalAudioRepresentations: []
            ),
            mediaHeaders: [:]
        )
    }
}

private actor StaticCollectionRepositoryStub: GuestContentRepository {
    let fixtures: BoundedCollectionCacheFixtures

    init(fixtures: BoundedCollectionCacheFixtures) {
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
        fixtures.detail.pages
    }

    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        fixtures.playback
    }
}

private struct CollectionFixtures: Sendable {
    let rootBVID = "BV1FixtureA1"
    let episodeBVID = "BV1FixtureB2"
    let thirdBVID = "BV1FixtureC3"
    let rootPages = [
        VideoPage(cid: 900_001, index: 1, title: "当前 P1", durationSeconds: 120),
        VideoPage(cid: 900_002, index: 2, title: "当前 P2", durationSeconds: 180),
    ]
    let episodePages = [
        VideoPage(cid: 910_001, index: 1, title: "下一 P1", durationSeconds: 90),
        VideoPage(cid: 910_002, index: 2, title: "下一 P2", durationSeconds: 110),
    ]
    let thirdPages = [
        VideoPage(cid: 920_001, index: 1, title: "第三 P1", durationSeconds: 80)
    ]

    var embeddedEpisode: VideoCollectionEpisode {
        episode(
            episodeID: 701,
            ordinal: 0,
            bvid: rootBVID,
            pages: rootPages
        )
    }

    var lazyEpisode: VideoCollectionEpisode {
        episode(
            episodeID: 702,
            ordinal: 1,
            bvid: episodeBVID,
            pages: nil
        )
    }

    var duplicateLazyEpisode: VideoCollectionEpisode {
        episode(
            episodeID: 703,
            ordinal: 2,
            bvid: episodeBVID,
            pages: nil
        )
    }

    var thirdLazyEpisode: VideoCollectionEpisode {
        episode(episodeID: 704, ordinal: 3, bvid: thirdBVID, pages: nil)
    }

    var rootSummaryEpisode: VideoCollectionEpisode {
        episode(episodeID: 705, ordinal: 4, bvid: rootBVID, pages: nil)
    }

    var embeddedRemoteEpisode: VideoCollectionEpisode {
        episode(episodeID: 706, ordinal: 5, bvid: episodeBVID, pages: episodePages)
    }

    var rootDetail: VideoDetail {
        detail(
            bvid: rootBVID,
            pages: rootPages,
            collection: VideoCollection(
                id: 501,
                title: "测试合集",
                reportedEpisodeCount: 6,
                sections: [
                    VideoCollectionSection(
                        id: VideoCollectionSectionIdentity(
                            seasonID: 501,
                            sectionID: 601
                        ),
                        ordinal: 0,
                        title: "第一章",
                        episodes: [
                            embeddedEpisode,
                            lazyEpisode,
                            duplicateLazyEpisode,
                            thirdLazyEpisode,
                            rootSummaryEpisode,
                            embeddedRemoteEpisode,
                        ]
                    )
                ]
            )
        )
    }

    var episodeDetail: VideoDetail {
        detail(bvid: episodeBVID, pages: episodePages, collection: nil)
    }

    var thirdDetail: VideoDetail {
        detail(bvid: thirdBVID, pages: thirdPages, collection: nil)
    }

    var playback: VideoPlayback {
        VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: [],
                originalAudioRepresentations: []
            ),
            mediaHeaders: [:]
        )
    }

    private func episode(
        episodeID: Int64,
        ordinal: Int,
        bvid: String,
        pages: [VideoPage]?
    ) -> VideoCollectionEpisode {
        VideoCollectionEpisode(
            id: VideoCollectionEpisodeIdentity(
                seasonID: 501,
                sectionID: 601,
                episodeID: episodeID
            ),
            ordinal: ordinal,
            aid: episodeID + 6_000,
            bvid: bvid,
            title: "合集视频 \(ordinal + 1)",
            coverURL: nil,
            durationSeconds: pages?.reduce(0) { $0 + $1.durationSeconds },
            defaultCID: pages?.first?.cid,
            knownPages: pages
        )
    }

    private func detail(
        bvid: String,
        pages: [VideoPage],
        collection: VideoCollection?
    ) -> VideoDetail {
        VideoDetail(
            bvid: bvid,
            title: "详情 \(bvid)",
            summary: "脱敏详情",
            coverURL: nil,
            owner: VideoOwner(id: 10_001, name: "测试 UP 主"),
            statistics: VideoStatistics(
                viewCount: 10,
                danmakuCount: 2,
                likeCount: 3
            ),
            durationSeconds: pages.reduce(0) { $0 + $1.durationSeconds },
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pages: pages,
            collection: collection
        )
    }
}

private actor CollectionEpisodeRepositoryStub: GuestContentRepository {
    let fixtures: CollectionFixtures
    let blocksEpisodeDetail: Bool
    let episodeFailureAfterRelease: GuestApplicationError?
    var failsFirstEpisodeDetail: Bool
    private var episodeRequests = 0
    private var observedPlaybackRequests: [(String, Int64)] = []
    private let episodeRequestEvents = TestEventCounter()
    private var episodeReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        fixtures: CollectionFixtures,
        blocksEpisodeDetail: Bool = false,
        failsFirstEpisodeDetail: Bool = false,
        episodeFailureAfterRelease: GuestApplicationError? = nil
    ) {
        self.fixtures = fixtures
        self.blocksEpisodeDetail = blocksEpisodeDetail
        self.failsFirstEpisodeDetail = failsFirstEpisodeDetail
        self.episodeFailureAfterRelease = episodeFailureAfterRelease
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
        guard bvid != fixtures.rootBVID else {
            return fixtures.rootDetail
        }
        episodeRequests += 1
        await episodeRequestEvents.signal()
        if failsFirstEpisodeDetail {
            failsFirstEpisodeDetail = false
            throw GuestApplicationError.transportFailure
        }
        if blocksEpisodeDetail {
            await withCheckedContinuation { continuation in
                episodeReleaseWaiters.append(continuation)
            }
        }
        if let episodeFailureAfterRelease {
            throw episodeFailureAfterRelease
        }
        return bvid == fixtures.episodeBVID
            ? fixtures.episodeDetail
            : fixtures.thirdDetail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        bvid == fixtures.rootBVID ? fixtures.rootPages : fixtures.episodePages
    }

    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        observedPlaybackRequests.append((bvid, cid))
        return fixtures.playback
    }

    func playbackBVIDs() -> [String] {
        observedPlaybackRequests.map(\.0)
    }

    func playbackCIDs() -> [Int64] {
        observedPlaybackRequests.map(\.1)
    }

    func episodeDetailRequestCount() -> Int {
        episodeRequests
    }

    func waitForEpisodeDetailRequest(count: Int = 1) async {
        try? await episodeRequestEvents.wait(until: count)
    }

    func releaseEpisodeDetail() {
        let waiters = episodeReleaseWaiters
        episodeReleaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct FailingUploaderSignatureRepository:
    UploaderSignatureRepository
{
    func signature(for ownerID: Int64) async throws -> String? {
        throw GuestApplicationError.transportFailure
    }
}

private actor CountingUploaderSignatureRepositoryStub:
    UploaderSignatureRepository
{
    private(set) var callCount = 0

    func signature(for ownerID: Int64) async throws -> String? {
        callCount += 1
        return "公开签名"
    }
}

private actor SequencedUploaderSignatureRepository:
    UploaderSignatureRepository
{
    private var continuations: [CheckedContinuation<String?, Never>?] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func signature(for ownerID: Int64) async throws -> String? {
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

    func releaseRequest(_ index: Int, signature: String?) {
        continuations[index]?.resume(returning: signature)
        continuations[index] = nil
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
    private var shouldFailNextSearch = false

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
        if shouldFailNextSearch {
            shouldFailNextSearch = false
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

    func failNextPopularRequest() {
        shouldFailNextPopular = true
    }

    func failNextSearchRequest() {
        shouldFailNextSearch = true
    }
}

private actor PopularPaginationRepositoryStub: GuestContentRepository {
    let first: GuestFixtures
    let second: GuestFixtures
    let failFirstSecondPage: Bool
    private(set) var popularCallCount = 0
    private var secondPageAttempts = 0

    init(
        first: GuestFixtures,
        second: GuestFixtures,
        failFirstSecondPage: Bool = false
    ) {
        self.first = first
        self.second = second
        self.failFirstSecondPage = failFirstSecondPage
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        popularCallCount += 1
        switch page {
        case 1:
            return PopularPage(
                videos: [first.popularVideo, first.popularVideo],
                pageNumber: 1,
                pageSize: pageSize,
                hasMore: true
            )
        case 2:
            secondPageAttempts += 1
            if failFirstSecondPage, secondPageAttempts == 1 {
                throw GuestApplicationError.requestRestricted
            }
            return PopularPage(
                videos: [first.popularVideo, second.popularVideo],
                pageNumber: 2,
                pageSize: pageSize,
                hasMore: false
            )
        default:
            throw GuestApplicationError.invalidRequest
        }
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

    func videoDetail(for bvid: String) async throws -> VideoDetail { first.detail }
    func pages(for bvid: String) async throws -> [VideoPage] { [first.page] }
    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        first.playback
    }
}

private actor DuplicateOnlyPopularRepositoryStub: GuestContentRepository {
    let fixtures: GuestFixtures
    private(set) var popularCallCount = 0

    init(fixtures: GuestFixtures) {
        self.fixtures = fixtures
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        popularCallCount += 1
        return PopularPage(
            videos: [fixtures.popularVideo],
            pageNumber: page,
            pageSize: pageSize,
            hasMore: true
        )
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

    func videoDetail(for bvid: String) async throws -> VideoDetail { fixtures.detail }
    func pages(for bvid: String) async throws -> [VideoPage] { [fixtures.page] }
    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        fixtures.playback
    }
}

private actor BlockingPopularAppendRepositoryStub: GuestContentRepository {
    let old: GuestFixtures
    let fresh: GuestFixtures
    private let appendEvents = TestEventCounter()
    private var firstPageAttempts = 0
    private var appendReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(old: GuestFixtures, fresh: GuestFixtures) {
        self.old = old
        self.fresh = fresh
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        if page == 2 {
            await appendEvents.signal()
            await withCheckedContinuation { continuation in
                if appendReleased {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
            return PopularPage(
                videos: [old.popularVideo],
                pageNumber: 2,
                pageSize: pageSize,
                hasMore: false
            )
        }
        firstPageAttempts += 1
        let fixture = firstPageAttempts == 1 ? old : fresh
        return PopularPage(
            videos: [fixture.popularVideo],
            pageNumber: 1,
            pageSize: pageSize,
            hasMore: firstPageAttempts == 1
        )
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

    func videoDetail(for bvid: String) async throws -> VideoDetail { fresh.detail }
    func pages(for bvid: String) async throws -> [VideoPage] { [fresh.page] }
    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        fresh.playback
    }

    func waitForAppendStart() async throws {
        try await appendEvents.wait(until: 1)
    }

    func releaseAppend() {
        appendReleased = true
        let pending = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor SearchPaginationRepositoryStub: GuestContentRepository {
    let first: GuestFixtures
    let second: GuestFixtures
    let failFirstSecondPage: Bool
    private(set) var searchCallCount = 0
    private var secondPageAttempts = 0

    init(
        first: GuestFixtures,
        second: GuestFixtures,
        failFirstSecondPage: Bool = false
    ) {
        self.first = first
        self.second = second
        self.failFirstSecondPage = failFirstSecondPage
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [], pageNumber: page, pageSize: pageSize)
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        searchCallCount += 1
        switch page {
        case 1:
            return SearchPage(
                videos: [first.searchVideo, first.searchVideo],
                pageNumber: 1,
                pageSize: 20,
                totalResults: 2,
                totalPages: 2
            )
        case 2:
            secondPageAttempts += 1
            if failFirstSecondPage, secondPageAttempts == 1 {
                throw GuestApplicationError.transportFailure
            }
            return SearchPage(
                videos: [first.searchVideo, second.searchVideo],
                pageNumber: 2,
                pageSize: 20,
                totalResults: 2,
                totalPages: 2
            )
        default:
            throw GuestApplicationError.invalidRequest
        }
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail { first.detail }
    func pages(for bvid: String) async throws -> [VideoPage] { [first.page] }
    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        first.playback
    }
}

private actor AuthenticationEpochSearchRepositoryStub: GuestContentRepository {
    private let requestEvents = TestEventCounter()
    private var continuations: [CheckedContinuation<SearchPage, Never>?] = []

    var requestCount: Int {
        continuations.count
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [], pageNumber: page, pageSize: pageSize)
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        let index = continuations.count
        continuations.append(nil)
        await requestEvents.signal()
        return await withCheckedContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        GuestFixtures().detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [GuestFixtures().page]
    }

    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        GuestFixtures().playback
    }

    func waitForRequestCount(_ count: Int) async throws {
        try await requestEvents.wait(until: count)
    }

    func releaseRequest(_ index: Int, fixture: GuestFixtures) {
        continuations[index]?.resume(
            returning: SearchPage(
                videos: [fixture.searchVideo],
                pageNumber: 1,
                pageSize: 20,
                totalResults: 1,
                totalPages: 1
            )
        )
        continuations[index] = nil
    }
}

private actor AuthenticationEpochPopularRepositoryStub: GuestContentRepository {
    private let requestEvents = TestEventCounter()
    private var continuations: [CheckedContinuation<PopularPage, Never>?] = []

    var requestCount: Int {
        continuations.count
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        let index = continuations.count
        continuations.append(nil)
        await requestEvents.signal()
        return await withCheckedContinuation { continuation in
            continuations[index] = continuation
        }
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
        GuestFixtures().detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [GuestFixtures().page]
    }

    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        GuestFixtures().playback
    }

    func waitForRequestCount(_ count: Int) async throws {
        try await requestEvents.wait(until: count)
    }

    func releaseRequest(_ index: Int, fixture: GuestFixtures) {
        continuations[index]?.resume(
            returning: PopularPage(
                videos: [fixture.popularVideo],
                pageNumber: 1,
                pageSize: 50
            )
        )
        continuations[index] = nil
    }
}

private actor BlockingSearchAppendRepositoryStub: GuestContentRepository {
    let old: GuestFixtures
    let fresh: GuestFixtures
    private let oldAppendEvents = TestEventCounter()
    private var oldAppendReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(old: GuestFixtures, fresh: GuestFixtures) {
        self.old = old
        self.fresh = fresh
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [], pageNumber: page, pageSize: pageSize)
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        if keyword == "旧查询", page == 2 {
            await oldAppendEvents.signal()
            await withCheckedContinuation { continuation in
                if oldAppendReleased {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
            return SearchPage(
                videos: [old.searchVideo],
                pageNumber: 2,
                pageSize: 20,
                totalResults: 2,
                totalPages: 2
            )
        }
        let fixture = keyword == "旧查询" ? old : fresh
        return SearchPage(
            videos: [fixture.searchVideo],
            pageNumber: 1,
            pageSize: 20,
            totalResults: keyword == "旧查询" ? 2 : 1,
            totalPages: keyword == "旧查询" ? 2 : 1
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail { fresh.detail }
    func pages(for bvid: String) async throws -> [VideoPage] { [fresh.page] }
    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        fresh.playback
    }

    func waitForOldAppendStart() async throws {
        try await oldAppendEvents.wait(until: 1)
    }

    func releaseOldAppend() {
        oldAppendReleased = true
        let pending = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
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
                originalAudioRepresentations: []
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

private actor ResumeRepositoryStub: GuestContentRepository {
    let fixtures: GuestFixtures
    let metadata: PlaybackResumeMetadata
    let includesSecondPage: Bool
    private(set) var playbackCIDs: [Int64] = []

    init(
        fixtures: GuestFixtures,
        metadata: PlaybackResumeMetadata,
        includesSecondPage: Bool = true
    ) {
        self.fixtures = fixtures
        self.metadata = metadata
        self.includesSecondPage = includesSecondPage
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
        guard includesSecondPage else { return [fixtures.page] }
        return [
            fixtures.page,
            VideoPage(
                cid: 900_002,
                index: 2,
                title: "P2",
                durationSeconds: 120
            ),
        ]
    }

    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        playbackCIDs.append(cid)
        return VideoPlayback(
            manifest: fixtures.playback.manifest,
            mediaHeaders: fixtures.playback.mediaHeaders,
            resumeMetadata: metadata
        )
    }
}

private actor PlaybackFailureRepositoryStub: GuestContentRepository {
    let fixtures: GuestFixtures
    let error: GuestApplicationError

    init(fixtures: GuestFixtures, error: GuestApplicationError) {
        self.fixtures = fixtures
        self.error = error
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
        [fixtures.page]
    }

    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        throw error
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

private actor LateAuthenticationFailureRepositoryStub: GuestContentRepository {
    let fixtures: GuestFixtures
    private let blockedRequestEvent = TestEventCounter()
    private var blockedRequest: CheckedContinuation<VideoPlayback, any Error>?

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

    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        guard cid == 900_002 else { return fixtures.playback }
        await blockedRequestEvent.signal()
        return try await withCheckedThrowingContinuation { continuation in
            blockedRequest = continuation
        }
    }

    func waitForBlockedRequest() async throws {
        try await blockedRequestEvent.wait(until: 1)
    }

    func failBlockedRequest() {
        blockedRequest?.resume(
            throwing: GuestApplicationError.authenticationInvalid
        )
        blockedRequest = nil
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
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var startedIntents: [PlaybackLoadIntent] = []
    private(set) var startedInitialPositions: [Double?] = []
    private(set) var restartTokens: [PlaybackResumeToken] = []
    private(set) var pauseCallCount = 0
    private(set) var stopCallCount = 0
    private let startOutcome: PlaybackStartOutcome
    private let restartSucceeds: Bool

    init(
        startOutcome: PlaybackStartOutcome = .startedAtBeginning,
        restartSucceeds: Bool = false
    ) {
        self.startOutcome = startOutcome
        self.restartSucceeds = restartSucceeds
    }

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

    func beginPlayback(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        initialPositionSeconds: Double?
    ) async -> PlaybackStartOutcome {
        startedIdentities.append(identity)
        startedIntents.append(intent)
        startedInitialPositions.append(initialPositionSeconds)
        return startOutcome
    }

    func restartFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        resumeToken: PlaybackResumeToken
    ) async -> Bool {
        restartTokens.append(resumeToken)
        return restartSucceeds
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

    func beginPlayback(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        initialPositionSeconds: Double?
    ) async -> PlaybackStartOutcome { .startedAtBeginning }

    func restartFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        resumeToken: PlaybackResumeToken
    ) async -> Bool { false }

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

    func beginPlayback(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        initialPositionSeconds: Double?
    ) async -> PlaybackStartOutcome { .startedAtBeginning }

    func restartFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        resumeToken: PlaybackResumeToken
    ) async -> Bool { false }

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

    func beginPlayback(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        initialPositionSeconds: Double?
    ) async -> PlaybackStartOutcome { .startedAtBeginning }

    func restartFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        resumeToken: PlaybackResumeToken
    ) async -> Bool { false }

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
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var startedIntents: [PlaybackLoadIntent] = []
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

    func beginPlayback(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        initialPositionSeconds: Double?
    ) async -> PlaybackStartOutcome {
        startedIdentities.append(identity)
        startedIntents.append(intent)
        return .startedAtBeginning
    }

    func restartFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        resumeToken: PlaybackResumeToken
    ) async -> Bool { false }

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
