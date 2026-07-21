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
            content == .search(
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
}

private actor FeedRepositoryStub: GuestContentRepository {
    private var observedSearchQueries: [String] = []

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

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        throw GuestApplicationError.unavailable
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        throw GuestApplicationError.unavailable
    }

    func playback(
        for bvid: String,
        cid: Int64,
        quality: Int
    ) async throws -> VideoPlayback {
        throw GuestApplicationError.unavailable
    }

    func searchQueries() -> [String] {
        observedSearchQueries
    }
}
