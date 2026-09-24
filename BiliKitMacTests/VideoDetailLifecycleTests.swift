import AppKit
import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliDanmaku
import BiliLibraryFeature
import BiliModels
import CoreGraphics
import Observation
import SwiftUI
import Testing

@testable import BiliKit

@Suite(.serialized, .timeLimit(.minutes(1)))
struct VideoDetailLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func playbackFailureStopsPresentationAndRetryStartsItAgain() async {
        let fixture = VideoDetailLifecycleFixture()
        let player = LifecyclePlayback(holdsLoads: true)
        let videoModel = VideoViewModel(
            useCase: VideoUseCase(
                repository: LifecycleVideoRepository(fixtures: [fixture])
            ),
            playback: player
        )
        let presentation = RecordingPresentation()
        let danmakuModel = DanmakuControlsViewModel(
            presentation: presentation
        )
        let hostingView = NSHostingView(
            rootView: AnyView(
                VideoPlaybackView(
                    model: videoModel,
                    danmakuModel: danmakuModel,
                    onRetry: {},
                    makeRelatedContent: { _, _, _ in EmptyView() }
                ) {
                    EmptyView()
                }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        await presentation.waitForStopCount(1)
        let baselineStopCount = presentation.stopCount

        videoModel.loadVideo(fixture.bvid)
        await player.waitForLoadCallCount(1)
        await presentation.waitForStartedCount(1)
        #expect(player.loadedIdentities.count == 1)
        #expect(presentation.startedIdentities.count == 1)
        #expect(videoModel.presentedContext?.detail.bvid == fixture.bvid)

        player.failPendingLoad()
        await videoModel.waitForCurrentTask()
        await presentation.waitForStopCount(baselineStopCount + 1)
        #expect(presentation.stopCount == baselineStopCount + 1)
        guard case .failed = videoModel.state else {
            Issue.record("播放加载失败后应进入失败状态")
            return
        }
        #expect(videoModel.presentedContext?.detail.bvid == fixture.bvid)

        videoModel.loadVideo(fixture.bvid)
        await player.waitForLoadCallCount(2)
        await presentation.waitForStartedCount(2)
        #expect(player.loadedIdentities.count == 2)
        #expect(presentation.startedIdentities.count == 2)

        player.failPendingLoad()
        await videoModel.waitForCurrentTask()
        await presentation.waitForStopCount(baselineStopCount + 2)
        #expect(presentation.stopCount == baselineStopCount + 2)

        window.contentView = NSView()
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func backCancelsPendingUploaderSignatureRequest()
        async throws
    {
        let fixture = VideoDetailLifecycleFixture()
        let signatureRepository = PendingLifecycleUploaderSignatureRepository()
        let videoModel = VideoViewModel(
            useCase: VideoUseCase(
                repository: LifecycleVideoRepository(fixtures: [fixture])
            ),
            playback: LifecyclePlayback(),
            uploaderSignatureUseCase: UploaderSignatureUseCase(
                repository: signatureRepository
            )
        )
        let coordinator = AppNavigationCoordinator(
            startPlayback: { intent in
                videoModel.loadVideo(
                    intent.bvid,
                    preferredCID: intent.preferredCID
                )
            },
            stopPlayback: {
                videoModel.reset()
            }
        )

        coordinator.openPlayback(fixture.bvid)
        await videoModel.waitForCurrentTask()
        try await signatureRepository.waitForRequest()
        #expect(videoModel.uploaderSignatureState == .loading)

        coordinator.playbackPath = []
        await signatureRepository.releaseLateResult()
        try await signatureRepository.waitForCompletion()

        #expect(videoModel.state == .idle)
        #expect(videoModel.presentedContext == nil)
        #expect(videoModel.uploaderSignatureState == .loaded(nil))
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func onlyResolvedAuthenticationBoundaryClosesPlayback() async throws {
        let fixture = VideoDetailLifecycleFixture()
        let watchProgressProbe = WatchProgressConnectionProbe()
        let repository = LifecycleVideoRepository(fixtures: [fixture])
        let playback = LifecyclePlayback()
        let browseModel = BrowseViewModel(
            useCase: FeedUseCase(repository: EmptyLifecycleFeedRepository())
        )
        let videoModel = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: playback
        )
        let danmakuModel = DanmakuControlsViewModel(
            presentation: RecordingPresentation()
        )
        let authenticationService = LifecycleAuthenticationService(
            restoreState: .signedIn(nil),
            blocksFirstRestore: true
        )
        let authenticationModel = AuthenticationViewModel(
            service: authenticationService,
            qrCodeProvider: LifecycleQRCodeProvider()
        )
        let historyModel = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(
                repository: EmptyLifecycleHistoryRepository()
            )
        )
        let coordinator = AppNavigationCoordinator(
            startPlayback: { intent in
                videoModel.loadVideo(
                    intent.bvid,
                    preferredCID: intent.preferredCID
                )
            },
            stopPlayback: {
                videoModel.reset()
                danmakuModel.reset()
            }
        )
        let hostingView = NSHostingView(
            rootView: AppRootView(
                navigationCoordinator: coordinator,
                browseModel: browseModel,
                videoModel: videoModel,
                danmakuModel: danmakuModel,
                authenticationModel: authenticationModel,
                historyModel: historyModel,
                playerContent: AnyView(EmptyView()),
                watchProgressConnection: watchProgressProbe.connection
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        try await authenticationService.waitForFirstRestoreStart()
        #expect(authenticationModel.sessionState == .unresolved)
        #expect(watchProgressProbe.startCount == 1)
        #expect(watchProgressProbe.accessValues == [false])

        coordinator.openPlayback(fixture.bvid)
        await videoModel.waitForCurrentTask()
        #expect(playback.loadedIdentities == [fixture.identity])
        #expect(videoModel.presentedContext?.detail.bvid == fixture.bvid)

        let loadCountBeforeRestore = playback.loadedIdentities.count
        let stopCountBeforeRestore = playback.stopCallCount
        await authenticationService.releaseFirstRestore()
        await authenticationModel.waitForCurrentTask()
        #expect(authenticationModel.sessionState == .signedIn(nil))
        #expect(coordinator.currentPlaybackBVID == fixture.bvid)
        #expect(playback.loadedIdentities.count == loadCountBeforeRestore)
        #expect(playback.stopCallCount == stopCountBeforeRestore)
        #expect(watchProgressProbe.accessValues.last == true)

        let identity = AccountIdentity(
            id: 42,
            displayName: "测试账号",
            avatarURL: nil
        )
        await authenticationService.setRestoreState(.signedIn(identity))
        let stopCountBeforeIdentity = playback.stopCallCount
        authenticationModel.revalidate()
        await authenticationModel.waitForCurrentTask()
        await playback.waitForStopCallCount(stopCountBeforeIdentity + 1)
        #expect(authenticationModel.sessionState == .signedIn(identity))
        #expect(videoModel.state == .idle)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(playback.stopCallCount == stopCountBeforeIdentity + 1)

        coordinator.openPlayback(fixture.bvid)
        await videoModel.waitForCurrentTask()
        #expect(coordinator.currentPlaybackBVID == fixture.bvid)

        let stopCountBeforeLogout = playback.stopCallCount
        authenticationModel.logout()
        await authenticationModel.waitForCurrentTask()
        await playback.waitForStopCallCount(stopCountBeforeLogout + 1)
        #expect(authenticationModel.sessionState == .signedOut)
        #expect(videoModel.state == .idle)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(playback.stopCallCount == stopCountBeforeLogout + 1)
        #expect(watchProgressProbe.accessValues.last == false)

        coordinator.openPlayback(fixture.bvid)
        await videoModel.waitForCurrentTask()
        #expect(
            playback.loadedIdentities == [
                fixture.identity,
                fixture.identity,
                fixture.identity
            ]
        )
        #expect(coordinator.currentPlaybackBVID == fixture.bvid)
        let loadCountBeforeSignIn = playback.loadedIdentities.count
        let stopCountBeforeSignIn = playback.stopCallCount

        await authenticationService.setRestoreState(.signedIn(identity))
        authenticationModel.revalidate()
        await authenticationModel.waitForCurrentTask()
        await playback.waitForStopCallCount(stopCountBeforeSignIn + 1)
        #expect(authenticationModel.sessionState == .signedIn(identity))
        #expect(videoModel.state == .idle)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(playback.loadedIdentities.count == loadCountBeforeSignIn)
        #expect(playback.stopCallCount == stopCountBeforeSignIn + 1)
        #expect(watchProgressProbe.accessValues.last == true)

        window.contentView = NSView()
        #expect(watchProgressProbe.stopCount == 1)
    }

    @Test(arguments: VideoDetailCredentialFailureSource.allCases)
    @MainActor
    func invalidCredentialRevalidatesAndClosesPlayback(
        _ source: VideoDetailCredentialFailureSource
    ) async {
        let fixture = VideoDetailLifecycleFixture()
        let repository = LifecycleVideoRepository(
            fixtures: [fixture],
            playbackError: source == .playback ? .authenticationInvalid : nil
        )
        let playback = LifecyclePlayback()
        let videoModel = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: playback
        )
        let commentsModel = PlaybackCommentsViewModel(
            useCase: CommentUseCase(
                repository: LifecycleCommentRepository(
                    rootError: source == .comments ? .authenticationInvalid : nil
                )
            )
        )
        let danmakuModel = DanmakuControlsViewModel(
            presentation: RecordingPresentation()
        )
        let authenticationService = LifecycleAuthenticationService(
            restoreState: .signedIn(nil)
        )
        let authenticationModel = AuthenticationViewModel(
            service: authenticationService,
            qrCodeProvider: LifecycleQRCodeProvider()
        )
        let coordinator = AppNavigationCoordinator(
            startPlayback: {
                videoModel.loadVideo($0.bvid, preferredCID: $0.preferredCID)
            },
            stopPlayback: {
                videoModel.reset()
                danmakuModel.reset()
            }
        )
        let hostingView = NSHostingView(
            rootView: AppRootView(
                navigationCoordinator: coordinator,
                browseModel: BrowseViewModel(
                    useCase: FeedUseCase(repository: EmptyLifecycleFeedRepository())
                ),
                videoModel: videoModel,
                commentsModel: commentsModel,
                danmakuModel: danmakuModel,
                authenticationModel: authenticationModel,
                historyModel: WatchHistoryViewModel(
                    useCase: WatchHistoryUseCase(
                        repository: EmptyLifecycleHistoryRepository()
                    )
                ),
                playerContent: AnyView(EmptyView())
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        await authenticationService.waitForRestoreCallCount(1)
        await authenticationModel.waitForCurrentTask()
        #expect(authenticationModel.sessionState == .signedIn(nil))

        await authenticationService.setRestoreState(.signedOut)
        coordinator.openPlayback(fixture.bvid)
        await videoModel.waitForCurrentTask()
        await authenticationService.waitForRestoreCallCount(2)
        await authenticationModel.waitForCurrentTask()
        await playback.waitForStopCallCount(1)

        #expect(authenticationModel.sessionState == .signedOut)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(videoModel.state == .idle)
        #expect(playback.stopCallCount == 1)
        switch source {
        case .playback:
            #expect(playback.loadedIdentities.isEmpty)
        case .comments:
            #expect(commentsModel.authenticationRevalidationGeneration == 1)
        }
        window.contentView = NSView()
    }

    @Test
    @MainActor
    func failedPageSelectionRoutesANewCIDInsteadOfRetryingTheOldTarget() async {
        let fixture = PageSelectionRoutingFixture()
        let repository = LifecycleVideoRepository(
            detail: { _ in fixture.detail },
            playback: { _, cid in
                if cid == fixture.failingPage.cid {
                    throw ContentApplicationError.transportFailure
                }
                return fixture.playback
            }
        )
        let videoModel = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: LifecyclePlayback()
        )

        videoModel.loadVideo(
            fixture.bvid,
            preferredCID: fixture.initialPage.cid
        )
        await videoModel.waitForCurrentTask()
        videoModel.selectPage(cid: fixture.failingPage.cid)
        await videoModel.waitForCurrentTask()
        guard case .failedPage(_, let failedPage, _) = videoModel.state else {
            Issue.record("切换失败后应保留失败的分 P 目标")
            return
        }
        #expect(failedPage.cid == fixture.failingPage.cid)

        AppWindowOwner.handlePlaybackSelection(
            PlaybackSelectionIntent(
                bvid: fixture.bvid,
                preferredCID: fixture.replacementPage.cid
            ),
            with: videoModel
        )
        await videoModel.waitForCurrentTask()

        #expect(videoModel.requestedPreferredCID == fixture.replacementPage.cid)
        #expect(videoModel.presentedPlaybackIdentity?.cid == fixture.replacementPage.cid)
        #expect(
            await repository.playbackCIDs == [
                fixture.initialPage.cid,
                fixture.failingPage.cid,
                fixture.replacementPage.cid
            ]
        )
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func appRootActivatesCommentsByAIDAndClearsThemOnBack() async {
        let first = VideoDetailLifecycleFixture(
            aid: 700_001,
            bvid: "BV1CommentLifecycleA",
            cid: 900_001,
            title: "评论生命周期 A"
        )
        let replacement = VideoDetailLifecycleFixture(
            aid: 700_002,
            bvid: "BV1CommentLifecycleB",
            cid: 900_002,
            title: "评论生命周期 B"
        )
        let repository = LifecycleVideoRepository(
            fixtures: [first, replacement]
        )
        let commentsRepository = LifecycleCommentRepository()
        let videoModel = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: LifecyclePlayback()
        )
        let commentsModel = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: commentsRepository)
        )
        let danmakuModel = DanmakuControlsViewModel(
            presentation: RecordingPresentation()
        )
        let coordinator = AppNavigationCoordinator(
            startPlayback: { intent in
                videoModel.loadVideo(
                    intent.bvid,
                    preferredCID: intent.preferredCID
                )
            },
            stopPlayback: {
                videoModel.reset()
                danmakuModel.reset()
            }
        )
        let hostingView = NSHostingView(
            rootView: AppRootView(
                navigationCoordinator: coordinator,
                browseModel: BrowseViewModel(
                    useCase: FeedUseCase(repository: EmptyLifecycleFeedRepository())
                ),
                videoModel: videoModel,
                commentsModel: commentsModel,
                danmakuModel: danmakuModel,
                authenticationModel: AuthenticationViewModel(
                    service: LifecycleAuthenticationService(restoreState: .signedOut),
                    qrCodeProvider: LifecycleQRCodeProvider()
                ),
                historyModel: WatchHistoryViewModel(
                    useCase: WatchHistoryUseCase(
                        repository: EmptyLifecycleHistoryRepository()
                    )
                ),
                playerContent: AnyView(EmptyView())
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()

        coordinator.openPlayback(first.bvid)
        await videoModel.waitForCurrentTask()
        await commentsRepository.waitForRequestCount(1)
        await commentsModel.waitForCurrentRootTask()
        #expect(commentsModel.subject == .video(aid: first.aid))
        #expect(commentsModel.rootState == .empty)

        coordinator.openPlayback(replacement.bvid)
        await videoModel.waitForCurrentTask()
        await commentsRepository.waitForRequestCount(2)
        await commentsModel.waitForCurrentRootTask()
        #expect(commentsModel.subject == .video(aid: replacement.aid))
        #expect(commentsModel.rootState == .empty)
        #expect(
            await commentsRepository.requestedSubjects()
                == [.video(aid: first.aid), .video(aid: replacement.aid)]
        )

        coordinator.playbackPath = []
        await waitForObservedState {
            commentsModel.subject == nil
                && commentsModel.rootState == .idle
                && videoModel.state == .idle
        }
        #expect(commentsModel.subject == nil)
        #expect(commentsModel.rootState == .idle)
        #expect(videoModel.state == .idle)
        window.contentView = NSView()
    }

