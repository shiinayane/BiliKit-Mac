import BiliApplication
import BiliModels
import Foundation
import Testing

struct GuestFeedUseCaseTests {
    @Test
    func rejectsInvalidFeedRequestWithoutCallingRepository() async {
        let repository = FeedRepositoryStub()
        let useCase = GuestFeedUseCase(repository: repository)

        await #expect(throws: GuestApplicationError.invalidRequest) {
            try await useCase.execute(.search(query: "   ", page: 1))
        }
        #expect(await repository.searchRequests.isEmpty)
    }

    @Test
    func forwardsCompleteSearchCriteriaAndRejectsInvalidRange() async throws {
        let repository = FeedRepositoryStub()
        let useCase = GuestFeedUseCase(repository: repository)
        let criteria = VideoSearchCriteria(
            query: "  macOS  ",
            order: .mostDanmaku,
            duration: .tenToThirtyMinutes,
            publicationRange: VideoPublicationTimeRange(
                beginTimestamp: 100,
                endTimestamp: 200
            )
        )

        _ = try await useCase.execute(
            .search(VideoSearchRequest(criteria: criteria, page: 2))
        )
        #expect(
            await repository.searchRequests
                == [VideoSearchRequest(criteria: criteria, page: 2)]
        )

        let invalid = VideoSearchCriteria(
            query: "macOS",
            publicationRange: VideoPublicationTimeRange(
                beginTimestamp: 201,
                endTimestamp: 200
            )
        )
        await #expect(throws: GuestApplicationError.invalidRequest) {
            try await useCase.execute(
                .search(VideoSearchRequest(criteria: invalid, page: 1))
            )
        }
        #expect(await repository.searchRequests.count == 1)
    }
}

private actor FeedRepositoryStub: GuestFeedRepository {
    private(set) var searchRequests: [VideoSearchRequest] = []

    func recommendations(
        after continuation: RecommendationContinuation?
    ) async throws -> RecommendationPage {
        throw GuestApplicationError.unavailable
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [], pageNumber: page, pageSize: pageSize)
    }

    func searchVideos(request: VideoSearchRequest) async throws -> SearchPage {
        searchRequests.append(request)
        return SearchPage(
            videos: [],
            pageNumber: request.page,
            pageSize: request.criteria.pageSize,
            totalResults: 0,
            totalPages: 0
        )
    }
}
