import BiliApplication
import BiliModels
import Foundation
import Testing

/// UP 主投稿页去掉同页重复的 BVID 并保留分页信息，非正的 UP 主 ID 或页码不发请求。
@Suite(.timeLimit(.minutes(1)))
struct UploaderVideoUseCaseTests {
    @Test
    func dropsDuplicateBVIDsWithinThePageAndKeepsPaging() async throws {
        let first = video("BV1FixtureA1")
        let second = video("BV1FixtureB2")
        let useCase = UploaderVideoUseCase(
            repository: UploaderVideoRepositoryStub(
                page: UploaderVideoPage(
                    videos: [first, second, first],
                    pageNumber: 2,
                    pageSize: 30,
                    totalCount: 61
                )
            )
        )

        let page = try await useCase.page(ownerID: 10_001, order: .newest, page: 2)

        #expect(page.videos == [first, second])
        #expect(page.pageNumber == 2)
        #expect(page.pageSize == 30)
        #expect(page.totalCount == 61)
    }

    @Test(arguments: [(0, 1), (10_001, 0)] as [(Int64, Int)])
    func invalidInputNeverReachesTheRepository(ownerID: Int64, page: Int) async {
        let repository = UploaderVideoRepositoryStub(
            page: UploaderVideoPage(videos: [], pageNumber: 1, pageSize: 30, totalCount: 0)
        )
        let useCase = UploaderVideoUseCase(repository: repository)

        await #expect(throws: ContentApplicationError.invalidRequest) {
            try await useCase.page(ownerID: ownerID, order: .newest, page: page)
        }
        #expect(await repository.callCount == 0)
    }

    private func video(_ bvid: String) -> UploaderVideo {
        UploaderVideo(
            bvid: bvid,
            title: bvid,
            coverURL: nil,
            durationSeconds: nil,
            viewCount: nil,
            danmakuCount: nil,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isCollaboration: false
        )
    }
}

private actor UploaderVideoRepositoryStub: UploaderVideoRepository {
    let page: UploaderVideoPage
    private(set) var callCount = 0

    init(page: UploaderVideoPage) {
        self.page = page
    }

    func uploaderVideos(
        ownerID: Int64,
        order: UploaderVideoOrder,
        page: Int
    ) async throws -> UploaderVideoPage {
        callCount += 1
        return self.page
    }
}
