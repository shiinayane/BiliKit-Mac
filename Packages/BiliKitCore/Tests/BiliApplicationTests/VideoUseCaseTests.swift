import BiliApplication
import BiliModels
import Foundation
import Testing

/// 打开视频只为选定的一个分 P 请求播放，选择不合法或详情请求被取消时不请求播放。
///
/// 分 P 已定（显式 cid、命中的链接序号或只有一个分 P）时，详情这一步就给出选定的分 P，播放页不等 playurl 就能呈现；
/// 多 P 且没有指定时由续播记录决定。
///
/// 来源列表给的 CID 可以在详情之前预取播放清单（会先发出一次请求），但只在与要请求的分 P 一致时采用，失败也在那时
/// 才按详情权益解释；不一致时丢弃、照常请求。
/// 选择依次取显式 cid、链接分 P 序号、服务器的续播记录；续播位置为零、已看完或越界时从头播；
/// 充电提示、可跳转时长与链接起播位置跟随实际下发的媒体。
@Suite(.timeLimit(.minutes(1)))
struct VideoUseCaseTests {
    @Test
    func resolvesDetailPagesAndPlaybackForFirstOrderedPage() async throws {
        let repository = ContentRepositoryStub()
        let useCase = VideoUseCase(repository: repository)

        let video = try await prepare(useCase, bvid: "BV1FixtureA1")

        #expect(video.context.detail.bvid == "BV1FixtureA1")
        #expect(video.context.pages.map(\.index) == [1, 2])
        #expect(video.context.selectedPage.index == 1)
        if case .dash(let manifest) = video.playback.media {
            #expect(manifest.videoRepresentations.first?.id == 32)
        } else {
            Issue.record("应得到 DASH 播放清单")
        }
        #expect(await repository.playbackCIDs() == [900_001])
    }

    @Test
    func detailStepSelectsThePartOnlyWhenItIsAlreadyDecided() async throws {
        let repository = ContentRepositoryStub()
        let useCase = VideoUseCase(repository: repository)

        let bvid = "BV1FixtureA1"
        let undecided = try await useCase.prepareDetail(bvid: bvid)
        let explicit = try await useCase.prepareDetail(bvid: bvid, preferredCID: 900_002)
        let linked = try await useCase.prepareDetail(bvid: bvid, preferredPageNumber: 2)
        let outOfRange = try await useCase.prepareDetail(bvid: bvid, preferredPageNumber: 3)

        #expect(undecided.context == nil)
        #expect(explicit.context?.selectedPage.cid == 900_002)
        #expect(linked.context?.selectedPage.cid == 900_002)
        #expect(outOfRange.context == nil)
        #expect(await repository.playbackCIDs().isEmpty)

        let singlePart = ContentRepositoryStub(
            singlePage: true,
            resumeMetadata: PlaybackResumeMetadata(
                lastPlayedCID: 900_001,
                positionMilliseconds: 42_500
            )
        )
        let singlePartUseCase = VideoUseCase(repository: singlePart)
        let preparation = try await singlePartUseCase.prepareDetail(bvid: "BV1FixtureA1")
        #expect(preparation.context?.selectedPage.cid == 900_001)
        #expect(await singlePart.playbackCIDs().isEmpty)

        // 提前选定不改变续播：只有一个分 P 时照样从服务器记录的位置继续。
        let video = try await singlePartUseCase.preparePlayback(for: preparation)
        #expect(video.resumePositionSeconds == 42.5)
        #expect(await singlePart.playbackCIDs() == [900_001])
    }

    @Test
    func prefetchIsUsedOnlyWhenItMatchesTheFirstRequestedPart() async throws {
        let matching = ContentRepositoryStub()
        let matchingUseCase = VideoUseCase(repository: matching)
        let prefetched = await matchingUseCase.prefetchPlayback(bvid: "BV1FixtureA1", cid: 900_001)
        let preparation = try await matchingUseCase.prepareDetail(bvid: "BV1FixtureA1")
        let video = try await matchingUseCase.preparePlayback(
            for: preparation,
            prefetched: prefetched
        )
        #expect(video.context.selectedPage.cid == 900_001)
        #expect(await matching.playbackCIDs() == [900_001])

        let mismatched = ContentRepositoryStub()
        let mismatchedUseCase = VideoUseCase(repository: mismatched)
        let stale = await mismatchedUseCase.prefetchPlayback(bvid: "BV1FixtureA1", cid: 900_002)
        let undecided = try await mismatchedUseCase.prepareDetail(bvid: "BV1FixtureA1")
        _ = try await mismatchedUseCase.preparePlayback(for: undecided, prefetched: stale)
        #expect(await mismatched.playbackCIDs() == [900_002, 900_001])
    }

