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
        .requestRestricted
    ])
    @MainActor
    func onlyInvalidAuthenticationRequestsAppRevalidation(
        error: GuestApplicationError
    ) async {
        let fixture = GuestFixtures()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: VideoRepositoryStub(
                    fixture,
                    playback: { _, _ in throw error }
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
        let searchGate = TestGate()
        let repository = FeedRepositoryStub(
            popular: { request, _ in fixture.popularPage(request) },
            search: { request, _ in
                await searchGate.pass()
                return fixture.searchPage(page: request.page)
            }
        )
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(
                repository: repository
            )
        )

        model.search("旧搜索")
        try await searchGate.waitForEntries()
        let supersededTask = try #require(model.taskSnapshotForTesting())
        model.refreshPopular()
        await model.waitForCurrentTask()
        await searchGate.open()
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
        let repository = FeedRepositoryStub.popularPagination(
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
        #expect(await repository.popularPages.count == 2)
        #expect(!model.popularPagination(for: request).canLoadMore)
    }

    @Test
    @MainActor
    func recommendationBatchesAppendDeduplicateAndStopWithoutProgress() async {
        let first = GuestFixtures(bvid: "BV1RcmdOneA", title: "推荐一")
        let second = GuestFixtures(bvid: "BV1RcmdTwoB", title: "推荐二")
        let repository = FeedRepositoryStub(recommendations: { continuation, _ in
            let freshIndex = continuation?.freshIndex ?? 1
            let videos: [RecommendedVideo]
            switch freshIndex {
            case 1: videos = [first.recommendedVideo, first.recommendedVideo]
            case 2: videos = [first.recommendedVideo, second.recommendedVideo]
            case 3: videos = [second.recommendedVideo]
            default: throw GuestApplicationError.invalidRequest
            }
            return RecommendationPage(
                videos: videos,
                continuation: RecommendationContinuation(freshIndex: freshIndex),
                nextContinuation: RecommendationContinuation(freshIndex: freshIndex + 1)
            )
        })
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.activateRecommendation()
        await model.waitForCurrentTask()
        #expect(model.recommendationPagination().canLoadMore)

        model.loadMoreRecommendations()
        await model.waitForCurrentTask()
        guard case .loaded(.recommendation(let secondBatch)) = model.state else {
            Issue.record("推荐追加后应保持 loaded")
            return
        }
        #expect(secondBatch.videos.map(\.bvid) == [first.bvid, second.bvid])
        #expect(secondBatch.nextContinuation == RecommendationContinuation(freshIndex: 3))

        model.loadMoreRecommendations()
        await model.waitForCurrentTask()
        guard case .loaded(.recommendation(let finalBatch)) = model.state else {
            Issue.record("全重复推荐批次后应保持 loaded")
            return
        }
        #expect(finalBatch.videos.map(\.bvid) == [first.bvid, second.bvid])
        #expect(finalBatch.nextContinuation == nil)
        #expect(!model.recommendationPagination().canLoadMore)
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
                    GuestFixtures(
                        bvid: "BV-capacity-\(index)",
                        title: "推荐 \(index)"
                    ).recommendedVideo
                },
                continuation: RecommendationContinuation(freshIndex: freshIndex),
                nextContinuation: RecommendationContinuation(freshIndex: freshIndex + 1)
            )
        })
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.activateRecommendation()
        await model.waitForCurrentTask()
        model.loadMoreRecommendations()
        await model.waitForCurrentTask()

        guard case .loaded(.recommendation(let page)) = model.state else {
            Issue.record("推荐达到容量后应保持 loaded")
            return
        }
        #expect(
            page.videos.count
                == GuestBrowseViewModel.maximumRetainedRecommendationVideos
        )
        #expect(page.nextContinuation == nil)
        #expect(!model.recommendationPagination().canLoadMore)
    }

    @Test
    @MainActor
    func recommendationAuthenticationFailureRequestsRevalidation() async {
        let repository = FeedRepositoryStub(recommendations: { _, _ in
            throw GuestApplicationError.authenticationInvalid
        })
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
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
        let fixture = GuestFixtures(bvid: "BV1AuthRcmd1", title: "认证推荐")
        let repository = FeedRepositoryStub(recommendations: { continuation, _ in
            guard continuation == nil else {
                throw GuestApplicationError.authenticationInvalid
            }
            return fixture.recommendationPage
        })
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.activateRecommendation()
        await model.waitForCurrentTask()
        model.loadMoreRecommendations()
        await model.waitForCurrentTask()

        guard case .loaded(.recommendation(let page)) = model.state else {
            Issue.record("认证失效的推荐追加应保留已有卡片")
            return
        }
        #expect(page.videos.count == 1)
        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(model.recommendationPagination().loadMoreError == .authenticationInvalid)
    }

    @Test
    @MainActor
    func popularAndSearchTailAuthenticationFailuresRequestRevalidation() async {
        let fixture = GuestFixtures(bvid: "BV1AuthTail1", title: "认证追加")
        let repository = FeedRepositoryStub(
            popular: { request, _ in
                guard request.page == 1 else {
                    throw GuestApplicationError.authenticationInvalid
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
                    throw GuestApplicationError.authenticationInvalid
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
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        model.loadMorePopular()
        await model.waitForCurrentTask()
        #expect(model.authenticationRevalidationGeneration == 1)

        model.activateSearch(VideoSearchCriteria(query: "认证"))
        await model.waitForCurrentTask()
        model.loadMoreSearch()
        await model.waitForCurrentTask()
        #expect(model.authenticationRevalidationGeneration == 2)
    }

    @Test
    @MainActor
    func failedPopularAppendKeepsCardsAndRetriesOnlyNextPage() async {
        let first = GuestFixtures(bvid: "BV1PopularC3", title: "保留热门卡片")
        let second = GuestFixtures(bvid: "BV1PopularD4", title: "重试热门追加")
        let repository = FeedRepositoryStub.popularPagination(
            first: first,
            second: second,
            failsFirstSecondPage: true
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
        #expect(await repository.popularPages.count == 3)
    }

    @Test
    @MainActor
    func duplicateOnlyPopularPageStopsNonProgressingPagination() async {
        let fixture = GuestFixtures(bvid: "BV1PopularE5", title: "重复热门卡片")
        let repository = FeedRepositoryStub(popular: { request, _ in
            fixture.popularPage(request, hasMore: true)
        })
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
        #expect(await repository.popularPages.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func popularRefreshCancelsAndRejectsLateAppend() async throws {
        let old = GuestFixtures(bvid: "BV1PopularF6", title: "旧热门榜单")
        let fresh = GuestFixtures(bvid: "BV1PopularG7", title: "刷新热门榜单")
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
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        model.loadMorePopular()
        try await appendGate.waitForEntries()
        let oldAppendTask = try #require(model.taskSnapshotForTesting())

        model.refreshPopular(pageSize: 50)
        await model.waitForCurrentTask()
        await appendGate.open()
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
                repository: FeedRepositoryStub(search: { request, attempt in
                    if attempt == 1 {
                        throw GuestApplicationError.requestRestricted
                    }
                    return fixture.searchPage(page: request.page)
                })
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
        let repository = FeedRepositoryStub.searchPagination(
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
        #expect(await repository.searchRequests.count == 2)
        #expect(!model.searchPagination(for: "macOS").canLoadMore)
    }

    @Test
    @MainActor
    func failedSearchAppendKeepsCardsAndRetriesOnlyNextPage() async {
        let first = GuestFixtures(bvid: "BV1SearchC03", title: "保留卡片")
        let second = GuestFixtures(bvid: "BV1SearchD04", title: "重试追加")
        let repository = FeedRepositoryStub.searchPagination(
            first: first,
            second: second,
            failsFirstSecondPage: true
        )
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )
        let criteria = VideoSearchCriteria(
            query: "Swift",
            order: .mostFavorited,
            duration: .thirtyToSixtyMinutes,
            publicationRange: VideoPublicationTimeRange(
                beginTimestamp: 100,
                endTimestamp: 200
            )
        )

        model.search(criteria)
        await model.waitForCurrentTask()
        let loadedState = model.state

        model.loadMoreSearch()
        await model.waitForCurrentTask()
        #expect(model.state == loadedState)
        #expect(
            model.searchPagination(for: criteria).loadMoreError
                == .transportFailure
        )
        #expect(!model.searchPagination(for: criteria).canLoadMore)
        #expect(model.searchPagination(for: criteria).tailIdentity == nil)

        model.retrySearchLoadMore()
        await model.waitForCurrentTask()
        guard case .loaded(.search(_, let page)) = model.state else {
            Issue.record("重试后搜索结果应保持 loaded")
            return
        }
        #expect(page.videos.map(\.bvid) == [first.bvid, second.bvid])
        #expect(await repository.searchRequests.count == 3)
        #expect(
            await repository.searchRequests
                == [
                    VideoSearchRequest(criteria: criteria, page: 1),
                    VideoSearchRequest(criteria: criteria, page: 2),
                    VideoSearchRequest(criteria: criteria, page: 2)
                ]
        )
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func newQueryCancelsAndRejectsLateSearchAppend() async throws {
        let old = GuestFixtures(bvid: "BV1SearchE05", title: "旧查询")
        let fresh = GuestFixtures(bvid: "BV1SearchF06", title: "新查询")
        let oldAppendGate = TestGate()
        let repository = FeedRepositoryStub.blockingSearchAppend(
            old: old,
            fresh: fresh,
            oldAppendGate: oldAppendGate
        )
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.search("旧查询")
        await model.waitForCurrentTask()
        model.loadMoreSearch()
        try await oldAppendGate.waitForEntries()
        let oldAppendTask = try #require(model.taskSnapshotForTesting())

        model.search("新查询")
        await model.waitForCurrentTask()
        await oldAppendGate.open()
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
    func criteriaChangeCancelsAppendAndStartsANewPageOneWorkset() async throws {
        let old = GuestFixtures(bvid: "BV1SearchCriteriaOld", title: "旧条件")
        let fresh = GuestFixtures(bvid: "BV1SearchCriteriaNew", title: "新条件")
        let oldAppendGate = TestGate()
        let repository = FeedRepositoryStub.blockingSearchAppend(
            old: old,
            fresh: fresh,
            oldAppendGate: oldAppendGate
        )
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )
        let oldCriteria = VideoSearchCriteria(query: "macOS")
        let newCriteria = VideoSearchCriteria(
            query: "macOS",
            order: .mostPlayed,
            duration: .underTenMinutes
        )

        model.search(oldCriteria)
        await model.waitForCurrentTask()
        model.loadMoreSearch()
        try await oldAppendGate.waitForEntries()
        let oldAppendTask = try #require(model.taskSnapshotForTesting())

        model.search(newCriteria)
        await model.waitForCurrentTask()
        await oldAppendGate.open()
        await oldAppendTask.value

        guard case .loaded(.search(let query, let page)) = model.state else {
            Issue.record("新条件应保持 loaded")
            return
        }
        #expect(query == "macOS")
        #expect(page.pageNumber == 1)
        #expect(page.videos.map(\.bvid) == [fresh.bvid])
        #expect(
            model.activeRequestIdentity
                == .search(
                    VideoSearchRequest(criteria: newCriteria, page: 1)
                )
        )
        #expect(model.searchPagination(for: newCriteria).loadMoreError == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func authenticationEpochRestartsSearchAndRejectsLateOldResult() async throws {
        let old = GuestFixtures(bvid: "BV1SearchG07", title: "旧账户结果")
        let fresh = GuestFixtures(bvid: "BV1SearchH08", title: "新账户结果")
        let gates = [TestGate(), TestGate()]
        let repository = FeedRepositoryStub(search: { _, attempt in
            await gates[attempt - 1].pass()
            return (attempt == 1 ? old : fresh).searchPage()
        })
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.search("macOS")
        try await gates[0].waitForEntries()
        let oldTask = try #require(model.taskSnapshotForTesting())

        model.synchronizeAuthenticationSession(generation: 1)
        try await gates[1].waitForEntries()
        await gates[1].open()
        await model.waitForCurrentTask()

        model.synchronizeAuthenticationSession(generation: 1)
        await gates[0].open()
        await oldTask.value

        guard case .loaded(.search(let query, let page)) = model.state else {
            Issue.record("账户切换后的搜索结果应保持 loaded")
            return
        }
        #expect(query == "macOS")
        #expect(page.videos.map(\.bvid) == [fresh.bvid])
        #expect(await repository.searchRequests.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func authenticationEpochRestartsPopularAndRejectsLateOldResult() async throws {
        let old = GuestFixtures(bvid: "BV1PopularOld", title: "旧账户热门")
        let fresh = GuestFixtures(bvid: "BV1PopularNew", title: "新账户热门")
        let gates = [TestGate(), TestGate()]
        let repository = FeedRepositoryStub(popular: { request, attempt in
            await gates[attempt - 1].pass()
            return (attempt == 1 ? old : fresh).popularPage(request)
        })
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        try await gates[0].waitForEntries()
        let oldTask = try #require(model.taskSnapshotForTesting())

        model.synchronizeAuthenticationSession(generation: 1)
        try await gates[1].waitForEntries()
        await gates[1].open()
        await model.waitForCurrentTask()

        model.synchronizeAuthenticationSession(generation: 1)
        await gates[0].open()
        await oldTask.value

        guard case .loaded(.popular(let page)) = model.state else {
            Issue.record("账户切换后的热门结果应保持 loaded")
            return
        }
        #expect(page.videos.map(\.bvid) == [fresh.bvid])
        #expect(await repository.popularPages.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func authenticationEpochRestartsRecommendationAndRejectsLateOldResult() async throws {
        let old = GuestFixtures(bvid: "BV1RcmdOld01", title: "旧账户推荐")
        let fresh = GuestFixtures(bvid: "BV1RcmdNew02", title: "新账户推荐")
        let gates = [TestGate(), TestGate()]
        let repository = FeedRepositoryStub(recommendations: { _, attempt in
            await gates[attempt - 1].pass()
            return (attempt == 1 ? old : fresh).recommendationPage
        })
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.activateRecommendation()
        try await gates[0].waitForEntries()
        let oldTask = try #require(model.taskSnapshotForTesting())

        model.synchronizeAuthenticationSession(generation: 1)
        try await gates[1].waitForEntries()
        await gates[1].open()
        await model.waitForCurrentTask()

        model.synchronizeAuthenticationSession(generation: 1)
        await gates[0].open()
        await oldTask.value

        guard case .loaded(.recommendation(let page)) = model.state else {
            Issue.record("账户切换后的首页推荐应保持 loaded")
            return
        }
        #expect(page.videos.map(\.bvid) == [fresh.bvid])
        #expect(await repository.recommendationRequests.count == 2)
    }

    @Test
    @MainActor
    func tabRoundTripReusesPopularAndSearchWorksetsWithoutNewRequests() async {
        let fixture = GuestFixtures()
        let repository = FeedRepositoryStub(
            popular: { request, _ in fixture.popularPage(request) },
            search: { request, _ in fixture.searchPage(page: request.page) }
        )
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

        #expect(await repository.popularPages.count == 1)
        #expect(await repository.searchRequests.count == 1)
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
        let repository = FeedRepositoryStub.popularPagination(
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
        #expect(await repository.popularPages.count == 2)
    }

    @Test
    @MainActor
    func failedRefreshKeepsMatchingLoadedContentVisible() async {
        let fixture = GuestFixtures()
        let repository = FeedRepositoryStub(popular: { request, attempt in
            if attempt == 2 { throw GuestApplicationError.requestRestricted }
            return fixture.popularPage(request)
        })
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        let loadedState = model.state
        let successfulRefreshGeneration =
            model.popularSuccessfulRefreshGeneration

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
        #expect(await repository.popularPages.count == 2)
    }

    @Test
    @MainActor
    func onlySuccessfulSameQueryRefreshAdvancesSearchGeneration() async {
        let fixture = GuestFixtures()
        let repository = FeedRepositoryStub(search: { request, attempt in
            if attempt == 3 { throw GuestApplicationError.requestRestricted }
            return fixture.searchPage(page: request.page)
        })
        let model = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )

        model.search("macOS")
        await model.waitForCurrentTask()
        #expect(model.searchSuccessfulRefreshGeneration == 0)

        model.search("macOS")
        await model.waitForCurrentTask()
        #expect(model.searchSuccessfulRefreshGeneration == 1)

        model.search("macOS")
        #expect(model.isRefreshing)
        await model.waitForCurrentTask()

        #expect(model.searchSuccessfulRefreshGeneration == 1)
        #expect(model.refreshError == .requestRestricted)
        #expect(await repository.searchRequests.count == 3)
    }

    @Test
    @MainActor
    func resetClearsWorksetsAndRequiresANewLoad() async {
        let fixture = GuestFixtures()
        let repository = FeedRepositoryStub(
            popular: { request, _ in fixture.popularPage(request) },
            search: { request, _ in fixture.searchPage(page: request.page) }
        )
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
        #expect(await repository.popularPages.count == 2)
    }

    @Test
    @MainActor
    func authenticatedResumeSelectsRecordedPartBeforeStartingAndCanRestart()
        async throws
    {
        let fixture = GuestFixtures()
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
                repository: VideoRepositoryStub(fixture)
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
        let metadata = try #require(
            PlaybackResumeMetadata(
                lastPlayedCID: 900_001,
                positionMilliseconds: positionMilliseconds
            )
        )
        let repository = VideoRepositoryStub(
            fixture,
            playback: { _, _ in fixture.playback(resuming: metadata) }
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
        let useCase = GuestVideoUseCase(repository: repository)
        let initial = try await useCase.prepareVideo(bvid: fixture.bvid)

        let selected = try await useCase.preparePage(in: initial, cid: 900_002)

        #expect(selected.selectedPage.cid == 900_002)
        #expect(selected.resumePositionSeconds == nil)
    }

    @Test
    @MainActor
    func playbackFailureRetainsTheNewPresentedContext() async {
        let first = GuestFixtures(bvid: "BV1PresentedA", title: "视频 A")
        let replacement = GuestFixtures(
            bvid: "BV1PresentedB",
            title: "视频 B"
        )
        let repository = VideoRepositoryStub(fixtures: [first, replacement])
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
        let repository = VideoRepositoryStub(
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
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: repository
            ),
            playback: player
        )

        model.loadVideo(slow.detail.bvid)
        // `/view` 先返回后才决定是否需要 pagelist，因此旧请求此时只有 detail 在飞行。
        try await slowGate.waitForEntries(1)
        let supersededTask = try #require(model.taskSnapshotForTesting())
        model.loadVideo(fast.detail.bvid)
        await model.waitForCurrentTask()
        await slowGate.open()
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
        let repository = VideoRepositoryStub(fixture, pages: fixture.twoPages)
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
        let repository = VideoRepositoryStub(
            fixture,
            pages: fixture.twoPages,
            playback: { identity, attempt in
                if identity.cid == 900_002, attempt == 1 {
                    throw GuestApplicationError.transportFailure
                }
                return fixture.playback
            }
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
        let fixture = GuestFixtures()
        let repository = VideoRepositoryStub(fixture, pages: fixture.twoPages)
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
        let repository = VideoRepositoryStub(fixture, pages: fixture.twoPages)
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
        let repository = VideoRepositoryStub(fixture, pages: fixture.twoPages)
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
        let secondPageGate = TestGate()
        let repository = VideoRepositoryStub(
            fixture,
            pages: fixture.twoPages,
            playback: { identity, _ in
                guard identity.cid == 900_002 else { return fixture.playback }
                await secondPageGate.pass()
                throw GuestApplicationError.authenticationInvalid
            }
        )
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: RecordingPlayerEngine()
        )
        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()

        model.selectPage(cid: 900_002)
        try await secondPageGate.waitForEntries()
        let supersededTask = try #require(model.taskSnapshotForTesting())
        model.selectPage(cid: 900_001)
        await model.waitForCurrentTask()
        await secondPageGate.open()
        await supersededTask.value

        #expect(model.authenticationRevalidationGeneration == 0)
        #expect(model.presentedPlaybackIdentity?.cid == 900_001)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func rapidPageABARejectsTheLateSupersededResult() async throws {
        let fixture = GuestFixtures()
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
        let player = RecordingPlayerEngine()
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: player
        )
        model.loadVideo(fixture.bvid)
        await model.waitForCurrentTask()

        model.selectPage(cid: 900_002)
        try await secondPageGate.waitForEntries()
        let supersededP2 = try #require(model.taskSnapshotForTesting())

        model.selectPage(cid: 900_001)
        try await firstPageGate.waitForEntries()
        await firstPageGate.open()
        await model.waitForCurrentTask()
        await secondPageGate.open()
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
                repository: VideoRepositoryStub(fixture)
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
                repository: VideoRepositoryStub(fixture)
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
                repository: VideoRepositoryStub(fixture)
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
                repository: VideoRepositoryStub(fixture)
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
                repository: VideoRepositoryStub(fixture, pages: fixture.twoPages)
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
                repository: VideoRepositoryStub(fixtures: [first, second])
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
                repository: VideoRepositoryStub(fixture)
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
        let model = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: VideoRepositoryStub(
                    detail: { _, _ in fixtures.detail },
                    pages: { _, _ in fixtures.detail.pages },
                    playback: { _, _ in fixtures.playback }
                )
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

private actor CollectionEpisodeRepositoryStub: GuestVideoRepository {
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
private actor FeedRepositoryStub: GuestFeedRepository {
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
            recommendations ?? { _, _ in throw GuestApplicationError.unavailable }
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
    /// 两页热门：第 1 页含重复卡片，第 2 页补上 `second`。
    static func popularPagination(
        first: GuestFixtures,
        second: GuestFixtures,
        failsFirstSecondPage: Bool = false
    ) -> FeedRepositoryStub {
        FeedRepositoryStub(popular: { request, attempt in
            switch request.page {
            case 1:
                return PopularPage(
                    videos: [first.popularVideo, first.popularVideo],
                    pageNumber: 1,
                    pageSize: request.pageSize,
                    hasMore: true
                )
            case 2:
                if failsFirstSecondPage, attempt == 1 {
                    throw GuestApplicationError.requestRestricted
                }
                return PopularPage(
                    videos: [first.popularVideo, second.popularVideo],
                    pageNumber: 2,
                    pageSize: request.pageSize,
                    hasMore: false
                )
            default:
                throw GuestApplicationError.invalidRequest
            }
        })
    }

    /// 两页搜索：第 1 页含重复卡片，第 2 页补上 `second`。
    static func searchPagination(
        first: GuestFixtures,
        second: GuestFixtures,
        failsFirstSecondPage: Bool = false
    ) -> FeedRepositoryStub {
        FeedRepositoryStub(search: { request, attempt in
            switch request.page {
            case 1:
                return SearchPage(
                    videos: [first.searchVideo, first.searchVideo],
                    pageNumber: 1,
                    pageSize: 20,
                    totalResults: 2,
                    totalPages: 2
                )
            case 2:
                if failsFirstSecondPage, attempt == 1 {
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
        })
    }

    /// 旧查询或旧条件的第 2 页在 `oldAppendGate` 放行前挂起；其余请求立即返回第 1 页。
    static func blockingSearchAppend(
        old: GuestFixtures,
        fresh: GuestFixtures,
        oldAppendGate: TestGate
    ) -> FeedRepositoryStub {
        FeedRepositoryStub(search: { request, _ in
            let keyword = request.criteria.query
            let isOldCriteria = request.criteria.order == .relevance
            if keyword == "旧查询" || keyword == "macOS", request.page == 2,
                isOldCriteria
            {
                await oldAppendGate.pass()
                return SearchPage(
                    videos: [old.searchVideo],
                    pageNumber: 2,
                    pageSize: 20,
                    totalResults: 2,
                    totalPages: 2
                )
            }
            let usesOldResult =
                keyword == "旧查询" || (keyword == "macOS" && isOldCriteria)
            return SearchPage(
                videos: [(usesOldResult ? old : fresh).searchVideo],
                pageNumber: 1,
                pageSize: 20,
                totalResults: usesOldResult ? 2 : 1,
                totalPages: usesOldResult ? 2 : 1
            )
        })
    }
}

/// 游客视频 port 的共享替身；`attempt` 语义与 `FeedRepositoryStub` 相同。
private actor VideoRepositoryStub: GuestVideoRepository {
    typealias Response<Request, Value> = FeedRepositoryStub.Response<Request, Value>

    private let detailResponse: Response<String, VideoDetail>
    private let pagesResponse: Response<String, [VideoPage]>
    private let playbackResponse: Response<PlaybackItemIdentity, VideoPlayback>
    private var detailRequests: [String] = []
    private var pageRequests: [String] = []
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
        _ fixture: GuestFixtures,
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
    init(fixtures: [GuestFixtures], cancelledBVID: String? = nil) {
        let fixturesByBVID = Dictionary(
            uniqueKeysWithValues: fixtures.map { ($0.bvid, $0) }
        )
        let fixture: @Sendable (String) throws -> GuestFixtures = { bvid in
            guard let fixture = fixturesByBVID[bvid] else {
                throw GuestApplicationError.invalidResponse
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

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        detailRequests.append(bvid)
        return try await detailResponse(bvid, detailRequests.filter { $0 == bvid }.count)
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        pageRequests.append(bvid)
        return try await pagesResponse(bvid, pageRequests.filter { $0 == bvid }.count)
    }

    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        let identity = PlaybackItemIdentity(bvid: bvid, cid: cid)
        playbackRequests.append(identity)
        let attempt = playbackRequests.filter { $0 == identity }.count
        return try await playbackResponse(identity, attempt)
    }
}

/// 让替身中的请求挂起到测试放行；放行后后续请求直接通过。
private actor TestGate {
    private let entries = TestEventCounter()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        await entries.signal()
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// 等到第 `count` 个请求进入；等待失败时先放行，避免挂起的请求拖住测试。
    func waitForEntries(_ count: Int = 1) async throws {
        do {
            try await entries.wait(until: count)
        } catch {
            open()
            throw error
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
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