    @MainActor
    private func waitForObservedState(
        _ condition: @MainActor @escaping () -> Bool
    ) async {
        while !condition() {
            await withCheckedContinuation { continuation in
                let gate = ObservationContinuationGate(continuation)
                let isAlreadySatisfied = withObservationTracking {
                    condition()
                } onChange: {
                    gate.resume()
                }
                if isAlreadySatisfied { gate.resume() }
            }
        }
    }
}

enum VideoDetailCredentialFailureSource: CaseIterable, Sendable {
    case playback
    case comments
}

private final class ObservationContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private struct VideoDetailLifecycleFixture: Sendable {
    let aid: Int64
    let bvid: String
    let page: VideoPage
    let title: String

    init(
        aid: Int64 = 700_000,
        bvid: String = "BV1LifecycleFixture",
        cid: Int64 = 900_001,
        title: String = "生命周期测试视频"
    ) {
        self.aid = aid
        self.bvid = bvid
        page = VideoPage(
            cid: cid,
            index: 1,
            title: "P1",
            durationSeconds: 120
        )
        self.title = title
    }

    var identity: PlaybackItemIdentity {
        PlaybackItemIdentity(bvid: bvid, cid: page.cid)
    }

    var detail: VideoDetail {
        VideoDetail(
            bvid: bvid,
            title: title,
            summary: "手写测试数据",
            coverURL: nil,
            owner: VideoOwner(id: 10_001, name: "测试 UP 主"),
            statistics: VideoStatistics(
                viewCount: 10,
                danmakuCount: 2,
                likeCount: 3
            ),
            durationSeconds: 120,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            aid: aid,
            pages: [page]
        )
    }

