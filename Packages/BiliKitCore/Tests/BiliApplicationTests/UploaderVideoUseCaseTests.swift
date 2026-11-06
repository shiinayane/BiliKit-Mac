import BiliApplication
import BiliModels
import Foundation
import Testing

/// 非正的 UP 主 ID 不发请求；跨批去重与到底判断归调用方的 `PagedVideoList`，不在这里。
@Suite(.timeLimit(.minutes(1)))
struct UploaderVideoUseCaseTests {
    @Test(arguments: [0, -1] as [Int64])
    func invalidOwnerNeverReachesTheRepository(ownerID: Int64) async {
        let repository = UploaderVideoRepositoryStub()
        let useCase = UploaderVideoUseCase(repository: repository)

        await #expect(throws: ContentApplicationError.invalidRequest) {
            try await useCase.batch(ownerID: ownerID, order: .newest, after: nil)
        }
        #expect(await repository.callCount == 0)
    }
}

private actor UploaderVideoRepositoryStub: UploaderVideoRepository {
    private(set) var callCount = 0

    func uploaderVideos(
        ownerID: Int64,
        order: UploaderVideoOrder,
        after cursor: UploaderVideoCursor?
    ) async throws -> UploaderVideoBatch {
        callCount += 1
        return UploaderVideoBatch(videos: [], nextCursor: nil, totalCount: 0)
    }
}
