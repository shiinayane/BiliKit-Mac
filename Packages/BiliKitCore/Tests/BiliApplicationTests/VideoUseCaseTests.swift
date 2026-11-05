import BiliApplication
import BiliModels
import Foundation
import Testing

/// 打开视频只为选定的一个分 P 请求播放，选择不合法或详情请求被取消时不请求播放。
///
/// 选择依次取显式 cid、链接分 P 序号、服务器的续播记录；续播位置为零、已看完或越界时从头播；
/// 充电提示、可跳转时长与链接起播位置跟随实际下发的媒体。
@Suite(.timeLimit(.minutes(1)))
struct VideoUseCaseTests {
    @Test
    func resolvesDetailPagesAndPlaybackForFirstOrderedPage() async throws {
        let repository = ContentRepositoryStub()
        let useCase = VideoUseCase(repository: repository)

        let context = try await useCase.prepareVideo(bvid: "BV1FixtureA1")

        #expect(context.detail.bvid == "BV1FixtureA1")
        #expect(context.pages.map(\.index) == [1, 2])
        #expect(context.selectedPage.index == 1)
        if case .dash(let manifest) = context.playback.media {
            #expect(manifest.videoRepresentations.first?.id == 32)
        } else {
            Issue.record("应得到 DASH 播放清单")
        }
        #expect(await repository.playbackCIDs() == [900_001])
    }

    @Test
    func collectionEpisodePagesAreOrderedDetailPages() async throws {
        let useCase = VideoUseCase(repository: ContentRepositoryStub())

        let pages = try await useCase.pagesForCollectionEpisode(
            bvid: "BV1FixtureA1"
        )

        #expect(pages.map(\.cid) == [900_001, 900_002])
    }

