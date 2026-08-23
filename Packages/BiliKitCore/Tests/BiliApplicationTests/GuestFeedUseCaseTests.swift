import BiliApplication
import BiliModels
import Foundation
import Testing

struct GuestFeedUseCaseTests {
    @Test
    func normalizesSearchBeforeCallingRepository() async throws {
        let repository = FeedRepositoryStub()
        let useCase = GuestFeedUseCase(repository: repository)

        let content = try await useCase.execute(
            .search(query: "  macOS  ", page: 2)
        )

        #expect(
            content
                == .search(
                    query: "macOS",
                    page: SearchPage(
                        videos: [],
                        pageNumber: 2,
                        pageSize: 20,
                        totalResults: 0,
                        totalPages: 0
                    )
                )
        )
        #expect(await repository.searchQueries() == ["macOS"])
    }

    @Test
    func rejectsInvalidFeedRequestWithoutCallingRepository() async {
        let repository = FeedRepositoryStub()
        let useCase = GuestFeedUseCase(repository: repository)

        await #expect(throws: GuestApplicationError.invalidRequest) {
            try await useCase.execute(.search(query: "   ", page: 1))
        }
        #expect(await repository.searchQueries().isEmpty)
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
            await repository.searchRequests()
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
        #expect(await repository.searchRequests().count == 1)
    }
}

private actor FeedRepositoryStub: GuestContentRepository {
    private var observedSearchQueries: [String] = []
    private var observedSearchRequests: [VideoSearchRequest] = []

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [], pageNumber: page, pageSize: pageSize)
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        observedSearchQueries.append(keyword)
        return SearchPage(
            videos: [],
            pageNumber: page,
            pageSize: 20,
            totalResults: 0,
            totalPages: 0
        )
    }

    func searchVideos(request: VideoSearchRequest) async throws -> SearchPage {
        observedSearchRequests.append(request)
        observedSearchQueries.append(request.criteria.query)
        return SearchPage(
            videos: [],
            pageNumber: request.page,
            pageSize: request.criteria.pageSize,
            totalResults: 0,
            totalPages: 0
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        throw GuestApplicationError.unavailable
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        throw GuestApplicationError.unavailable
    }

    func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        throw GuestApplicationError.unavailable
    }

    func searchQueries() -> [String] {
        observedSearchQueries
    }

    func searchRequests() -> [VideoSearchRequest] {
        observedSearchRequests
    }
}