    var playback: VideoPlayback {
        VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: [],
                originalAudioRepresentations: []
            ),
            mediaHeaders: [:]
        )
    }
}

/// 本文件共享的游客视频 port 替身：按闭包回答详情（含分 P）与播放，并记录播放 CID。
private actor LifecycleVideoRepository: VideoRepository {
    private let detailResponse: @Sendable (String) throws -> VideoDetail
    private let playbackResponse: @Sendable (String, Int64) throws -> VideoPlayback
    private(set) var playbackCIDs: [Int64] = []

    init(
        detail: @escaping @Sendable (String) throws -> VideoDetail,
        playback: @escaping @Sendable (String, Int64) throws -> VideoPlayback
    ) {
        detailResponse = detail
        playbackResponse = playback
    }

    /// 按 BVID 选择 fixture；`playbackError` 让每次播放请求都失败。
    init(
        fixtures: [VideoDetailLifecycleFixture],
        playbackError: ContentApplicationError? = nil
    ) {
        let fixturesByBVID = Dictionary(
            uniqueKeysWithValues: fixtures.map { ($0.bvid, $0) }
        )
        let fixture: @Sendable (String) throws -> VideoDetailLifecycleFixture = {
            guard let fixture = fixturesByBVID[$0] else {
                throw ContentApplicationError.invalidRequest
            }
            return fixture
        }
        self.init(
            detail: { try fixture($0).detail },
            playback: { bvid, _ in
                if let playbackError { throw playbackError }
                return try fixture(bvid).playback
            }
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        try detailResponse(bvid)
    }

    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        playbackCIDs.append(cid)
        return try playbackResponse(bvid, cid)
    }
}