    @Test
    func collectionEpisodeWithoutDetailPagesIsInvalidResponse() async {
        let useCase = VideoUseCase(repository: ContentRepositoryStub(hasPages: false))

        await #expect(throws: ContentApplicationError.invalidResponse) {
            try await useCase.pagesForCollectionEpisode(bvid: "BV1FixtureA1")
        }
    }

    @Test
    func rejectsVideoWithoutPagesBeforeRequestingPlayback() async {
        let repository = ContentRepositoryStub(hasPages: false)
        let useCase = VideoUseCase(repository: repository)

        await #expect(throws: ContentApplicationError.invalidResponse) {
            try await useCase.prepareVideo(bvid: "BV1FixtureA1")
        }
        #expect(await repository.playbackCIDs().isEmpty)
    }

    @Test
    func replacesOnlyTheSelectedCIDWithinPreparedContext() async throws {
        let repository = ContentRepositoryStub()
        let useCase = VideoUseCase(repository: repository)
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
        let repository = ContentRepositoryStub()
        let useCase = VideoUseCase(repository: repository)
        let initial = try await useCase.prepareVideo(bvid: "BV1FixtureA1")

        await #expect(throws: ContentApplicationError.invalidRequest) {
            try await useCase.preparePage(in: initial, cid: 999_999)
        }
        #expect(await repository.playbackCIDs() == [900_001])
    }

    @Test
    func explicitCIDRequestsOnlyTheValidatedTargetAndOverridesResume() async throws {
        let repository = ContentRepositoryStub(
            resumeMetadata: PlaybackResumeMetadata(
                lastPlayedCID: 900_001,
                positionMilliseconds: 5_000
            )
        )
        let useCase = VideoUseCase(repository: repository)

        let context = try await useCase.prepareVideo(
            bvid: "BV1FixtureA1",
            preferredCID: 900_002
        )

        #expect(context.selectedPage.cid == 900_002)
        #expect(context.resumePositionSeconds == nil)
        #expect(await repository.playbackCIDs() == [900_002])
    }

    /// 链接里的分 P 序号按分 P 的 `index` 选择，不按数组位置，也不被服务器记录的上次分 P 改写。
    @Test
    func linkPageNumberSelectsThatPart() async throws {
        let repository = ContentRepositoryStub(
            resumeMetadata: PlaybackResumeMetadata(
                lastPlayedCID: 900_001,
                positionMilliseconds: 5_000
            )
        )
        let useCase = VideoUseCase(repository: repository)

        let context = try await useCase.prepareVideo(
            bvid: "BV1FixtureA1",
            preferredPageNumber: 2
        )

        #expect(context.selectedPage.cid == 900_002)
        #expect(context.resumePositionSeconds == nil)
        #expect(await repository.playbackCIDs() == [900_002])
    }

    /// 链接给的分 P 正是上次看到的分 P 时照常续播（常见于单 P 视频带 `?p=1` 的链接）。
    @Test
    func linkPageNumberKeepsTheResumePositionOfThatPart() async throws {
        let repository = ContentRepositoryStub(
            resumeMetadata: PlaybackResumeMetadata(
                lastPlayedCID: 900_002,
                positionMilliseconds: 42_500
            )
        )
        let useCase = VideoUseCase(repository: repository)

        let context = try await useCase.prepareVideo(
            bvid: "BV1FixtureA1",
            preferredPageNumber: 2
        )

        #expect(context.selectedPage.cid == 900_002)
        #expect(context.resumePositionSeconds == 42.5)
    }

    /// 链接给出的分 P 序号不可信：超出范围时按默认规则选择，不报错。
    @Test(arguments: [0, 3])
    func outOfRangeLinkPageNumberFallsBackToTheDefaultPart(_ number: Int) async throws {
        let repository = ContentRepositoryStub()
        let useCase = VideoUseCase(repository: repository)

        let context = try await useCase.prepareVideo(
            bvid: "BV1FixtureA1",
            preferredPageNumber: number
        )

        #expect(context.selectedPage.cid == 900_001)
    }

    @Test
    func explicitCIDWinsOverLinkPageNumber() async throws {
        let repository = ContentRepositoryStub()
        let useCase = VideoUseCase(repository: repository)

        let context = try await useCase.prepareVideo(
            bvid: "BV1FixtureA1",
            preferredCID: 900_001,
            preferredPageNumber: 2
        )

        #expect(context.selectedPage.cid == 900_001)
    }

    @Test
    func invalidExplicitCIDNeverRequestsPlayback() async {
        let repository = ContentRepositoryStub()
        let useCase = VideoUseCase(repository: repository)

        await #expect(throws: ContentApplicationError.invalidRequest) {
            try await useCase.prepareVideo(
                bvid: "BV1FixtureA1",
                preferredCID: 999_999
            )
        }

        #expect(await repository.playbackCIDs().isEmpty)
    }

    @Test
    func cancellationDuringDetailRequestPreventsPlayback() async throws {
        let repository = ContentRepositoryStub(blocksDetail: true)
        let useCase = VideoUseCase(repository: repository)
        let task = Task {
            try await useCase.prepareVideo(bvid: "BV1FixtureA1")
        }

        await repository.waitForDetailRequest()
        task.cancel()
        await repository.releaseDetail()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await repository.playbackCIDs().isEmpty)
    }

    @Test(arguments: [0, 115_000, 120_000, 900_000] as [Int64])
    func zeroCompletedAndOutOfRangeResumePositionsStartAtBeginning(
        positionMilliseconds: Int64
    ) async throws {
        let repository = ContentRepositoryStub(
            resumeMetadata: PlaybackResumeMetadata(
                lastPlayedCID: 900_001,
                positionMilliseconds: positionMilliseconds
            )
        )

        let context = try await VideoUseCase(repository: repository)
            .prepareVideo(bvid: "BV1FixtureA1")

        #expect(context.selectedPage.cid == 900_001)
        #expect(context.resumePositionSeconds == nil)
    }

    @Test
    func explicitPartSelectionDoesNotBounceToServerRecordedPart() async throws {
        let repository = ContentRepositoryStub(
            resumeMetadata: PlaybackResumeMetadata(
                lastPlayedCID: 900_002,
                positionMilliseconds: 42_500
            )
        )
        let useCase = VideoUseCase(repository: repository)
        let initial = try await useCase.prepareVideo(bvid: "BV1FixtureA1")
        #expect(initial.selectedPage.cid == 900_002)

        let selected = try await useCase.preparePage(in: initial, cid: 900_002)

        #expect(selected.selectedPage.cid == 900_002)
        #expect(selected.resumePositionSeconds == nil)
    }

    enum AccessCase: CaseIterable, Sendable {
        case ordinaryProgressive
        case shortUPowerProgressive
        case overflowingPageDuration
        case fullDASH
    }

    @Test(arguments: AccessCase.allCases)
    func upowerAccessNoticeFollowsDeliveredMedia(_ accessCase: AccessCase) throws {
        let preview = VideoAccess(
            isUPowerExclusive: true,
            isUPowerPreviewAvailable: true,
            isUPowerPlayable: false
        )
        let (access, playback, pageDuration, expected):
            (
                VideoAccess, VideoPlayback, Int, PlaybackAccessNotice?
            ) =
                switch accessCase {
                case .ordinaryProgressive:
                    (VideoAccess(), try progressivePreview(), 2_255, nil)
                case .shortUPowerProgressive:
                    (
                        preview, try progressivePreview(), 2_255,
                        .upowerPreview(previewDurationSeconds: 884, fullDurationSeconds: 2_255)
                    )
                case .overflowingPageDuration:
                    (preview, try progressivePreview(), .max, .upowerExclusive)
                case .fullDASH:
                    (
                        VideoAccess(
                            isUPowerExclusive: true,
                            isUPowerPreviewAvailable: true,
                            isUPowerPlayable: true
                        ),
                        try makeFixturePlayback(resumeMetadata: nil), 2_255, .upowerExclusive
                    )
                }
        let page = VideoPage(cid: 900_001, index: 1, title: "P1", durationSeconds: pageDuration)
        let context = VideoContext(
            detail: makeAccessDetail(access: access),
            pages: [page],
            selectedPage: page,
            playback: playback
        )

        #expect(context.accessNotice == expected)
    }

    /// 可跳转时长是时间戳与链接起播的唯一规则：充电试看取试看时长；只有 DASH 采用链接起播位置。
    @Test
    func seekableDurationAndLinkStartFollowTheDeliveredMedia() throws {
        let page = VideoPage(cid: 900_001, index: 1, title: "P1", durationSeconds: 2_255)
        let previewContext = VideoContext(
            detail: makeAccessDetail(
                access: VideoAccess(
                    isUPowerExclusive: true,
                    isUPowerPreviewAvailable: true,
                    isUPowerPlayable: false
                )
            ),
            pages: [page],
            selectedPage: page,
            playback: try progressivePreview()
        )
        let dashContext = VideoContext(
            detail: makeAccessDetail(access: VideoAccess()),
            pages: [page],
            selectedPage: page,
            playback: try makeFixturePlayback(resumeMetadata: nil)
        )

        #expect(previewContext.seekableDurationSeconds == 884)
        #expect(previewContext.acceptsSeek(toSeconds: 883))
        #expect(!previewContext.acceptsSeek(toSeconds: 884))
        #expect(previewContext.linkStartPosition(seconds: 60) == nil)
        #expect(dashContext.seekableDurationSeconds == 2_255)
        #expect(dashContext.linkStartPosition(seconds: 60) == 60)
        #expect(dashContext.linkStartPosition(seconds: 2_255) == nil)
        #expect(dashContext.linkStartPosition(seconds: nil) == nil)
        #expect(!VideoContext.accepts(seconds: 0, seekableDurationSeconds: nil))
    }

    @Test(
        arguments: [
            (
                ContentApplicationError.serviceRejected(code: -10403),
                .fullViewingEntitlementRequired
            ),
            (.playbackUnavailable, .playbackUnavailable)
        ] as [(ContentApplicationError, ContentApplicationError)]
    )
    func explicitNoRightsMapsOnlyBusinessRejectionToEntitlementMessage(
        playbackFailure: ContentApplicationError,
        expected: ContentApplicationError
    ) async {
        let repository = ContentRepositoryStub(
            access: VideoAccess(
                isUPowerExclusive: true,
                isUPowerPreviewAvailable: false,
                isUPowerPlayable: false
            ),
            playbackFailure: playbackFailure
        )

        await #expect(throws: expected) {
            try await VideoUseCase(repository: repository).prepareVideo(
                bvid: "BV1FixtureA1"
            )
        }
    }

    private func progressivePreview() throws -> VideoPlayback {
        let source = ProgressivePlaybackSource(
            primaryURL: try #require(
                URL(string: "https://media.example.invalid/preview.mp4")
            ),
            contentLength: 50_000_000,
            durationMilliseconds: 884_983,
            contentType: "video/mp4",
            container: .mp4
        )
        return VideoPlayback(media: .progressive(source), mediaHeaders: [:])
    }

    private func makeAccessDetail(access: VideoAccess) -> VideoDetail {
        VideoDetail(
            bvid: "BV1FixtureA1",
            title: "详情",
            summary: "说明",
            coverURL: nil,
            owner: VideoOwner(id: 1, name: "作者"),
            statistics: VideoStatistics(viewCount: 1, danmakuCount: 1, likeCount: 1),
            durationSeconds: 2_255,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            access: access
        )
    }
}

