import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

/// 推荐、热门与搜索的来源分页：各来源怎样构造下一页请求、校验响应衔接，以及无新增即停止；去重、上限、
/// 回环与尾标的通用规则由 `PagedVideoListTests` 固定。
@Suite(.timeLimit(.minutes(1)))
struct FeedPagingTests {
    @Test
    @MainActor
    func recommendationBatchesAppendDeduplicateAndStopWithoutProgress() async {
        let first = ContentFixtures(bvid: "BV1RcmdOneA", title: "推荐一")
        let second = ContentFixtures(bvid: "BV1RcmdTwoB", title: "推荐二")
        let repository = FeedRepositoryStub(recommendations: { continuation, _ in
            let index = continuation?.index ?? 1
            let videos: [RecommendedVideo]
            switch index {
            case 1: videos = [first.recommendedVideo, first.recommendedVideo]
            case 2: videos = [first.recommendedVideo, second.recommendedVideo]
            case 3: videos = [second.recommendedVideo]
            default: throw ContentApplicationError.invalidRequest
            }
            return RecommendationPage(
                videos: videos,
                continuation: continuation,
                nextContinuation: RecommendationContinuation(index: index + 1)
            )
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )
        let request = FeedRequest.recommendation(continuation: nil)

        model.activateRecommendation()
        await model.waitForCurrentTask()
        #expect(model.pagination(for: request).canLoadMore)

        model.loadMore(.recommendation)
        await model.waitForCurrentTask()
        #expect(BrowseFeed.recommendation.loadedBVIDs(model) == [first.bvid, second.bvid])
        #expect(model.pagination(for: request).canLoadMore)

        model.loadMore(.recommendation)
        await model.waitForCurrentTask()
        #expect(BrowseFeed.recommendation.loadedBVIDs(model) == [first.bvid, second.bvid])
        #expect(!model.pagination(for: request).canLoadMore)

        model.loadMore(.recommendation)
        await model.waitForCurrentTask()
        #expect(
            await repository.recommendationRequests == [
                nil,
                RecommendationContinuation(index: 2),
                RecommendationContinuation(index: 3)
            ]
        )
    }