    @Test
    func validatedPrefetchFailureIsInterpretedByTheDetailAndNotRetried() async throws {
        let repository = ContentRepositoryStub(
            access: VideoAccess(
                isUPowerExclusive: true,
                isUPowerPreviewAvailable: false,
                isUPowerPlayable: false
            ),
            playbackFailure: .serviceRejected(code: -10403)
        )
        let useCase = VideoUseCase(repository: repository)
        let prefetched = await useCase.prefetchPlayback(bvid: "BV1FixtureA1", cid: 900_001)
        let preparation = try await useCase.prepareDetail(bvid: "BV1FixtureA1")

        await #expect(throws: ContentApplicationError.fullViewingEntitlementRequired) {
            try await useCase.preparePlayback(for: preparation, prefetched: prefetched)
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
            try await prepare(useCase, bvid: "BV1FixtureA1")
        }
        #expect(await repository.playbackCIDs().isEmpty)
    }

    @Test
    func replacesOnlyTheSelectedCIDWithinPreparedContext() async throws {
        let repository = ContentRepositoryStub()
        let useCase = VideoUseCase(repository: repository)
        let initial = try await prepare(useCase, bvid: "BV1FixtureA1")

        let replacement = try await useCase.preparePage(
            in: initial.context,
            cid: 900_002
        )

        #expect(replacement.context.detail == initial.context.detail)
        #expect(replacement.context.pages == initial.context.pages)
        #expect(replacement.context.selectedPage.cid == 900_002)
        #expect(await repository.playbackCIDs() == [900_001, 900_002])
    }

    @Test
    func rejectsCIDOutsidePreparedPagesWithoutPlaybackRequest() async throws {
        let repository = ContentRepositoryStub()
        let useCase = VideoUseCase(repository: repository)
        let initial = try await prepare(useCase, bvid: "BV1FixtureA1")

        await #expect(throws: ContentApplicationError.invalidRequest) {
            try await useCase.preparePage(in: initial.context, cid: 999_999)
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

        let video = try await prepare(
            useCase,
            bvid: "BV1FixtureA1",
            preferredCID: 900_002
        )

        #expect(video.context.selectedPage.cid == 900_002)
        #expect(video.resumePositionSeconds == nil)
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

        let video = try await prepare(
            useCase,
            bvid: "BV1FixtureA1",
            preferredPageNumber: 2
        )

        #expect(video.context.selectedPage.cid == 900_002)
        #expect(video.resumePositionSeconds == nil)
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

        let video = try await prepare(
            useCase,
            bvid: "BV1FixtureA1",
            preferredPageNumber: 2
        )

        #expect(video.context.selectedPage.cid == 900_002)
        #expect(video.resumePositionSeconds == 42.5)
    }

    /// 链接给出的分 P 序号不可信：超出范围时按默认规则选择，不报错。
    @Test(arguments: [0, 3])
    func outOfRangeLinkPageNumberFallsBackToTheDefaultPart(_ number: Int) async throws {
        let repository = ContentRepositoryStub()
        let useCase = VideoUseCase(repository: repository)

        let video = try await prepare(
            useCase,
            bvid: "BV1FixtureA1",
            preferredPageNumber: number
        )

        #expect(video.context.selectedPage.cid == 900_001)
    }

    @Test
    func explicitCIDWinsOverLinkPageNumber() async throws {
        let repository = ContentRepositoryStub()
        let useCase = VideoUseCase(repository: repository)

        let video = try await prepare(
            useCase,
            bvid: "BV1FixtureA1",
            preferredCID: 900_001,
            preferredPageNumber: 2
        )

        #expect(video.context.selectedPage.cid == 900_001)
    }

    @Test
    func invalidExplicitCIDNeverRequestsPlayback() async {
        let repository = ContentRepositoryStub()
        let useCase = VideoUseCase(repository: repository)

        await #expect(throws: ContentApplicationError.invalidRequest) {
            try await prepare(
                useCase,
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
            try await prepare(useCase, bvid: "BV1FixtureA1")
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

        let video = try await prepare(VideoUseCase(repository: repository), bvid: "BV1FixtureA1")

        #expect(video.context.selectedPage.cid == 900_001)
        #expect(video.resumePositionSeconds == nil)
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
        let initial = try await prepare(useCase, bvid: "BV1FixtureA1")
        #expect(initial.context.selectedPage.cid == 900_002)

        let selected = try await useCase.preparePage(in: initial.context, cid: 900_002)

        #expect(selected.context.selectedPage.cid == 900_002)
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
        let video = PlayableVideo(
            context: VideoContext(
                detail: makeAccessDetail(access: access),
                pages: [page],
                selectedPage: page
            ),
            playback: playback
        )

        #expect(video.accessNotice == expected)
    }

    /// 可跳转时长是时间戳与链接起播的唯一规则：充电试看取试看时长；只有 DASH 采用链接起播位置。
    ///
    /// 带分 P 前缀的时间戳指向其他分 P 时按那个分 P 的全长判断，分 P 不存在或时长未知时不能跳。
    @Test
    func seekableDurationAndLinkStartFollowTheDeliveredMedia() throws {
        let page = VideoPage(cid: 900_001, index: 1, title: "P1", durationSeconds: 2_255)
        let otherPages = [
            VideoPage(cid: 900_002, index: 2, title: "P2", durationSeconds: 600),
            VideoPage(cid: 900_003, index: 3, title: "P3", durationSeconds: 0)
        ]
        let previewContext = PlayableVideo(
            context: VideoContext(
                detail: makeAccessDetail(
                    access: VideoAccess(
                        isUPowerExclusive: true,
                        isUPowerPreviewAvailable: true,
                        isUPowerPlayable: false
                    )
                ),
                pages: [page] + otherPages,
                selectedPage: page
            ),
            playback: try progressivePreview()
        )
        let dashContext = PlayableVideo(
            context: VideoContext(
                detail: makeAccessDetail(access: VideoAccess()),
                pages: [page],
                selectedPage: page
            ),
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
        #expect(!PlayableVideo.accepts(seconds: 0, seekableDurationSeconds: nil))
        let limits = previewContext.timestampSeekLimits
        #expect(limits.accepts(seconds: 883, page: nil))
        #expect(!limits.accepts(seconds: 884, page: 1))
        #expect(limits.accepts(seconds: 599, page: 2))
        #expect(!limits.accepts(seconds: 600, page: 2))
        #expect(!limits.accepts(seconds: 0, page: 3))
        #expect(!limits.accepts(seconds: 0, page: 4))
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
            try await prepare(VideoUseCase(repository: repository), bvid: "BV1FixtureA1")
        }
    }

    /// 按播放页的顺序走完两步：先取详情，再取播放清单。
    private func prepare(
        _ useCase: VideoUseCase,
        bvid: String,
        preferredCID: Int64? = nil,
        preferredPageNumber: Int? = nil
    ) async throws -> PlayableVideo {
        let preparation = try await useCase.prepareDetail(
            bvid: bvid,
            preferredCID: preferredCID,
            preferredPageNumber: preferredPageNumber
        )
        return try await useCase.preparePlayback(for: preparation)
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
    private let singlePage: Bool
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
        singlePage: Bool = false,
        resumeMetadata: PlaybackResumeMetadata? = nil,
        access: VideoAccess = VideoAccess(),
        playbackFailure: ContentApplicationError? = nil,
        blocksDetail: Bool = false
    ) {
        self.hasPages = hasPages
        self.singlePage = singlePage
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

    private var pages: [VideoPage] {
        singlePage ? fixturePages.filter { $0.index == 1 } : fixturePages
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
            pages: hasPages ? pages : [],
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
