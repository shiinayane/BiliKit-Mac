import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

/// 各来源的工作集：新意图取消旧请求，切换来源保留各自结果不重复请求，重试沿用原请求，reset 后需重新加载。
@Suite(.timeLimit(.minutes(1)))
struct FeedWorksetTests {
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
        model.refreshPopular(pageSize: 50)
        try await searchGate.waitForCancellations()
        await model.waitForCurrentTask()
        await searchGate.open()

        #expect(model.activeRequestIdentity == .popular(page: 1, pageSize: 50))
        #expect(BrowseFeed.popular.loadedBVIDs(model) == [fixture.bvid])
    }

    @Test
    @MainActor
    func failedSearchRetriesItsOriginalRequest() async {
        let fixture = ContentFixtures()
        let model = BrowseViewModel(
            useCase: FeedUseCase(
                repository: FeedRepositoryStub(search: { request, attempt in
                    if attempt == 1 {
                        throw ContentApplicationError.requestRestricted(.httpStatus412)
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
                    error: .requestRestricted(.httpStatus412)
                )
        )

        model.retry(.search(query: "macOS", page: 1))
        await model.waitForCurrentTask()
        guard case .loaded(.search(let query, _)) = model.state else {
            Issue.record("重试后搜索应为 loaded")
            return
        }
        #expect(query == "macOS")
        #expect(BrowseFeed.search.loadedBVIDs(model) == [fixture.bvid])
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

        guard case .loaded(.search(let query, _)) = model.state else {
            Issue.record("新搜索应保持 loaded")
            return
        }
        #expect(query == newCriteria.query)
        #expect(BrowseFeed.search.loadedBVIDs(model) == [fresh.bvid])
        #expect(
            model.activeRequestIdentity
                == .search(VideoSearchRequest(criteria: newCriteria, page: 1))
        )
        #expect(
            model.pagination(for: .search(VideoSearchRequest(criteria: newCriteria, page: 1)))
                .loadMoreError == nil
        )
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
            BrowseFeed.search.loadedBVIDs(
                in: model.presentation(for: .search(query: "macOS", page: 1)).state
            ) == [searchFixture.bvid]
        )
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
}
