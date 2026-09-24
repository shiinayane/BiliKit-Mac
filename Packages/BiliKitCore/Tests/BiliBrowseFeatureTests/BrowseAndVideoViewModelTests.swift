import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

@Suite(.timeLimit(.minutes(1)))
struct BrowseAndVideoViewModelTests {
    @Test(arguments: [
        ContentApplicationError.authenticationInvalid,
        .authenticationUnavailable,
        .requestRestricted
    ])
    @MainActor
    func onlyInvalidAuthenticationRequestsAppRevalidation(
        error: ContentApplicationError
    ) async {
        let fixture = ContentFixtures()
        let model = VideoViewModel(
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

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func newerPopularRequestPreventsOldSearchFromOverwritingFeed() async throws {
        let fixture = ContentFixtures()
        let searchGate = TestGate()
        let repository = FeedRepositoryStub(
            popular: { request, _ in fixture.popularPage(request) },
            search: { request, _ in
                await searchGate.pass()
                return fixture.searchPage(page: request.page)
            }
        )
        let model = BrowseViewModel(
            useCase: FeedUseCase(
                repository: repository
            )
        )

        model.search(VideoSearchCriteria(query: "旧搜索"))
        try await searchGate.waitForEntries()
        model.refreshPopular()
        try await searchGate.waitForCancellations()
        await model.waitForCurrentTask()
        await searchGate.open()

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
    func recommendationBatchesAppendDeduplicateAndStopWithoutProgress() async {
        let first = ContentFixtures(bvid: "BV1RcmdOneA", title: "推荐一")
        let second = ContentFixtures(bvid: "BV1RcmdTwoB", title: "推荐二")
        let repository = FeedRepositoryStub(recommendations: { continuation, _ in
            let freshIndex = continuation?.freshIndex ?? 1
            let videos: [RecommendedVideo]
            switch freshIndex {
            case 1: videos = [first.recommendedVideo, first.recommendedVideo]
            case 2: videos = [first.recommendedVideo, second.recommendedVideo]
            case 3: videos = [second.recommendedVideo]
            default: throw ContentApplicationError.invalidRequest
            }
            return RecommendationPage(
                videos: videos,
                continuation: RecommendationContinuation(freshIndex: freshIndex),
                nextContinuation: RecommendationContinuation(freshIndex: freshIndex + 1)
            )
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.activateRecommendation()
        await model.waitForCurrentTask()
        #expect(model.pagination(for: .recommendation(continuation: nil)).canLoadMore)

        model.loadMore(.recommendation)
        await model.waitForCurrentTask()
        guard case .loaded(.recommendation(let secondBatch)) = model.state else {
            Issue.record("推荐追加后应保持 loaded")
            return
        }
        #expect(secondBatch.videos.map(\.bvid) == [first.bvid, second.bvid])
        #expect(secondBatch.nextContinuation == RecommendationContinuation(freshIndex: 3))

        model.loadMore(.recommendation)
        await model.waitForCurrentTask()
        guard case .loaded(.recommendation(let finalBatch)) = model.state else {
            Issue.record("全重复推荐批次后应保持 loaded")
            return
        }
        #expect(finalBatch.videos.map(\.bvid) == [first.bvid, second.bvid])
        #expect(finalBatch.nextContinuation == nil)
        #expect(!model.pagination(for: .recommendation(continuation: nil)).canLoadMore)
        #expect(await repository.recommendationRequests.count == 3)
    }

    @Test
    @MainActor
    func recommendationWorksetStopsAtItsRetainedCapacity() async {
        let repository = FeedRepositoryStub(recommendations: { continuation, _ in
            let freshIndex = continuation?.freshIndex ?? 1
            let range = freshIndex == 1 ? 0..<999 : 999..<1_004
            return RecommendationPage(
                videos: range.map { index in
                    ContentFixtures(
                        bvid: "BV-capacity-\(index)",
                        title: "推荐 \(index)"
                    ).recommendedVideo
                },
                continuation: RecommendationContinuation(freshIndex: freshIndex),
                nextContinuation: RecommendationContinuation(freshIndex: freshIndex + 1)
            )
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.activateRecommendation()
        await model.waitForCurrentTask()
        model.loadMore(.recommendation)
        await model.waitForCurrentTask()

        guard case .loaded(.recommendation(let page)) = model.state else {
            Issue.record("推荐达到容量后应保持 loaded")
            return
        }
        #expect(
            page.videos.count
                == BrowseViewModel.maximumRetainedRecommendationVideos
        )
        #expect(page.nextContinuation == nil)
        #expect(!model.pagination(for: .recommendation(continuation: nil)).canLoadMore)
    }

    @Test
    @MainActor
    func recommendationAuthenticationFailureRequestsRevalidation() async {
        let repository = FeedRepositoryStub(recommendations: { _, _ in
            throw ContentApplicationError.authenticationInvalid
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.activateRecommendation()
        await model.waitForCurrentTask()

        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(
            model.state
                == .failed(
                    request: .recommendation(continuation: nil),
                    error: .authenticationInvalid
                )
        )
    }

    @Test
    @MainActor
    func recommendationTailAuthenticationFailureKeepsCardsAndRequestsRevalidation() async {
        let fixture = ContentFixtures(bvid: "BV1AuthRcmd1", title: "认证推荐")
        let repository = FeedRepositoryStub(recommendations: { continuation, _ in
            guard continuation == nil else {
                throw ContentApplicationError.authenticationInvalid
            }
            return fixture.recommendationPage
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.activateRecommendation()
        await model.waitForCurrentTask()
        model.loadMore(.recommendation)
        await model.waitForCurrentTask()

        guard case .loaded(.recommendation(let page)) = model.state else {
            Issue.record("认证失效的推荐追加应保留已有卡片")
            return
        }
        #expect(page.videos.count == 1)
        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(
            model.pagination(for: .recommendation(continuation: nil)).loadMoreError
                == .authenticationInvalid
        )
    }

    @Test
    @MainActor
    func popularAndSearchTailAuthenticationFailuresRequestRevalidation() async {
        let fixture = ContentFixtures(bvid: "BV1AuthTail1", title: "认证追加")
        let repository = FeedRepositoryStub(
            popular: { request, _ in
                guard request.page == 1 else {
                    throw ContentApplicationError.authenticationInvalid
                }
                return PopularPage(
                    videos: [fixture.popularVideo],
                    pageNumber: 1,
                    pageSize: request.pageSize,
                    hasMore: true
                )
            },
            search: { request, _ in
                guard request.page == 1 else {
                    throw ContentApplicationError.authenticationInvalid
                }
                return SearchPage(
                    videos: [fixture.searchVideo],
                    pageNumber: 1,
                    pageSize: VideoSearchCriteria.pageSize,
                    totalResults: 40,
                    totalPages: 2
                )
            }
        )
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        model.loadMore(.popular)
        await model.waitForCurrentTask()
        #expect(model.authenticationRevalidationGeneration == 1)

        model.activateSearch(VideoSearchCriteria(query: "认证"))
        await model.waitForCurrentTask()
        model.loadMore(.search)
        await model.waitForCurrentTask()
        #expect(model.authenticationRevalidationGeneration == 2)
    }

    @Test
    @MainActor
    func duplicateOnlyPopularPageStopsNonProgressingPagination() async {
        let fixture = ContentFixtures(bvid: "BV1PopularE5", title: "重复热门卡片")
        let repository = FeedRepositoryStub(popular: { request, _ in
            fixture.popularPage(request, hasMore: true)
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )
        let request = FeedRequest.popular(page: 1, pageSize: 50)

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        model.loadMore(.popular)
        await model.waitForCurrentTask()

        guard case .loaded(.popular(let page)) = model.state else {
            Issue.record("全重复分页后应保持 loaded")
            return
        }
        #expect(page.videos.map(\.bvid) == [fixture.bvid])
        #expect(page.pageNumber == 2)
        #expect(!page.hasMore)
        #expect(!model.pagination(for: request).canLoadMore)
        #expect(await repository.popularPages.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func popularRefreshCancelsAndRejectsLateAppend() async throws {
        let old = ContentFixtures(bvid: "BV1PopularF6", title: "旧热门榜单")
        let fresh = ContentFixtures(bvid: "BV1PopularG7", title: "刷新热门榜单")
        let appendGate = TestGate()
        let repository = FeedRepositoryStub(popular: { request, attempt in
            if request.page == 2 {
                await appendGate.pass()
                return old.popularPage(request)
            }
            return (attempt == 1 ? old : fresh).popularPage(
                request,
                hasMore: attempt == 1
            )
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        model.loadMore(.popular)
        try await appendGate.waitForEntries()

        model.refreshPopular(pageSize: 50)
        try await appendGate.waitForCancellations()
        await model.waitForCurrentTask()
        await appendGate.open()

        guard case .loaded(.popular(let page)) = model.state else {
            Issue.record("刷新后的热门榜单应保持 loaded")
            return
        }
        #expect(page.videos.map(\.bvid) == [fresh.bvid])
        #expect(page.pageNumber == 1)
        #expect(!page.hasMore)
        #expect(model.successfulRefreshGeneration(for: .popular) == 1)
    }

    @Test
    @MainActor
    func failedSearchRetriesItsOriginalRequest() async {
        let fixture = ContentFixtures()
        let model = BrowseViewModel(
            useCase: FeedUseCase(
                repository: FeedRepositoryStub(search: { request, attempt in
                    if attempt == 1 {
                        throw ContentApplicationError.requestRestricted
                    }
                    return fixture.searchPage(page: request.page)
                })
            )
        )

        model.search(VideoSearchCriteria(query: "macOS"))
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

    @Test(arguments: [BrowseFeed.popular, .search])
    @MainActor
    func nearEndAppendsDeduplicatesAndBackpressuresSameTail(_ feed: BrowseFeed) async {
        let first = ContentFixtures(bvid: "BV1PagedA1", title: "第一页")
        let second = ContentFixtures(bvid: "BV1PagedB2", title: "第二页")
        let repository = FeedRepositoryStub.pagination(feed, first: first, second: second)
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        feed.activate(model)
        await model.waitForCurrentTask()
        let firstTail = feed.pagination(model)
        #expect(firstTail.canLoadMore)
        #expect(firstTail.tailIdentity?.contains("|1|") == true)

        feed.loadMore(model)
        feed.loadMore(model)
        await model.waitForCurrentTask()

        #expect(feed.loadedBVIDs(model) == [first.bvid, second.bvid])
        #expect(await repository.requestedPages(feed) == [1, 2])
        #expect(!feed.pagination(model).canLoadMore)
    }

    @Test(arguments: [BrowseFeed.popular, .search])
    @MainActor
    func failedAppendKeepsCardsAndRetriesOnlyNextPage(_ feed: BrowseFeed) async {
        let first = ContentFixtures(bvid: "BV1PagedC3", title: "保留卡片")
        let second = ContentFixtures(bvid: "BV1PagedD4", title: "重试追加")
        let repository = FeedRepositoryStub.pagination(
            feed,
            first: first,
            second: second,
            failsFirstSecondPage: true
        )
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        feed.activate(model)
        await model.waitForCurrentTask()
        let loadedState = model.state

        feed.loadMore(model)
        await model.waitForCurrentTask()
        let failed = feed.pagination(model)
        #expect(model.state == loadedState)
        #expect(failed.loadMoreError == .transportFailure)
        #expect(!failed.canLoadMore)
        #expect(failed.tailIdentity == nil)

        feed.retryLoadMore(model)
        await model.waitForCurrentTask()

        #expect(feed.loadedBVIDs(model) == [first.bvid, second.bvid])
        #expect(await repository.requestedPages(feed) == [1, 2, 2])
        #expect(
            await repository.searchRequests.allSatisfy { $0.criteria == BrowseFeed.searchCriteria }
        )
    }

    /// 新关键词与同关键词换筛选条件都开启新的第 1 页工作集。
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor
    func newSearchCancelsAppendAndStartsANewPageOneWorkset(
        keepsQuery: Bool
    ) async throws {
        let newCriteria =
            keepsQuery
            ? VideoSearchCriteria(query: "macOS", order: .mostPlayed, duration: .underTenMinutes)
            : VideoSearchCriteria(query: "新查询")
        let old = ContentFixtures(bvid: "BV1SearchOld", title: "旧条件")
        let fresh = ContentFixtures(bvid: "BV1SearchNew", title: "新条件")
        let oldCriteria = VideoSearchCriteria(query: "macOS")
        let oldAppendGate = TestGate()
        let repository = FeedRepositoryStub(search: { request, _ in
            let isOld = request.criteria == oldCriteria
            if isOld, request.page == 2 {
                await oldAppendGate.pass()
            }
            return SearchPage(
                videos: [(isOld ? old : fresh).searchVideo],
                pageNumber: request.page,
                pageSize: 20,
                totalResults: isOld ? 2 : 1,
                totalPages: isOld ? 2 : 1
            )
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.search(oldCriteria)
        await model.waitForCurrentTask()
        model.loadMore(.search)
        try await oldAppendGate.waitForEntries()

        model.search(newCriteria)
        try await oldAppendGate.waitForCancellations()
        await model.waitForCurrentTask()
        await oldAppendGate.open()

        guard case .loaded(.search(let query, let page)) = model.state else {
            Issue.record("新搜索应保持 loaded")
            return
        }
        #expect(query == newCriteria.query)
        #expect(page.pageNumber == 1)
        #expect(page.videos.map(\.bvid) == [fresh.bvid])
        #expect(
            model.activeRequestIdentity
                == .search(VideoSearchRequest(criteria: newCriteria, page: 1))
        )
        #expect(
            model.pagination(for: .search(VideoSearchRequest(criteria: newCriteria, page: 1)))
                .loadMoreError == nil
        )
    }

    @Test(.timeLimit(.minutes(1)), arguments: [BrowseFeed.recommendation, .popular, .search])
    @MainActor
    func authenticationEpochRestartsFeedAndRejectsLateOldResult(_ feed: BrowseFeed) async throws {
        let old = ContentFixtures(bvid: "BV1EpochOld", title: "旧账户结果")
        let fresh = ContentFixtures(bvid: "BV1EpochNew", title: "新账户结果")
        let gates = [TestGate(), TestGate()]
        let repository = FeedRepositoryStub(
            recommendations: { _, attempt in
                await gates[attempt - 1].pass()
                return (attempt == 1 ? old : fresh).recommendationPage
            },
            popular: { request, attempt in
                await gates[attempt - 1].pass()
                return (attempt == 1 ? old : fresh).popularPage(request)
            },
            search: { request, attempt in
                await gates[attempt - 1].pass()
                return (attempt == 1 ? old : fresh).searchPage(page: request.page)
            }
        )
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        feed.activate(model)
        try await gates[0].waitForEntries()

        model.synchronizeAuthenticationSession(generation: 1)
        try await gates[0].waitForCancellations()
        try await gates[1].waitForEntries()
        await gates[1].open()
        await model.waitForCurrentTask()

        model.synchronizeAuthenticationSession(generation: 1)
        await gates[0].open()

        #expect(feed.loadedBVIDs(model) == [fresh.bvid])
        #expect(await repository.requestedPages(feed).count == 2)
    }

    @Test
    @MainActor
    func tabRoundTripPreservesPopularAndSearchWorksetsWithoutNewRequests() async {
        let first = ContentFixtures(bvid: "BV1PopularH8", title: "热门第一页")
        let second = ContentFixtures(bvid: "BV1PopularJ9", title: "热门第二页")
        let searchFixture = ContentFixtures()
        let repository = FeedRepositoryStub(
            popular: { request, _ in
                request.page == 1
                    ? first.popularPage(request, hasMore: true)
                    : second.popularPage(request)
            },
            search: { request, _ in searchFixture.searchPage(page: request.page) }
        )
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        model.loadMore(.popular)
        await model.waitForCurrentTask()
        model.activateSearch(VideoSearchCriteria(query: "macOS"))
        await model.waitForCurrentTask()
        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()

        #expect(BrowseFeed.popular.loadedBVIDs(model) == [first.bvid, second.bvid])
        #expect(await repository.popularPages == [1, 2])
        #expect(await repository.searchRequests.count == 1)
        #expect(
            model.presentation(for: .search(query: "macOS", page: 1)).state
                == .loaded(.search(query: "macOS", page: searchFixture.searchPage()))
        )
    }

    @Test
    @MainActor
    func failedRefreshKeepsMatchingLoadedContentVisible() async {
        let fixture = ContentFixtures()
        let repository = FeedRepositoryStub(popular: { request, attempt in
            if attempt == 2 { throw ContentApplicationError.requestRestricted }
            return fixture.popularPage(request)
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        let loadedState = model.state
        let successfulRefreshGeneration =
            model.successfulRefreshGeneration(for: .popular)

        model.refreshPopular(pageSize: 50)
        #expect(model.state == loadedState)
        #expect(model.isRefreshing)
        await model.waitForCurrentTask()

        #expect(model.state == loadedState)
        #expect(!model.isRefreshing)
        #expect(model.refreshError == .requestRestricted)
        #expect(
            model.successfulRefreshGeneration(for: .popular)
                == successfulRefreshGeneration
        )
        #expect(await repository.popularPages.count == 2)
    }

    @Test
    @MainActor
    func onlySuccessfulSameQueryRefreshAdvancesSearchGeneration() async {
        let fixture = ContentFixtures()
        let repository = FeedRepositoryStub(search: { request, attempt in
            if attempt == 3 { throw ContentApplicationError.requestRestricted }
            return fixture.searchPage(page: request.page)
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.search(VideoSearchCriteria(query: "macOS"))
        await model.waitForCurrentTask()
        #expect(model.successfulRefreshGeneration(for: .search) == 0)

        model.search(VideoSearchCriteria(query: "macOS"))
        await model.waitForCurrentTask()
        #expect(model.successfulRefreshGeneration(for: .search) == 1)

        model.search(VideoSearchCriteria(query: "macOS"))
        #expect(model.isRefreshing)
        await model.waitForCurrentTask()

        #expect(model.successfulRefreshGeneration(for: .search) == 1)
        #expect(model.refreshError == .requestRestricted)
        #expect(await repository.searchRequests.count == 3)
    }

    @Test(arguments: [BrowseFeed.recommendation, .popular, .search])
    @MainActor
    func successfulRefreshAdvancesOnlyItsOwnSourceGeneration(_ feed: BrowseFeed) async {
        let fixture = ContentFixtures()
        let repository = FeedRepositoryStub(
            recommendations: { _, _ in fixture.recommendationPage },
            popular: { request, _ in fixture.popularPage(request) },
            search: { request, _ in fixture.searchPage(page: request.page) }
        )
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        feed.activate(model)
        await model.waitForCurrentTask()
        feed.refresh(model)
        await model.waitForCurrentTask()

        for source in FeedSource.allCases {
            #expect(
                model.successfulRefreshGeneration(for: source)
                    == (source == feed.source ? 1 : 0)
            )
        }
    }

    @Test
    @MainActor
    func resetClearsWorksetsAndRequiresANewLoad() async {
        let fixture = ContentFixtures()
        let repository = FeedRepositoryStub(
            popular: { request, _ in fixture.popularPage(request) },
            search: { request, _ in fixture.searchPage(page: request.page) }
        )
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
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
        #expect(await repository.popularPages.count == 2)
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
            startOutcome: .resumed(
                positionSeconds: 42.5,
                token: resumeToken,
                discontinuityGeneration: 3
            ),
            restartSucceeds: true
        )
        let model = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: player
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)

        #expect(model.presentedContext?.selectedPage.cid == 900_002)
        #expect(await repository.playbackRequests.map(\.cid) == [900_001, 900_002])
        #expect(player.startedInitialPositions == [42.5])
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
            startOutcome: .resumed(
                positionSeconds: 42.5,
                token: resumeToken,
                discontinuityGeneration: 1
            ),
            restartSucceeds: true,
            holdsRestarts: true
        )
        let model = VideoViewModel(
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

    @Test
    @MainActor
    func resumePreparationFailureUsesExistingPlaybackRetryState() async {
        let fixture = ContentFixtures()
        let player = PlayerStub(
            startOutcome: .preparationFailed
        )
        let model = VideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture)
            ),
            playback: player
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)

        #expect(
            model.state
                == .failed(bvid: fixture.bvid, failure: .playback)
        )
        #expect(model.resumeNotice == nil)
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
        let model = VideoViewModel(
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
        let model = VideoViewModel(
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
        let model = VideoViewModel(
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
        let model = VideoViewModel(
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
        let model = VideoViewModel(
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

        model.retry()
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
        let model = VideoViewModel(
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
        let model = VideoViewModel(
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
        let model = VideoViewModel(
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
        let model = VideoViewModel(
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
        let model = VideoViewModel(
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

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func relatedVideoABARejectsOldSameBVIDResult() async throws {
        let fixture = ContentFixtures()
        let relatedRepository = RelatedRepositoryStub()
        let model = VideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture)
            ),
            playback: PlayerStub(),
            relatedVideoUseCase: RelatedVideoUseCase(
                repository: relatedRepository
            )
        )

        model.loadVideo("BV1RelatedAA")
        await relatedRepository.waitForRequestCount(1)
        model.loadVideo("BV1RelatedBB")
        await relatedRepository.waitForRequestCount(2)
        model.loadVideo("BV1RelatedAA")
        await relatedRepository.waitForRequestCount(3)

        let newResult = RelatedVideo.testFixture(bvid: "BV1CurrentAA1")
        await relatedRepository.releaseRequest(2, videos: [newResult])
        await waitForObservedState {
            model.relatedVideoState
                == .loaded(bvid: "BV1RelatedAA", videos: [newResult])
        }

        await relatedRepository.releaseRequest(
            0,
            videos: [.testFixture(bvid: "BV1StaleAAA1")]
        )
        await relatedRepository.releaseRequest(1, videos: [])

        #expect(
            model.relatedVideoState
                == .loaded(bvid: "BV1RelatedAA", videos: [newResult])
        )
    }

    @Test
    @MainActor
    func relatedVideoFailureRetriesWithoutReloadingPlayback() async {
        let fixture = ContentFixtures()
        let relatedRepository = RelatedRepositoryStub(
            responses: [
                .failure(.transportFailure),
                .success([.testFixture(bvid: "BV1RetryVid1")])
            ]
        )
        let player = PlayerStub()
        let model = VideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture)
            ),
            playback: player,
            relatedVideoUseCase: RelatedVideoUseCase(
                repository: relatedRepository
            )
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        await waitForObservedState {
            model.relatedVideoState
                == .failed(bvid: fixture.bvid, error: .transportFailure)
        }

        model.retryRelatedVideos()
        await waitForObservedState {
            model.relatedVideoState
                == .loaded(
                    bvid: fixture.bvid,
                    videos: [.testFixture(bvid: "BV1RetryVid1")]
                )
        }

        #expect(player.loadedPlaybacks.count == 1)
        #expect(await relatedRepository.callCount == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func uploaderSignatureLoadsWithoutBlockingReadyDetail() async throws {
        let fixture = ContentFixtures()
        let signatureRepository = SignatureRepositoryStub()
        let model = VideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture)
            ),
            playback: PlayerStub(),
            uploaderSignatureUseCase: UploaderSignatureUseCase(
                repository: signatureRepository
            )
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        await signatureRepository.waitForRequestCount(1)

        #expect(model.presentedContext?.detail == fixture.detail)
        #expect(model.uploaderSignatureState == .loading)

        await signatureRepository.releaseRequest(0, signature: "公开签名")
        await waitForObservedState { model.uploaderSignatureState == .loaded("公开签名") }
    }

    @Test
    @MainActor
    func uploaderSignatureFailureHidesOnlyEnhancement() async {
        let fixture = ContentFixtures()
        let model = VideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture)
            ),
            playback: PlayerStub(),
            uploaderSignatureUseCase: UploaderSignatureUseCase(
                repository: SignatureRepositoryStub(immediate: .failure(.transportFailure))
            )
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        await waitForObservedState { model.uploaderSignatureState != .loading }

        #expect(
            model.state
                == .ready(
                    VideoContext(
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
        let fixture = ContentFixtures()
        let signatureRepository = SignatureRepositoryStub(immediate: .success("公开签名"))
        let model = VideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture, pages: fixture.twoPages)
            ),
            playback: PlayerStub(),
            uploaderSignatureUseCase: UploaderSignatureUseCase(
                repository: signatureRepository
            )
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        await waitForObservedState { model.uploaderSignatureState != .loading }
        model.selectPage(cid: 900_002)
        await waitUntilSettled(model)

        #expect(model.uploaderSignatureState == .loaded("公开签名"))
        #expect(await signatureRepository.callCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func uploaderSignatureABARejectsOldSameOwnerResult() async throws {
        let first = ContentFixtures(bvid: "BV1SignatureA", title: "视频 A")
        let second = ContentFixtures(bvid: "BV1SignatureB", title: "视频 B")
        let signatureRepository = SignatureRepositoryStub()
        let model = VideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixtures: [first, second])
            ),
            playback: PlayerStub(),
            uploaderSignatureUseCase: UploaderSignatureUseCase(
                repository: signatureRepository
            )
        )

        model.loadVideo(first.bvid)
        await waitUntilSettled(model)
        await signatureRepository.waitForRequestCount(1)

        model.loadVideo(second.bvid)
        await waitUntilSettled(model)
        await signatureRepository.waitForRequestCount(2)
        model.loadVideo(first.bvid)
        await waitUntilSettled(model)
        await signatureRepository.waitForRequestCount(3)

        await signatureRepository.releaseRequest(2, signature: "新 A 签名")
        await waitForObservedState { model.uploaderSignatureState == .loaded("新 A 签名") }
        await signatureRepository.releaseRequest(0, signature: "旧 A 签名")
        await signatureRepository.releaseRequest(1, signature: "旧 B 签名")

        #expect(model.presentedContext?.detail.bvid == first.bvid)
        #expect(model.uploaderSignatureState == .loaded("新 A 签名"))
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func resetCancelsAndIsolatesLateUploaderSignature() async throws {
        let fixture = ContentFixtures()
        let signatureRepository = SignatureRepositoryStub()
        let model = VideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(fixture)
            ),
            playback: PlayerStub(),
            uploaderSignatureUseCase: UploaderSignatureUseCase(
                repository: signatureRepository
            )
        )

        model.loadVideo(fixture.bvid)
        await waitUntilSettled(model)
        await signatureRepository.waitForRequestCount(1)
        model.reset()
        await signatureRepository.releaseRequest(0, signature: "迟到签名")

        #expect(model.state == .idle)
        #expect(model.presentedContext == nil)
        #expect(model.uploaderSignatureState == .loaded(nil))
    }

    @Test
    @MainActor
    func crossBVIDExplicitCIDLoadsOnlyTheAtomicTarget() async {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(fixtures: fixtures)
        let model = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(
            fixtures.episodeBVID,
            preferredCID: fixtures.episodePages[1].cid
        )
        #expect(model.requestedSelectionBVID == fixtures.episodeBVID)
        #expect(model.requestedPreferredCID == fixtures.episodePages[1].cid)
        #expect(model.presentedPlaybackIdentity == nil)
        await waitUntilSettled(model)

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
        let model = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(
            fixtures.episodeBVID,
            preferredCID: fixtures.episodePages[1].cid
        )
        await waitUntilSettled(model)
        #expect(model.requestedPreferredCID == fixtures.episodePages[1].cid)
        #expect(model.presentedPlaybackIdentity == nil)

        model.retry()
        await waitUntilSettled(model)

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
        let model = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )
        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        var resolved: [(String, Int64?)] = []

        model.selectCollectionEpisode(fixtures.lazyEpisode) {
            resolved.append(($0, $1))
        }
        await repository.waitForEpisodeDetailRequest()

        #expect(model.selectedCollectionEpisode == fixtures.lazyEpisode.id)
        #expect(model.collectionEpisodePageStates[fixtures.lazyEpisode.id] == .loading)
        #expect(resolved.isEmpty)

        await repository.releaseEpisodeDetail()
        await waitForObservedState {
            model.collectionEpisodePageStates[fixtures.lazyEpisode.id]
                == .loaded(bvid: fixtures.episodeBVID)
        }

        #expect(resolved.count == 1)
        #expect(resolved.first?.0 == fixtures.episodeBVID)
        #expect(resolved.first?.1 == fixtures.episodePages.first?.cid)
    }

    @Test
    @MainActor
    func explicitDuplicateBVIDOccurrenceSurvivesContextReconciliation() async {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(fixtures: fixtures)
        let model = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        model.selectCollectionEpisode(fixtures.rootSummaryEpisode) { _, _ in }
        #expect(model.selectedCollectionEpisode == fixtures.rootSummaryEpisode.id)

        model.loadVideo(
            fixtures.rootBVID,
            preferredCID: fixtures.rootPages[1].cid
        )
        await waitUntilSettled(model)

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
        let model = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        model.selectCollectionEpisode(fixtures.duplicateLazyEpisode) { _, _ in }
        await repository.waitForEpisodeDetailRequest()
        await repository.releaseEpisodeDetail()
        await waitForObservedState {
            model.collectionEpisodePageStates[fixtures.duplicateLazyEpisode.id]
                == .loaded(bvid: fixtures.episodeBVID)
        }

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
    func cancelledEpisodeFailureDoesNotRevalidateAuthentication() async throws {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(
            fixtures: fixtures,
            blocksEpisodeDetail: true,
            episodeFailureAfterRelease: .authenticationInvalid
        )
        let model = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        await repository.waitForEpisodeDetailRequest()
        model.selectCollectionEpisode(fixtures.embeddedEpisode) { _, _ in }
        await repository.releaseEpisodeDetail()

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
        let model = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        await waitForObservedState {
            model.collectionEpisodePageStates[fixtures.lazyEpisode.id]
                == .failed(.transportFailure)
        }
        #expect(model.presentedContext?.detail.bvid == fixtures.rootBVID)

        model.retryCollectionEpisodePages(fixtures.lazyEpisode)
        await waitForObservedState {
            model.collectionEpisodePageStates[fixtures.lazyEpisode.id]
                == .loaded(bvid: fixtures.episodeBVID)
        }
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
        let model = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        await repository.waitForEpisodeDetailRequest()

        model.reset()
        await repository.releaseEpisodeDetail()

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
        let model = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        model.selectCollectionEpisode(fixtures.lazyEpisode) { _, _ in }
        await repository.waitForEpisodeDetailRequest(count: 1)
        model.selectCollectionEpisode(fixtures.thirdLazyEpisode) { _, _ in }

        await repository.waitForEpisodeDetailRequest(count: 2)
        #expect(await repository.episodeDetailRequestCount() == 2)
        #expect(model.collectionEpisodePageStates[fixtures.lazyEpisode.id] == .idle)
        #expect(model.collectionEpisodePageStates[fixtures.thirdLazyEpisode.id] == .loading)

        await repository.releaseEpisodeDetail()
        await waitForObservedState {
            model.collectionEpisodePageStates[fixtures.thirdLazyEpisode.id]
                == .loaded(bvid: fixtures.thirdBVID)
        }

        #expect(await repository.episodeDetailRequestCount() == 2)
        #expect(
            model.collectionEpisodePageStates[fixtures.lazyEpisode.id] == .idle
        )
    }

    @Test
    @MainActor
    func knownEpisodePagesResolveSelectionsWithoutRemoteDetail() async {
        let fixtures = CollectionFixtures()
        let repository = CollectionEpisodeRepositoryStub(fixtures: fixtures)
        let model = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
        var embeddedSelection: String?
        model.selectCollectionEpisode(fixtures.embeddedEpisode) { bvid, _ in
            embeddedSelection = bvid
        }
        #expect(embeddedSelection == fixtures.rootBVID)
        #expect(
            model.collectionEpisodePages(for: fixtures.embeddedEpisode.id)
                == fixtures.rootPages
        )
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
        let model = VideoViewModel(
            useCase: VideoUseCase(
                repository: VideoRepositoryStub(
                    detail: { _, _ in fixtures.detail },
                    pages: { _, _ in fixtures.detail.pages },
                    playback: { _, _ in fixtures.playback }
                )
            ),
            playback: PlayerStub()
        )

        model.loadVideo(fixtures.rootBVID)
        await waitUntilSettled(model)
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

private struct CollectionFixtures: Sendable {
    let rootBVID = "BV1FixtureA1"
    let episodeBVID = "BV1FixtureB2"
    let thirdBVID = "BV1FixtureC3"
    let rootPages = [
        VideoPage(cid: 900_001, index: 1, title: "当前 P1", durationSeconds: 120),
        VideoPage(cid: 900_002, index: 2, title: "当前 P2", durationSeconds: 180)
    ]
    let episodePages = [
        VideoPage(cid: 910_001, index: 1, title: "下一 P1", durationSeconds: 90),
        VideoPage(cid: 910_002, index: 2, title: "下一 P2", durationSeconds: 110)
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
                            embeddedRemoteEpisode
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

private actor CollectionEpisodeRepositoryStub: VideoRepository {
    let fixtures: CollectionFixtures
    let blocksEpisodeDetail: Bool
    let episodeFailureAfterRelease: ContentApplicationError?
    var failsFirstEpisodeDetail: Bool
    private var episodeRequests = 0
    private var observedPlaybackRequests: [(String, Int64)] = []
    private let episodeRequestEvents = TestEventCounter()
    private var episodeReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        fixtures: CollectionFixtures,
        blocksEpisodeDetail: Bool = false,
        failsFirstEpisodeDetail: Bool = false,
        episodeFailureAfterRelease: ContentApplicationError? = nil
    ) {
        self.fixtures = fixtures
        self.blocksEpisodeDetail = blocksEpisodeDetail
        self.failsFirstEpisodeDetail = failsFirstEpisodeDetail
        self.episodeFailureAfterRelease = episodeFailureAfterRelease
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        guard bvid != fixtures.rootBVID else {
            return fixtures.rootDetail
        }
        episodeRequests += 1
        await episodeRequestEvents.signal()
        if failsFirstEpisodeDetail {
            failsFirstEpisodeDetail = false
            throw ContentApplicationError.transportFailure
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
        episodeReleaseWaiters.resumeAll()
    }
}

/// UploaderSignatureRepository 的唯一替身：`immediate` 为 nil 时每个请求挂起到测试按序号放行。
private actor SignatureRepositoryStub: UploaderSignatureRepository {
    private let immediate: Result<String?, ContentApplicationError>?
    private var held: [CheckedContinuation<String?, Never>?] = []
    private var requestWaiters = CountWaiters()
    private(set) var callCount = 0

    init(immediate: Result<String?, ContentApplicationError>? = nil) {
        self.immediate = immediate
    }

    func signature(for ownerID: Int64) async throws -> String? {
        callCount += 1
        if let immediate { return try immediate.get() }
        return await withCheckedContinuation { continuation in
            held.append(continuation)
            requestWaiters.resume(reaching: held.count)
        }
    }

    func waitForRequestCount(_ count: Int) async {
        await withCheckedContinuation {
            requestWaiters.add($0, until: count, current: held.count)
        }
    }

    func releaseRequest(_ index: Int, signature: String?) {
        held[index]?.resume(returning: signature)
        held[index] = nil
    }
}

/// RelatedVideoRepository 的唯一替身：按序消费 `responses`，用尽后挂起到测试按序号放行。
private actor RelatedRepositoryStub: RelatedVideoRepository {
    private var responses: [Result<[RelatedVideo], ContentApplicationError>]
    private var held: [Int: CheckedContinuation<[RelatedVideo], Never>] = [:]
    private var requestWaiters = CountWaiters()
    private(set) var callCount = 0

    init(responses: [Result<[RelatedVideo], ContentApplicationError>] = []) {
        self.responses = responses
    }

    func relatedVideos(to bvid: String) async throws -> [RelatedVideo] {
        callCount += 1
        let index = callCount - 1
        requestWaiters.resume(reaching: callCount)
        if !responses.isEmpty { return try responses.removeFirst().get() }
        return await withCheckedContinuation { held[index] = $0 }
    }

    func waitForRequestCount(_ count: Int) async {
        await withCheckedContinuation {
            requestWaiters.add($0, until: count, current: callCount)
        }
    }

    func releaseRequest(_ index: Int, videos: [RelatedVideo]) {
        held.removeValue(forKey: index)?.resume(returning: videos)
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

private struct ContentFixtures: Sendable {
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

    var recommendedVideo: RecommendedVideo {
        RecommendedVideo(
            bvid: bvid,
            title: title,
            coverURL: nil,
            owner: owner,
            statistics: popularVideo.statistics,
            durationSeconds: popularVideo.durationSeconds,
            publishedAt: popularVideo.publishedAt,
            recommendationReason: "正在流行"
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
            publishedAt: popularVideo.publishedAt,
            pages: [page]
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

    var twoPages: [VideoPage] {
        [page, VideoPage(cid: 900_002, index: 2, title: "P2", durationSeconds: 180)]
    }

    func popularPage(
        _ request: FeedRepositoryStub.PopularRequest,
        hasMore: Bool = false
    ) -> PopularPage {
        PopularPage(
            videos: [popularVideo],
            pageNumber: request.page,
            pageSize: request.pageSize,
            hasMore: hasMore
        )
    }

    func searchPage(page: Int = 1) -> SearchPage {
        SearchPage(
            videos: [searchVideo],
            pageNumber: page,
            pageSize: 20,
            totalResults: 1,
            totalPages: 1
        )
    }

    var recommendationPage: RecommendationPage {
        RecommendationPage(
            videos: [recommendedVideo],
            continuation: RecommendationContinuation(freshIndex: 1),
            nextContinuation: RecommendationContinuation(freshIndex: 2)
        )
    }

    var playback: VideoPlayback {
        VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: [],
                originalAudioRepresentations: []
            ),
            mediaHeaders: [
                "Referer": "https://www.bilibili.com/video/\(bvid)/",
                "User-Agent": "BiliKitMacTests"
            ]
        )
    }

    func playback(resuming metadata: PlaybackResumeMetadata) -> VideoPlayback {
        VideoPlayback(
            media: playback.media,
            mediaHeaders: playback.mediaHeaders,
            resumeMetadata: metadata
        )
    }
}

/// 游客 Feed port 的共享替身：每个方法由闭包回答，并按到达顺序记录请求。
///
/// 闭包的 `attempt` 是同一请求第几次到达（从 1 开始），用于表达“首次失败、重试成功”。
private actor FeedRepositoryStub: FeedRepository {
    typealias Response<Request, Value> =
        @Sendable (Request, _ attempt: Int) async throws -> Value
    typealias PopularRequest = (page: Int, pageSize: Int)

    private let recommendationResponse: Response<RecommendationContinuation?, RecommendationPage>
    private let popularResponse: Response<PopularRequest, PopularPage>
    private let searchResponse: Response<VideoSearchRequest, SearchPage>
    private(set) var recommendationRequests: [RecommendationContinuation?] = []
    private(set) var popularPages: [Int] = []
    private(set) var searchRequests: [VideoSearchRequest] = []

    /// 未配置的推荐请求视为不可用，热门与搜索返回空页。
    init(
        recommendations: Response<RecommendationContinuation?, RecommendationPage>? = nil,
        popular: Response<PopularRequest, PopularPage>? = nil,
        search: Response<VideoSearchRequest, SearchPage>? = nil
    ) {
        recommendationResponse =
            recommendations ?? { _, _ in throw ContentApplicationError.unavailable }
        popularResponse =
            popular ?? { request, _ in
                PopularPage(videos: [], pageNumber: request.page, pageSize: request.pageSize)
            }
        searchResponse =
            search ?? { request, _ in
                SearchPage(
                    videos: [],
                    pageNumber: request.page,
                    pageSize: 20,
                    totalResults: 0,
                    totalPages: 0
                )
            }
    }

    func recommendations(
        after continuation: RecommendationContinuation?
    ) async throws -> RecommendationPage {
        recommendationRequests.append(continuation)
        let attempt = recommendationRequests.filter { $0 == continuation }.count
        return try await recommendationResponse(continuation, attempt)
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        popularPages.append(page)
        let attempt = popularPages.filter { $0 == page }.count
        return try await popularResponse((page, pageSize), attempt)
    }

    func searchVideos(request: VideoSearchRequest) async throws -> SearchPage {
        searchRequests.append(request)
        let attempt = searchRequests.filter { $0 == request }.count
        return try await searchResponse(request, attempt)
    }
}

extension FeedRepositoryStub {
    /// 两页热门或搜索：第 1 页含重复卡片，第 2 页补上 `second`，可让第 2 页首次失败。
    static func pagination(
        _ feed: BrowseFeed,
        first: ContentFixtures,
        second: ContentFixtures,
        failsFirstSecondPage: Bool = false
    ) -> FeedRepositoryStub {
        let pageVideos: @Sendable (Int, Int) throws -> [ContentFixtures] = { page, attempt in
            switch page {
            case 1: return [first, first]
            case 2:
                if failsFirstSecondPage, attempt == 1 {
                    throw ContentApplicationError.transportFailure
                }
                return [first, second]
            default: throw ContentApplicationError.invalidRequest
            }
        }
        switch feed {
        case .recommendation:
            preconditionFailure("推荐使用 continuation 分页")
        case .popular:
            return FeedRepositoryStub(popular: { request, attempt in
                PopularPage(
                    videos: try pageVideos(request.page, attempt).map(\.popularVideo),
                    pageNumber: request.page,
                    pageSize: request.pageSize,
                    hasMore: request.page == 1
                )
            })
        case .search:
            return FeedRepositoryStub(search: { request, attempt in
                SearchPage(
                    videos: try pageVideos(request.page, attempt).map(\.searchVideo),
                    pageNumber: request.page,
                    pageSize: 20,
                    totalResults: 2,
                    totalPages: 2
                )
            })
        }
    }
}

/// 游客视频 port 的共享替身；`attempt` 语义与 `FeedRepositoryStub` 相同。
private actor VideoRepositoryStub: VideoRepository {
    typealias Response<Request, Value> = FeedRepositoryStub.Response<Request, Value>

    private let detailResponse: Response<String, VideoDetail>
    private let pagesResponse: Response<String, [VideoPage]>
    private let playbackResponse: Response<PlaybackItemIdentity, VideoPlayback>
    private var detailRequests: [String] = []
    private(set) var playbackRequests: [PlaybackItemIdentity] = []

    init(
        detail: @escaping Response<String, VideoDetail>,
        pages: @escaping Response<String, [VideoPage]>,
        playback: @escaping Response<PlaybackItemIdentity, VideoPlayback>
    ) {
        detailResponse = detail
        pagesResponse = pages
        playbackResponse = playback
    }

    /// 所有请求都由同一个 fixture 回答；默认只有一个分 P。
    init(
        _ fixture: ContentFixtures,
        pages: [VideoPage]? = nil,
        playback: Response<PlaybackItemIdentity, VideoPlayback>? = nil
    ) {
        self.init(
            detail: { _, _ in fixture.detail },
            pages: { _, _ in pages ?? [fixture.page] },
            playback: playback ?? { _, _ in fixture.playback }
        )
    }

    /// 按 BVID 选择 fixture；未知 BVID 视为无效响应，`cancelledBVID` 的详情请求被取消。
    init(fixtures: [ContentFixtures], cancelledBVID: String? = nil) {
        let fixturesByBVID = Dictionary(
            uniqueKeysWithValues: fixtures.map { ($0.bvid, $0) }
        )
        let fixture: @Sendable (String) throws -> ContentFixtures = { bvid in
            guard let fixture = fixturesByBVID[bvid] else {
                throw ContentApplicationError.invalidResponse
            }
            return fixture
        }
        self.init(
            detail: { bvid, _ in
                if bvid == cancelledBVID { throw CancellationError() }
                return try fixture(bvid).detail
            },
            pages: { bvid, _ in [try fixture(bvid).page] },
            playback: { identity, _ in try fixture(identity.bvid).playback }
        )
    }

    /// `/view` 响应自带分 P：详情脚本给出其余字段，分 P 脚本给出 `pages`。
    func videoDetail(for bvid: String) async throws -> VideoDetail {
        detailRequests.append(bvid)
        let attempt = detailRequests.filter { $0 == bvid }.count
        let detail = try await detailResponse(bvid, attempt)
        return VideoDetail(
            bvid: detail.bvid,
            title: detail.title,
            summary: detail.summary,
            coverURL: detail.coverURL,
            owner: detail.owner,
            statistics: detail.statistics,
            durationSeconds: detail.durationSeconds,
            publishedAt: detail.publishedAt,
            dimension: detail.dimension,
            aid: detail.aid,
            pages: try await pagesResponse(bvid, attempt),
            collection: detail.collection,
            access: detail.access
        )
    }

    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        let identity = PlaybackItemIdentity(bvid: bvid, cid: cid)
        playbackRequests.append(identity)
        let attempt = playbackRequests.filter { $0 == identity }.count
        return try await playbackResponse(identity, attempt)
    }
}

/// 唯一的 PlaybackControlling 替身，记录 load、开播、重播与停止。
///
/// 可让指定 BVID 的 load 失败、让第 `heldLoad` 次 load 挂起到测试放行，
/// 或让首个 load 先发布失败再等到 stop 才返回。失败事件经 `FailureEventSource` 发布，
/// 测试可等 ViewModel 回来请求下一个事件。
@MainActor
private final class PlayerStub: PlaybackControlling {
    private let startOutcome: PlaybackStartOutcome
    private let restartSucceeds: Bool
    private let holdsRestarts: Bool
    private let failingBVID: String?
    private let heldLoad: Int?
    private let failsFirstLoadUntilStopped: Bool
    private let failureSource = FailureEventSource()
    private var heldLoadContinuation: CheckedContinuation<Void, Never>?
    private var loadWaiters = CountWaiters()
    private var stopWaiters = CountWaiters()
    private var restartWaiters = CountWaiters()
    private var heldRestarts: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var loadedPlaybacks: [VideoPlayback] = []
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var loadedIntents: [PlaybackLoadIntent] = []
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var startedIntents: [PlaybackLoadIntent] = []
    private(set) var startedInitialPositions: [Double?] = []
    private(set) var restartTokens: [PlaybackResumeToken] = []
    private(set) var stopCallCount = 0

    init(
        startOutcome: PlaybackStartOutcome = .startedAtBeginning,
        restartSucceeds: Bool = false,
        holdsRestarts: Bool = false,
        failingBVID: String? = nil,
        heldLoad: Int? = nil,
        failsFirstLoadUntilStopped: Bool = false
    ) {
        self.startOutcome = startOutcome
        self.restartSucceeds = restartSucceeds
        self.holdsRestarts = holdsRestarts
        self.failingBVID = failingBVID
        self.heldLoad = heldLoad
        self.failsFirstLoadUntilStopped = failsFirstLoadUntilStopped
    }

    deinit {
        Task { [failureSource] in await failureSource.finish() }
    }

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        AsyncStream(unfolding: { [failureSource] in await failureSource.next() })
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        loadedPlaybacks.append(playback)
        loadedIdentities.append(identity)
        loadedIntents.append(intent)
        loadWaiters.resume(reaching: loadedIdentities.count)
        if identity.bvid == failingBVID {
            throw PlayerStubFailure()
        }
        if failsFirstLoadUntilStopped, loadedIdentities.count == 1 {
            await failureSource.send(PlaybackFailureEvent(identity: identity, intent: intent))
            await withCheckedContinuation { heldLoadContinuation = $0 }
        } else if loadedIdentities.count == heldLoad {
            await withCheckedContinuation { heldLoadContinuation = $0 }
        }
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
        let index = restartTokens.count
        restartTokens.append(resumeToken)
        restartWaiters.resume(reaching: restartTokens.count)
        if holdsRestarts {
            await withCheckedContinuation { heldRestarts[index] = $0 }
        }
        return restartSucceeds
    }

    func pause() {}

    func stop() {
        stopCallCount += 1
        stopWaiters.resume(reaching: stopCallCount)
        if failsFirstLoadUntilStopped {
            releaseHeldLoad()
        }
    }

    /// 以该 identity 最近一次 load 的 intent 发布 ready 后失败。
    func fail(_ identity: PlaybackItemIdentity) async {
        guard let index = loadedIdentities.lastIndex(of: identity) else { return }
        await publishFailure(PlaybackFailureEvent(identity: identity, intent: loadedIntents[index]))
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

    func waitForLoadCount(_ expectedCount: Int) async {
        await withCheckedContinuation {
            loadWaiters.add($0, until: expectedCount, current: loadedIdentities.count)
        }
    }

    func releaseHeldLoad() {
        heldLoadContinuation?.resume()
        heldLoadContinuation = nil
    }

    func waitForRestartCount(_ expectedCount: Int) async {
        await withCheckedContinuation {
            restartWaiters.add($0, until: expectedCount, current: restartTokens.count)
        }
    }

    func releaseRestart(at index: Int) {
        heldRestarts.removeValue(forKey: index)?.resume()
    }

    func waitForStopCallCount(_ expectedCount: Int) async {
        await withCheckedContinuation {
            stopWaiters.add($0, until: expectedCount, current: stopCallCount)
        }
    }
}

private actor FailureEventSource {
    private var queuedEvents: [PlaybackFailureEvent] = []
    private var pendingNext: CheckedContinuation<PlaybackFailureEvent?, Never>?
    private var requestCount = 0
    private var requestWaiters = CountWaiters()
    private var isFinished = false

    func next() async -> PlaybackFailureEvent? {
        requestCount += 1
        requestWaiters.resume(reaching: requestCount)
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
        await withCheckedContinuation {
            requestWaiters.add($0, until: expectedCount, current: requestCount)
        }
    }

    func finish() {
        isFinished = true
        queuedEvents.removeAll()
        pendingNext?.resume(returning: nil)
        pendingNext = nil
    }
}

private struct PlayerStubFailure: Error {}

/// 把推荐、热门与搜索三条 feed 的相同操作映射到各自 API，供结构相同的参数化测试共用。
enum BrowseFeed: Sendable {
    case recommendation
    case popular
    case search

    static let searchCriteria = VideoSearchCriteria(
        query: "Swift",
        order: .mostFavorited,
        duration: .thirtyToSixtyMinutes,
        publicationRange: VideoPublicationTimeRange(beginTimestamp: 100, endTimestamp: 200)
    )
    private static let popularRequest = FeedRequest.popular(page: 1, pageSize: 50)

    @MainActor
    func activate(_ model: BrowseViewModel) {
        switch self {
        case .recommendation: model.activateRecommendation()
        case .popular: model.activatePopular(pageSize: 50)
        case .search: model.activateSearch(Self.searchCriteria)
        }
    }

    var source: FeedSource {
        switch self {
        case .recommendation: .recommendation
        case .popular: .popular
        case .search: .search
        }
    }

    private var firstPageRequest: FeedRequest {
        switch self {
        case .recommendation: .recommendation(continuation: nil)
        case .popular: Self.popularRequest
        case .search: .search(VideoSearchRequest(criteria: Self.searchCriteria, page: 1))
        }
    }

    @MainActor
    func refresh(_ model: BrowseViewModel) {
        switch self {
        case .recommendation: model.refreshRecommendation()
        case .popular: model.refreshPopular(pageSize: 50)
        case .search: model.search(Self.searchCriteria)
        }
    }

    @MainActor
    func loadMore(_ model: BrowseViewModel) {
        model.loadMore(source)
    }

    @MainActor
    func retryLoadMore(_ model: BrowseViewModel) {
        model.retryLoadMore(source)
    }

    @MainActor
    func pagination(
        _ model: BrowseViewModel
    ) -> (canLoadMore: Bool, tailIdentity: String?, loadMoreError: ContentApplicationError?) {
        let pagination = model.pagination(for: firstPageRequest)
        return (pagination.canLoadMore, pagination.tailIdentity, pagination.loadMoreError)
    }

    @MainActor
    func loadedBVIDs(_ model: BrowseViewModel) -> [String] {
        switch (self, model.state) {
        case (.recommendation, .loaded(.recommendation(let page))): page.videos.map(\.bvid)
        case (.popular, .loaded(.popular(let page))): page.videos.map(\.bvid)
        case (.search, .loaded(.search(_, let page))): page.videos.map(\.bvid)
        default: []
        }
    }
}

extension FeedRepositoryStub {
    /// 推荐没有页码，按请求序号计数。
    func requestedPages(_ feed: BrowseFeed) -> [Int] {
        switch feed {
        case .recommendation: recommendationRequests.indices.map { $0 + 1 }
        case .popular: popularPages
        case .search: searchRequests.map(\.page)
        }
    }
}