private actor ContentRepositoryStub: VideoRepository {
    private let hasPages: Bool
    private let resumeMetadata: PlaybackResumeMetadata?
    private let access: VideoAccess
    private let playbackFailure: ContentApplicationError?
    private let blocksDetail: Bool
    private var observedPlaybackCIDs: [Int64] = []
    private var observedDetailRequestCount = 0
    private var detailRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var detailReleases: [CheckedContinuation<Void, Never>] = []

    init(
        hasPages: Bool = true,
        resumeMetadata: PlaybackResumeMetadata? = nil,
        access: VideoAccess = VideoAccess(),
        playbackFailure: ContentApplicationError? = nil,
        blocksDetail: Bool = false
    ) {
        self.hasPages = hasPages
        self.resumeMetadata = resumeMetadata
        self.access = access
        self.playbackFailure = playbackFailure
        self.blocksDetail = blocksDetail
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        observedDetailRequestCount += 1
        detailRequestWaiters.resumeAll()
        if blocksDetail {
            await withCheckedContinuation { detailReleases.append($0) }
        }
        return makeDetail(bvid: bvid)
    }

    func waitForDetailRequest() async {
        guard observedDetailRequestCount == 0 else { return }
        await withCheckedContinuation { detailRequestWaiters.append($0) }
    }

    func releaseDetail() {
        detailReleases.resumeAll()
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
            )
        ]
    }

    func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        observedPlaybackCIDs.append(cid)
        if let playbackFailure { throw playbackFailure }
        return try makeFixturePlayback(resumeMetadata: resumeMetadata)
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
            pages: hasPages ? fixturePages : [],
            access: access
        )
    }
}

private func makeFixturePlayback(
    resumeMetadata: PlaybackResumeMetadata?
) throws -> VideoPlayback {
    let segmentBase = SegmentBase(
        initialization: try MediaByteRange(start: 0, endInclusive: 999),
        index: try MediaByteRange(start: 1_000, endInclusive: 1_999)
    )
    let videoURL = try #require(URL(string: "https://media.example.invalid/video.m4s"))
    let audioURL = try #require(URL(string: "https://media.example.invalid/audio.m4s"))
    return VideoPlayback(
        media: .dash(
            PlaybackManifest(
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
                audioTracks: [
                    .original(
                        representations: [
                            MediaRepresentation(
                                id: 30216,
                                kind: .audio,
                                codecs: "mp4a.40.2",
                                mimeType: "audio/mp4",
                                primaryURL: audioURL,
                                segmentBase: segmentBase
                            )
                        ]
                    )
                ]
            )
        ),
        mediaHeaders: [:],
        resumeMetadata: resumeMetadata
    )
}
