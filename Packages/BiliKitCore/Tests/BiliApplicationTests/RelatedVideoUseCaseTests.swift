import BiliApplication
import BiliModels
import Testing

struct RelatedVideoUseCaseTests {
    @Test
    func removesCurrentVideoAndDuplicatesWithoutChangingRemoteOrder() async throws {
        let current = RelatedVideo.fixture(bvid: "BV1CurrentAA1")
        let first = RelatedVideo.fixture(bvid: "BV1RelatedA1")
        let second = RelatedVideo.fixture(bvid: "BV1RelatedB2")
        let useCase = RelatedVideoUseCase(
            repository: RelatedVideoRepositoryStub(
                videos: [current, first, first, second]
            )
        )

        let videos = try await useCase.relatedVideos(to: current.bvid)

        #expect(videos == [first, second])
    }

    @Test
    func currentVideoOnlyBecomesEmptyResult() async throws {
        let current = RelatedVideo.fixture(bvid: "BV1CurrentAA1")
        let useCase = RelatedVideoUseCase(
            repository: RelatedVideoRepositoryStub(videos: [current])
        )

        let videos = try await useCase.relatedVideos(to: current.bvid)

        #expect(videos.isEmpty)
    }
}

private struct RelatedVideoRepositoryStub: RelatedVideoRepository {
    let videos: [RelatedVideo]

    func relatedVideos(to bvid: String) async throws -> [RelatedVideo] {
        videos
    }
}

extension RelatedVideo {
    fileprivate static func fixture(bvid: String) -> RelatedVideo {
        RelatedVideo(
            bvid: bvid,
            title: "合成推荐",
            coverURL: nil,
            ownerName: "测试作者",
            viewCount: 10,
            danmakuCount: 1,
            durationSeconds: 120
        )
    }
}
