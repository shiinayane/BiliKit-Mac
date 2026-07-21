import BiliApplication
import BiliModels
import Foundation
import Testing

struct GuestVideoUseCaseTests {
    @Test
    func resolvesDetailPagesAndPlaybackForFirstOrderedPage() async throws {
        let repository = GuestRepositoryStub()
        let useCase = GuestVideoUseCase(repository: repository)

        let context = try await useCase.prepareVideo(bvid: "BV1FixtureA1")

        #expect(context.detail.bvid == "BV1FixtureA1")
        #expect(context.pages.map(\.index) == [1, 2])
        #expect(context.selectedPage.index == 1)
        #expect(context.playback.manifest.videoRepresentations.first?.id == 32)
        #expect(await repository.playbackCIDs() == [900_001])
    }

    @Test
    func rejectsVideoWithoutPagesBeforeRequestingPlayback() async {
        let repository = GuestRepositoryStub(hasPages: false)
        let useCase = GuestVideoUseCase(repository: repository)

        await #expect(throws: GuestApplicationError.invalidResponse) {
            try await useCase.prepareVideo(bvid: "BV1FixtureA1")
        }
        #expect(await repository.playbackCIDs().isEmpty)
    }
}

private actor GuestRepositoryStub: GuestContentRepository {
    private let hasPages: Bool
    private var observedPlaybackCIDs: [Int64] = []

    init(hasPages: Bool = true) {
        self.hasPages = hasPages
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [], pageNumber: page, pageSize: pageSize)
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        SearchPage(
            videos: [],
            pageNumber: page,
            pageSize: 20,
            totalResults: 0,
            totalPages: 0
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        return makeDetail(bvid: bvid)
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        guard hasPages else { return [] }
        return [
            VideoPage(
                cid: 900_002,
                index: 2,
                title: "第二部分",
                durationSeconds: 240
            ),
            VideoPage(
                cid: 900_001,
                index: 1,
                title: "第一部分",
                durationSeconds: 120
            ),
        ]
    }

    func playback(
        for bvid: String,
        cid: Int64,
        quality: Int
    ) async throws -> VideoPlayback {
        observedPlaybackCIDs.append(cid)
        return try makePlayback()
    }

    func playbackCIDs() -> [Int64] {
        observedPlaybackCIDs
    }

    private func makeDetail(bvid: String) -> VideoDetail {
        VideoDetail(
            bvid: bvid,
            title: "合成详情 \(bvid)",
            summary: "测试说明",
            coverURL: URL(string: "https://images.example.invalid/cover.jpg"),
            owner: VideoOwner(id: 10_001, name: "测试作者"),
            statistics: VideoStatistics(
                viewCount: 100,
                danmakuCount: 10,
                likeCount: 20
            ),
            durationSeconds: 360,
            publishedAt: Date(timeIntervalSince1970: 1_720_000_000)
        )
    }

    private func makePlayback() throws -> VideoPlayback {
        let segmentBase = SegmentBase(
            initialization: try MediaByteRange(start: 0, endInclusive: 999),
            index: try MediaByteRange(start: 1_000, endInclusive: 1_999)
        )
        let videoURL = try #require(
            URL(string: "https://media.example.invalid/video.m4s")
        )
        let audioURL = try #require(
            URL(string: "https://media.example.invalid/audio.m4s")
        )
        return VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: [
                    MediaRepresentation(
                        id: 32,
                        kind: .video,
                        codecs: "avc1.64001f",
                        mimeType: "video/mp4",
                        primaryURL: videoURL,
                        segmentBase: segmentBase
                    ),
                ],
                audioRepresentations: [
                    MediaRepresentation(
                        id: 30216,
                        kind: .audio,
                        codecs: "mp4a.40.2",
                        mimeType: "audio/mp4",
                        primaryURL: audioURL,
                        segmentBase: segmentBase
                    ),
                ]
            ),
            mediaHeaders: [:]
        )
    }
}