/// App 根视图会激活浏览页；本文件只验证播放生命周期，因此 Feed 恒为空。
private struct EmptyLifecycleFeedRepository: FeedRepository {
    func recommendations(
        after continuation: RecommendationContinuation?
    ) async throws -> RecommendationPage {
        throw ContentApplicationError.unavailable
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [], pageNumber: page, pageSize: pageSize)
    }

    func searchVideos(request: VideoSearchRequest) async throws -> SearchPage {
        SearchPage(
            videos: [],
            pageNumber: request.page,
            pageSize: 20,
            totalResults: 0,
            totalPages: 0
        )
    }
}

/// 本文件唯一的评论 port 替身：记录请求的 subject；`rootError` 让根评论请求失败。
private actor LifecycleCommentRepository: CommentRepository {
    private let rootError: CommentReadError?
    private var subjects: [CommentSubjectIdentity] = []
    private var requestWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(rootError: CommentReadError? = nil) {
        self.rootError = rootError
    }

    func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) async throws -> CommentRootPage {
        subjects.append(subject)
        let ready = requestWaiters.filter { $0.target <= subjects.count }
        requestWaiters.removeAll { $0.target <= subjects.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
        if let rootError { throw rootError }
        return CommentRootPage(
            threads: [],
            totalCount: 0,
            continuation: nil,
            isEnd: true
        )
    }

    func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) async throws -> CommentReplyPage {
        if let rootError { throw rootError }
        return CommentReplyPage(
            rootID: rootID,
            replies: [],
            pageNumber: page,
            pageSize: pageSize,
            totalCount: 0
        )
    }

    func requestedSubjects() -> [CommentSubjectIdentity] {
        subjects
    }

    func waitForRequestCount(_ target: Int) async {
        guard subjects.count < target else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((target, continuation))
        }
    }
}