    /// 推荐批次的 continuation 与所请求的不符时按无效响应记为加载失败，已显示卡片不变，重试仍请求同一批。
    @Test
    @MainActor
    func recommendationBatchThatDoesNotContinueTheRequestIsInvalid() async {
        let first = ContentFixtures(bvid: "BV1RcmdC3", title: "第一批")
        let stray = ContentFixtures(bvid: "BV1RcmdD4", title: "错位批次")
        let repository = FeedRepositoryStub(recommendations: { continuation, _ in
            guard continuation != nil else { return first.recommendationPage }
            return RecommendationPage(
                videos: [stray.recommendedVideo],
                continuation: RecommendationContinuation(index: 5),
                nextContinuation: RecommendationContinuation(index: 6)
            )
        })
        let model = BrowseViewModel(useCase: FeedUseCase(repository: repository))
        let request = FeedRequest.recommendation(continuation: nil)

        model.activateRecommendation()
        await model.waitForCurrentTask()
        model.loadMore(.recommendation)
        await model.waitForCurrentTask()

        #expect(BrowseFeed.recommendation.loadedBVIDs(model) == [first.bvid])
        #expect(model.pagination(for: request).loadMoreError == .invalidResponse)
        #expect(!model.pagination(for: request).canLoadMore)

        model.loadMore(.recommendation)
        await model.waitForCurrentTask()
        #expect(
            await repository.recommendationRequests == [
                nil,
                RecommendationContinuation(index: 2),
                RecommendationContinuation(index: 2)
            ]
        )
    }

    /// 热门与搜索的下一页没有新条目时停止翻页，不再请求。
    @Test(arguments: [BrowseFeed.popular, .search])
    @MainActor
    func nonProgressingPageStopsPagination(_ feed: BrowseFeed) async {
        let fixture = ContentFixtures(bvid: "BV1PopularE5", title: "重复卡片")
        let repository = FeedRepositoryStub(
            popular: { request, _ in fixture.popularPage(request, hasMore: true) },
            search: { request, _ in
                SearchPage(
                    videos: [fixture.searchVideo],
                    pageNumber: request.page,
                    pageSize: request.criteria.pageSize,
                    totalResults: 60,
                    totalPages: 3
                )
            }
        )
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        feed.activate(model)
        await model.waitForCurrentTask()
        feed.loadMore(model)
        await model.waitForCurrentTask()
        feed.loadMore(model)
        await model.waitForCurrentTask()

        #expect(feed.loadedBVIDs(model) == [fixture.bvid])
        #expect(!feed.pagination(model).canLoadMore)
        #expect(feed.pagination(model).loadMoreError == nil)
        #expect(await repository.requestedPages(feed) == [1, 2])
    }

    /// 搜索首页没有可显示条目时与推荐、热门一样停止翻页，即使接口报告还有更多页。
    @Test
    @MainActor
    func emptySearchFirstPageStopsPaginationDespiteRemainingPages() async {
        let repository = FeedRepositoryStub(search: { request, _ in
            SearchPage(
                videos: [],
                pageNumber: request.page,
                pageSize: request.criteria.pageSize,
                totalResults: 40,
                totalPages: 2
            )
        })
        let model = BrowseViewModel(useCase: FeedUseCase(repository: repository))
        let criteria = VideoSearchCriteria(query: "空首页")
        let request = FeedRequest.search(VideoSearchRequest(criteria: criteria, page: 1))

        model.activateSearch(criteria)
        await model.waitForCurrentTask()
        model.loadMore(.search)
        await model.waitForCurrentTask()

        #expect(BrowseFeed.search.loadedBVIDs(model).isEmpty)
        #expect(!model.pagination(for: request).canLoadMore)
        #expect(await repository.searchRequests.map(\.page) == [1])
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
        #expect(firstTail.tailIdentity != nil)

        feed.loadMore(model)
        feed.loadMore(model)
        await model.waitForCurrentTask()

        #expect(feed.loadedBVIDs(model) == [first.bvid, second.bvid])
        #expect(await repository.requestedPages(feed) == [1, 2])
        #expect(!feed.pagination(model).canLoadMore)
    }

    /// 加载更多失败保留卡片并暂停自动加载（没有尾标）；底部重试走同一入口，只重新请求失败的那一页。
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

        feed.loadMore(model)
        await model.waitForCurrentTask()
        let failed = feed.pagination(model)
        #expect(feed.loadedBVIDs(model) == [first.bvid])
        #expect(failed.loadMoreError == .transportFailure)
        #expect(!failed.canLoadMore)
        #expect(failed.tailIdentity == nil)

        feed.loadMore(model)
        await model.waitForCurrentTask()

        #expect(feed.loadedBVIDs(model) == [first.bvid, second.bvid])
        #expect(await repository.requestedPages(feed) == [1, 2, 2])
        #expect(
            await repository.searchRequests.allSatisfy { $0.criteria == BrowseFeed.searchCriteria }
        )
    }

    /// 下一页的页码与请求不符时按无效响应记为加载失败，已显示卡片不变，重试仍请求同一页。
    @Test(arguments: [BrowseFeed.popular, .search])
    @MainActor
    func appendedPageThatDoesNotMatchTheRequestIsInvalid(_ feed: BrowseFeed) async {
        let fixture = ContentFixtures(bvid: "BV1PagedE5", title: "第一页")
        let stray = ContentFixtures(bvid: "BV1PagedF6", title: "错位页")
        let repository = FeedRepositoryStub(
            popular: { request, _ in
                PopularPage(
                    videos: [(request.page == 1 ? fixture : stray).popularVideo],
                    pageNumber: request.page == 1 ? 1 : 3,
                    pageSize: request.pageSize,
                    hasMore: true
                )
            },
            search: { request, _ in
                SearchPage(
                    videos: [(request.page == 1 ? fixture : stray).searchVideo],
                    pageNumber: request.page == 1 ? 1 : 3,
                    pageSize: request.criteria.pageSize,
                    totalResults: 60,
                    totalPages: 3
                )
            }
        )
        let model = BrowseViewModel(useCase: FeedUseCase(repository: repository))

        feed.activate(model)
        await model.waitForCurrentTask()
        feed.loadMore(model)
        await model.waitForCurrentTask()

        #expect(feed.loadedBVIDs(model) == [fixture.bvid])
        #expect(feed.pagination(model).loadMoreError == .invalidResponse)
        #expect(!feed.pagination(model).canLoadMore)

        feed.loadMore(model)
        await model.waitForCurrentTask()
        #expect(await repository.requestedPages(feed) == [1, 2, 2])
    }
}
