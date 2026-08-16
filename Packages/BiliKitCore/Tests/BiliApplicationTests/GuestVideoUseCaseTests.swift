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
    func usesPagesEmbeddedInDetailWithoutPagelistRequest() async throws {
        let repository = GuestRepositoryStub(detailHasPages: true)
        let useCase = GuestVideoUseCase(repository: repository)

        let context = try await useCase.prepareVideo(bvid: "BV1FixtureA1")

        #expect(context.pages.map(\.cid) == [900_001, 900_002])
        #expect(await repository.pageRequestCount() == 0)
    }

    @Test
    func collectionEpisodePagesUseDetailBeforePagelistFallback() async throws {
        let repository = GuestRepositoryStub(detailHasPages: true)
        let useCase = GuestVideoUseCase(repository: repository)

        let pages = try await useCase.pagesForCollectionEpisode(
            bvid: "BV1FixtureA1"
        )

        #expect(pages.map(\.cid) == [900_001, 900_002])
        #expect(await repository.pageRequestCount() == 0)
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

    @Test
    func replacesOnlyTheSelectedCIDWithinPreparedContext() async throws {
        let repository = GuestRepositoryStub()
        let useCase = GuestVideoUseCase(repository: repository)
        let initial = try await useCase.prepareVideo(bvid: "BV1FixtureA1")

        let replacement = try await useCase.preparePage(
            in: initial,
            cid: 900_002
        )

        #expect(replacement.detail == initial.detail)
        #expect(replacement.pages == initial.pages)
        #expect(replacement.selectedPage.cid == 900_002)
        #expect(await repository.playbackCIDs() == [900_001, 900_002])
    }

    @Test
    func rejectsCIDOutsidePreparedPagesWithoutPlaybackRequest() async throws {
        let repository = GuestRepositoryStub()
        let useCase = GuestVideoUseCase(repository: repository)
        let initial = try await useCase.prepareVideo(bvid: "BV1FixtureA1")

        await #expect(throws: GuestApplicationError.invalidRequest) {
            try await useCase.preparePage(in: initial, cid: 999_999)
        }
        #expect(await repository.playbackCIDs() == [900_001])
    }

    @Test
    func explicitCIDRequestsOnlyTheValidatedTargetAndOverridesResume() async throws {
        let repository = GuestRepositoryStub(
            resumeMetadata: PlaybackResumeMetadata(
                lastPlayedCID: 900_001,
                positionMilliseconds: 5_000
            )
        )
        let useCase = GuestVideoUseCase(repository: repository)

        let context = try await useCase.prepareVideo(
            bvid: "BV1FixtureA1",
            preferredCID: 900_002
        )

        #expect(context.selectedPage.cid == 900_002)
        #expect(context.resumePositionSeconds == nil)
        #expect(await repository.playbackCIDs() == [900_002])
    }

    @Test
    func invalidExplicitCIDNeverRequestsPlayback() async {
        let repository = GuestRepositoryStub()
        let useCase = GuestVideoUseCase(repository: repository)

        await #expect(throws: GuestApplicationError.invalidRequest) {
            try await useCase.prepareVideo(
                bvid: "BV1FixtureA1",
                preferredCID: 999_999
            )
        }

        #expect(await repository.playbackCIDs().isEmpty)
    }

    @Test
    func cancellationDuringPagelistFallbackPreventsPlayback() async throws {
        let repository = FallbackCancellationRepository()
        let useCase = GuestVideoUseCase(repository: repository)
        let task = Task {
            try await useCase.prepareVideo(bvid: "BV1FixtureA1")
        }

        await repository.waitForPagesRequest()
        task.cancel()
        await repository.releasePages()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await repository.playbackRequestCount() == 0)
    }
}

private actor FallbackCancellationRepository: GuestContentRepository {
    private var pagesStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var playbackRequests = 0

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
        VideoDetail(
            bvid: bvid,
            title: "详情",
            summary: "说明",
            coverURL: nil,
            owner: VideoOwner(id: 1, name: "作者"),
            statistics: VideoStatistics(viewCount: 1, danmakuCount: 1, likeCount: 1),
            durationSeconds: 10,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        pagesStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return [VideoPage(cid: 900_001, index: 1, title: "P1", durationSeconds: 10)]
    }

    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        playbackRequests += 1
        return VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: [],
                originalAudioRepresentations: []
            ),
            mediaHeaders: [:]
        )
    }

    func waitForPagesRequest() async {
        guard !pagesStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releasePages() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func playbackRequestCount() -> Int {
        playbackRequests
    }
}

private actor GuestRepositoryStub: GuestContentRepository {
    private let hasPages: Bool
    private let detailHasPages: Bool
    private let resumeMetadata: PlaybackResumeMetadata?
    private var observedPlaybackCIDs: [Int64] = []
    private var observedPageRequestCount = 0

    init(
        hasPages: Bool = true,
        detailHasPages: Bool = false,
        resumeMetadata: PlaybackResumeMetadata? = nil
    ) {
        self.hasPages = hasPages
        self.detailHasPages = detailHasPages
        self.resumeMetadata = resumeMetadata
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
        makeDetail(bvid: bvid)
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        observedPageRequestCount += 1
        guard hasPages else { return [] }
        return fixturePages
    }

    func pageRequestCount() -> Int {
        observedPageRequestCount
    }

    private var fixturePages: [VideoPage] {
        [
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
        cid: Int64
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
            publishedAt: Date(timeIntervalSince1970: 1_720_000_000),
            pages: detailHasPages ? fixturePages : []
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
                    )
                ],
                originalAudioRepresentations: [
                    MediaRepresentation(
                        id: 30216,
                        kind: .audio,
                        codecs: "mp4a.40.2",
                        mimeType: "audio/mp4",
                        primaryURL: audioURL,
                        segmentBase: segmentBase
                    )
                ]
            ),
            mediaHeaders: [:],
            resumeMetadata: resumeMetadata
        )
    }
}