private struct PageSelectionRoutingFixture: Sendable {
    let bvid = "BV1PageRoute"
    let initialPage = VideoPage(
        cid: 910_001,
        index: 1,
        title: "P1",
        durationSeconds: 60
    )
    let failingPage = VideoPage(
        cid: 910_002,
        index: 2,
        title: "P2",
        durationSeconds: 60
    )
    let replacementPage = VideoPage(
        cid: 910_003,
        index: 3,
        title: "P3",
        durationSeconds: 60
    )

    var pages: [VideoPage] {
        [initialPage, failingPage, replacementPage]
    }

    var detail: VideoDetail {
        VideoDetail(
            bvid: bvid,
            title: "分 P 路由测试",
            summary: "手写测试数据",
            coverURL: nil,
            owner: VideoOwner(id: 10_001, name: "测试 UP 主"),
            statistics: VideoStatistics(
                viewCount: 10,
                danmakuCount: 2,
                likeCount: 3
            ),
            durationSeconds: 180,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pages: pages
        )
    }

    var playback: VideoPlayback {
        VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: [],
                originalAudioRepresentations: []
            ),
            mediaHeaders: [:]
        )
    }
}

private actor PendingLifecycleUploaderSignatureRepository:
    UploaderSignatureRepository
{
    private var requestStarted = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<String?, Never>?
    private var requestCompleted = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    func signature(for ownerID: Int64) async throws -> String? {
        requestStarted = true
        for waiter in requestWaiters {
            waiter.resume()
        }
        requestWaiters.removeAll()
        let result = await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
        requestCompleted = true
        for waiter in completionWaiters {
            waiter.resume()
        }
        completionWaiters.removeAll()
        return result
    }

    func waitForRequest() async throws {
        guard !requestStarted else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func releaseLateResult() {
        resultContinuation?.resume(returning: "迟到签名")
        resultContinuation = nil
    }

    func waitForCompletion() async throws {
        guard !requestCompleted else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append(continuation)
        }
    }
}

