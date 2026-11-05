import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

/// Feed 的凭据失效请求窗口复核（追加失败保留卡片）；复核确认仍登录或确认未登录后，停在凭据失败页的来源自动重载至多
/// 一次；账户代次变化重启当前来源并丢弃旧账户的迟到结果。
@Suite(.timeLimit(.minutes(1)))
struct FeedAuthenticationTests {
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

    /// 复核的三种结果：确认仍登录、确认未登录（启动时首页先删掉了坏凭据，账户范围不变）、没能确认。
    enum RevalidationOutcome: CaseIterable {
        case signedIn, signedOut, failed
    }

    @Test(arguments: RevalidationOutcome.allCases)
    @MainActor
    func failedPageReloadsAtMostOnceAfterRevalidationConcludes(
        outcome: RevalidationOutcome
    ) async {
        let fixture = ContentFixtures(bvid: "BV1Revalid01", title: "复核后重载")
        let repository = FeedRepositoryStub(recommendations: { _, attempt in
            guard attempt == 3 else { throw ContentApplicationError.authenticationInvalid }
            return fixture.recommendationPage
        })
        let model = BrowseViewModel(useCase: FeedUseCase(repository: repository))
        let deliver = {
            switch outcome {
            case .signedIn: model.authenticationRevalidationSucceeded()
            case .signedOut: model.authenticationRevalidationConfirmedSignedOut()
            case .failed: model.authenticationRevalidationFailed()
            }
        }

        model.activateRecommendation()
        await model.waitForCurrentTask()
        deliver()
        await model.waitForCurrentTask()
        // 重载后仍失败：再请求一次复核，但同一次失败页不再自动重载，挡住“复核 → 重载 → 失效”的循环。
        deliver()
        await model.waitForCurrentTask()

        let expectedRequests = outcome == .failed ? 1 : 2
        #expect(await repository.recommendationRequests.count == expectedRequests)
        #expect(model.authenticationRevalidationGeneration == expectedRequests)
        #expect(
            model.state
                == .failed(
                    request: .recommendation(continuation: nil),
                    error: .authenticationInvalid
                )
        )
    }

    @Test(arguments: [BrowseFeed.recommendation, .popular, .search])
    @MainActor
    func tailAuthenticationFailureKeepsCardsAndRequestsRevalidation(_ feed: BrowseFeed) async {
        let fixture = ContentFixtures(bvid: "BV1AuthTail1", title: "认证追加")
        let repository = FeedRepositoryStub(
            recommendations: { continuation, _ in
                guard continuation == nil else {
                    throw ContentApplicationError.authenticationInvalid
                }
                return fixture.recommendationPage
            },
            popular: { request, _ in
                guard request.page == 1 else {
                    throw ContentApplicationError.authenticationInvalid
                }
                return fixture.popularPage(request, hasMore: true)
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

        feed.activate(model)
        await model.waitForCurrentTask()
        feed.loadMore(model)
        await model.waitForCurrentTask()

        #expect(feed.loadedBVIDs(model) == [fixture.bvid])
        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(feed.pagination(model).loadMoreError == .authenticationInvalid)
        #expect(await repository.requestedPages(feed) == [1, 2])
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
}