/// 本文件唯一的播放 port 替身：记录 load/begin/stop；`holdsLoads` 时 load 挂起到
/// `failPendingLoad()` 为止，用于驱动加载失败路径。
@MainActor
private final class LifecyclePlayback: PlaybackControlling {
    private struct ControlledFailure: Error {}

    private let holdsLoads: Bool
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCallCount = 0
    private var pendingLoad: CheckedContinuation<Void, any Error>?
    private var loadWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var stopWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(holdsLoads: Bool = false) {
        self.holdsLoads = holdsLoads
    }

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        AsyncStream { $0.finish() }
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        loadedIdentities.append(identity)
        Self.resume(&loadWaiters, reaching: loadedIdentities.count)
        guard holdsLoads else { return }
        try await withCheckedThrowingContinuation { continuation in
            pendingLoad = continuation
        }
    }

    func beginPlayback(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        initialPositionSeconds: Double?
    ) async -> PlaybackStartOutcome {
        startedIdentities.append(identity)
        return .startedAtBeginning
    }

    func restartFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        resumeToken: PlaybackResumeToken
    ) async -> Bool { false }

    func pause() {}

    func stop() {
        stopCallCount += 1
        Self.resume(&stopWaiters, reaching: stopCallCount)
    }

    func failPendingLoad() {
        pendingLoad?.resume(throwing: ControlledFailure())
        pendingLoad = nil
    }

    func waitForLoadCallCount(_ target: Int) async {
        guard loadedIdentities.count < target else { return }
        await withCheckedContinuation { continuation in
            loadWaiters.append((target, continuation))
        }
    }

    func waitForStopCallCount(_ target: Int) async {
        guard stopCallCount < target else { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append((target, continuation))
        }
    }

    private static func resume(
        _ waiters: inout [(target: Int, continuation: CheckedContinuation<Void, Never>)],
        reaching count: Int
    ) {
        let ready = waiters.filter { $0.target <= count }
        waiters.removeAll { $0.target <= count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

@MainActor
private final class RecordingPresentation: DanmakuPresentationControlling {
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCount = 0
    private var startWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var stopWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func start(for identity: PlaybackItemIdentity) {
        startedIdentities.append(identity)
        resumeStartWaiters()
    }

    func setEnabled(_ enabled: Bool) {}
    func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {}
    func setOpacity(_ opacity: DanmakuOpacity) {}
    func setDisplayArea(_ displayArea: DanmakuDisplayArea) {}
    func setDensity(_ density: DanmakuDensity) {}

    func setModeVisibility(
        scrolling: Bool,
        top: Bool,
        bottom: Bool
    ) {}

    func stop() {
        stopCount += 1
        resumeStopWaiters()
    }

    func waitForStartedCount(_ target: Int) async {
        guard startedIdentities.count < target else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((target, continuation))
        }
    }

    func waitForStopCount(_ target: Int) async {
        guard stopCount < target else { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append((target, continuation))
        }
    }

    private func resumeStartWaiters() {
        let ready = startWaiters.filter { $0.target <= startedIdentities.count }
        startWaiters.removeAll { $0.target <= startedIdentities.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func resumeStopWaiters() {
        let ready = stopWaiters.filter { $0.target <= stopCount }
        stopWaiters.removeAll { $0.target <= stopCount }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

private actor LifecycleAuthenticationService: AuthenticationServicing {
    private var restoreState: AuthenticationState
    private let blocksFirstRestore: Bool
    private var restoreCount = 0
    private var firstRestoreStarted = false
    private var firstRestoreReleased = false
    private var restoreStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var restoreReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var restoreCountWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        restoreState: AuthenticationState,
        blocksFirstRestore: Bool = false
    ) {
        self.restoreState = restoreState
        self.blocksFirstRestore = blocksFirstRestore
    }

    func setRestoreState(_ state: AuthenticationState) {
        restoreState = state
    }

    func restoreCallCount() -> Int {
        restoreCount
    }

    func restore() async -> AuthenticationState {
        restoreCount += 1
        resumeRestoreCountWaiters()
        if blocksFirstRestore, restoreCount == 1 {
            firstRestoreStarted = true
            resume(&restoreStartWaiters)
            await withCheckedContinuation { continuation in
                if firstRestoreReleased {
                    continuation.resume()
                } else {
                    restoreReleaseWaiters.append(continuation)
                }
            }
        }
        return restoreState
    }

    func waitForFirstRestoreStart() async throws {
        if firstRestoreStarted { return }
        await withCheckedContinuation { continuation in
            restoreStartWaiters.append(continuation)
        }
    }

    func waitForRestoreCallCount(_ target: Int) async {
        guard restoreCount < target else { return }
        await withCheckedContinuation { continuation in
            restoreCountWaiters.append((target, continuation))
        }
    }

    func releaseFirstRestore() {
        firstRestoreReleased = true
        resume(&restoreReleaseWaiters)
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }

    private func resumeRestoreCountWaiters() {
        let ready = restoreCountWaiters.filter { $0.target <= restoreCount }
        restoreCountWaiters.removeAll { $0.target <= restoreCount }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
    func requestQRCode() async -> AuthenticationState { .signedOut }
    func pollOnce() async -> AuthenticationState { .signedOut }
    func finalizeLogin() async -> AuthenticationState { .signedOut }
    func cancelLogin() async -> AuthenticationState { .signedOut }
    func logout() async -> AuthenticationState { .signedOut }
}

@MainActor
private final class WatchProgressConnectionProbe {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var accessValues: [Bool] = []

    var connection: WatchProgressWindowConnection {
        WatchProgressWindowConnection(
            start: { [weak self] in self?.startCount += 1 },
            stop: { [weak self] in self?.stopCount += 1 },
            setReportingAccess: { [weak self] in self?.accessValues.append($0) }
        )
    }
}

private struct LifecycleQRCodeProvider: AuthenticationQRCodeProviding {
    func makeQRCodeImage(scale: Int) async throws -> CGImage? { nil }
}

private struct EmptyLifecycleHistoryRepository: WatchHistoryRepository {
    func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage {
        WatchHistoryPage(items: [], continuation: nil)
    }
}
