import AVKit
import AppKit
import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliDanmaku
import BiliLibraryFeature
import BiliModels
import CoreGraphics
import SwiftUI
import Testing

@testable import BiliKit

struct VideoDetailLifecycleTests {
    @Test
    @MainActor
    func playbackFailureStopsPresentationAndRetryStartsItAgain() async {
        let fixture = VideoDetailLifecycleFixture()
        let player = ControlledFailingPlayback()
        let videoModel = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: VideoDetailLifecycleRepository(fixture: fixture)
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
                    onRetry: {}
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
        #expect(
            await waitUntil {
                presentation.stopCount > 0
            }
        )
        let baselineStopCount = presentation.stopCount

        videoModel.loadVideo(fixture.bvid)
        #expect(
            await waitUntil {
                player.loadCallCount == 1
                    && videoModel.presentedContext?.detail.bvid == fixture.bvid
                    && presentation.startedIdentities.count == 1
            }
        )

        player.failPendingLoad()
        await videoModel.waitForCurrentTask()
        #expect(
            await waitUntil {
                if case .failed = videoModel.state {
                    return videoModel.presentedContext?.detail.bvid
                        == fixture.bvid
                        && presentation.stopCount == baselineStopCount + 1
                }
                return false
            }
        )

        videoModel.loadVideo(fixture.bvid)
        #expect(
            await waitUntil {
                player.loadCallCount == 2
                    && presentation.startedIdentities.count == 2
            }
        )

        player.failPendingLoad()
        await videoModel.waitForCurrentTask()
        #expect(
            await waitUntil {
                presentation.stopCount == baselineStopCount + 2
            }
        )

        window.contentView = NSView()
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func replacementKeepsPlayerSurfaceUntilReset() async throws {
        let first = VideoDetailLifecycleFixture(
            bvid: "BV1LifecycleFirst",
            cid: 900_001,
            title: "第一个视频"
        )
        let replacement = VideoDetailLifecycleFixture(
            bvid: "BV1LifecycleReplacement",
            cid: 900_002,
            title: "替换视频"
        )
        let repository = ReplacementLifecycleRepository(
            first: first,
            replacement: replacement
        )
        let relatedRepository = RelatedLifecycleRepository(
            replacementBVID: replacement.bvid
        )
        let signatureRepository = LifecycleUploaderSignatureRepository()
        let player = ControlledReplacementPlayback()
        let videoModel = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: player,
            relatedVideoUseCase: RelatedVideoUseCase(
                repository: relatedRepository
            ),
            uploaderSignatureUseCase: UploaderSignatureUseCase(
                repository: signatureRepository
            )
        )
        let presentation = RecordingPresentation()
        let danmakuModel = DanmakuControlsViewModel(
            presentation: presentation
        )
        let hostedPlayer = AVPlayer()
        let renderer = CoreAnimationDanmakuRenderer()
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: DanmakuLaneConfiguration(
                surfaceWidth: 0,
                surfaceHeight: 0,
                laneHeight: 36,
                minimumHorizontalGap: 12,
                maximumActiveCount:
                    DanmakuLaneConfiguration.hardMaximumActiveCount,
                displayAreaFraction: 1
            )
        )
        let coordinator = AppNavigationCoordinator(
            startPlayback: { bvid in
                videoModel.loadVideo(bvid)
            },
            stopPlayback: {
                videoModel.reset()
                danmakuModel.reset()
            }
        )
        let selectRelatedVideo: (String) -> Void = { bvid in
            coordinator.openPlayback(bvid)
        }
        let playerSurface = PlayerSurfaceRecorder()
        let hostingView = NSHostingView(
            rootView: AnyView(
                VideoPlaybackView(
                    model: videoModel,
                    danmakuModel: danmakuModel,
                    onRetry: {},
                    onSelectRelatedVideo: selectRelatedVideo
                ) {
                    ZStack {
                        PlayerHostView(
                            player: hostedPlayer,
                            danmakuRenderer: renderer,
                            danmakuController: controller
                        )
                        PlayerSurfaceProbe(
                            recorder: playerSurface,
                            phase: PlayerSurfacePhase(videoModel.state)
                        )
                    }
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

        coordinator.openPlayback(first.bvid)
        #expect(
            await waitUntilAsync {
                guard
                    case .loading(let bvid) = videoModel.state,
                    bvid == first.bvid
                else {
                    return false
                }
                return await repository.firstRequestHasStarted()
            }
        )
        hostingView.layoutSubtreeIfNeeded()
        let initialDetailScrollView = try #require(
            verticallyScrollableViews(in: hostingView).first
        )
        #expect(verticallyScrollableViews(in: hostingView).count == 1)

        await repository.releaseFirstRequest()
        #expect(
            await waitUntil {
                guard case .ready(let context) = videoModel.state else {
                    return false
                }
                return context.detail.bvid == first.bvid
                    && videoModel.presentedContext?.detail.bvid == first.bvid
                    && playerSurface.createdIdentities.count == 1
                    && self.playerViews(in: hostingView).count == 1
                    && presentation.startedIdentities.last?.bvid == first.bvid
            }
        )
        let surfaceIdentity = playerSurface.createdIdentities[0]
        let playerView = try #require(playerViews(in: hostingView).first)
        let playerViewIdentity = ObjectIdentifier(playerView)
        let detailScrollView = try #require(
            firstAncestor(ofType: NSScrollView.self, from: playerView)
        )
        #expect(detailScrollView === initialDetailScrollView)
        #expect(playerView.player === hostedPlayer)
        #expect(
            await waitUntil {
                self.verticallyScrollableViews(in: hostingView).map(
                    ObjectIdentifier.init
                ) == [ObjectIdentifier(detailScrollView)]
            }
        )
        let stopCountBeforeReplacement = presentation.stopCount

        #expect(
            await waitUntilAsync {
                await relatedRepository.firstRequestHasStarted()
            }
        )
        await relatedRepository.releaseFirstRequest()
        await videoModel.waitForCurrentRelatedVideoTask()
        hostingView.layoutSubtreeIfNeeded()
        #expect(
            videoModel.relatedVideoState
                == .loaded(
                    bvid: first.bvid,
                    videos: [relatedRepository.fixture]
                )
        )
        #expect(player.loadedIdentities == [first.identity])
        await videoModel.waitForCurrentUploaderSignatureTask()
        #expect(videoModel.uploaderSignatureState == .loaded("首个签名"))
        #expect(playerSurface.createdIdentities == [surfaceIdentity])
        #expect(playerSurface.dismantledIdentities.isEmpty)
        #expect(
            playerViews(in: hostingView).first.map(ObjectIdentifier.init)
                == Optional(playerViewIdentity)
        )
        #expect(
            verticallyScrollableViews(in: hostingView).map(
                ObjectIdentifier.init
            ) == [ObjectIdentifier(detailScrollView)]
        )
        let replacementViewportOrigin = scrollToBottom(detailScrollView)
        #expect(replacementViewportOrigin.y > 0)

        selectRelatedVideo(relatedRepository.fixture.bvid)
        #expect(
            await waitUntilAsync {
                guard
                    case .loading(let bvid) = videoModel.state,
                    bvid == replacement.bvid
                else {
                    return false
                }
                return await repository.replacementRequestHasStarted()
                    && videoModel.presentedContext?.detail.bvid == first.bvid
                    && playerSurface.lastUpdatedPhase == .loading
                    && presentation.stopCount
                        == stopCountBeforeReplacement + 1
            }
        )
        #expect(player.loadedIdentities == [first.identity])
        #expect(player.stopCallCount == 1)
        #expect(playerSurface.createdIdentities == [surfaceIdentity])
        #expect(playerSurface.dismantledIdentities.isEmpty)
        #expect(
            playerViews(in: hostingView).first.map(ObjectIdentifier.init)
                == Optional(playerViewIdentity)
        )
        hostingView.layoutSubtreeIfNeeded()
        #expect(
            verticallyScrollableViews(in: hostingView).map(
                ObjectIdentifier.init
            ) == [ObjectIdentifier(detailScrollView)]
        )
        #expect(
            abs(
                detailScrollView.contentView.bounds.origin.y
                    - replacementViewportOrigin.y
            ) < 2
        )

        await repository.failReplacementRequest()
        await videoModel.waitForCurrentTask()
        hostingView.layoutSubtreeIfNeeded()
        #expect(
            await waitUntil {
                if case .failed(let bvid, .content) = videoModel.state {
                    return bvid == replacement.bvid
                        && videoModel.presentedContext?.detail.bvid == first.bvid
                        && playerSurface.lastUpdatedPhase == .failed
                }
                return false
            }
        )
        #expect(playerSurface.createdIdentities == [surfaceIdentity])
        #expect(playerSurface.dismantledIdentities.isEmpty)
        #expect(
            verticallyScrollableViews(in: hostingView).map(
                ObjectIdentifier.init
            ) == [ObjectIdentifier(detailScrollView)]
        )
        #expect(
            playerViews(in: hostingView).first.map(ObjectIdentifier.init)
                == Optional(playerViewIdentity)
        )

        coordinator.retryPlayback()
        #expect(
            await waitUntil {
                guard
                    case .preparingPlayback(let context) = videoModel.state
                else {
                    return false
                }
                return context.detail.bvid == replacement.bvid
                    && videoModel.presentedContext?.detail.bvid
                        == replacement.bvid
                    && playerSurface.lastUpdatedPhase == .preparing
                    && player.loadedIdentities == [
                        first.identity,
                        replacement.identity,
                    ]
                    && presentation.startedIdentities.last?.bvid
                        == replacement.bvid
            }
        )
        #expect(playerSurface.createdIdentities == [surfaceIdentity])
        #expect(playerSurface.dismantledIdentities.isEmpty)
        #expect(
            verticallyScrollableViews(in: hostingView).map(
                ObjectIdentifier.init
            ) == [ObjectIdentifier(detailScrollView)]
        )
        #expect(
            playerViews(in: hostingView).first.map(ObjectIdentifier.init)
                == Optional(playerViewIdentity)
        )

        player.succeedPendingLoad()
        await videoModel.waitForCurrentTask()
        await videoModel.waitForCurrentUploaderSignatureTask()
        #expect(
            await waitUntil {
                if case .ready(let context) = videoModel.state {
                    return context.detail.bvid == replacement.bvid
                        && playerSurface.lastUpdatedPhase == .ready
                }
                return false
            }
        )
        #expect(playerSurface.createdIdentities == [surfaceIdentity])
        #expect(videoModel.uploaderSignatureState == .loaded("替换后签名"))
        #expect(await signatureRepository.callCount == 2)
        #expect(playerSurface.dismantledIdentities.isEmpty)
        #expect(
            playerViews(in: hostingView).first.map(ObjectIdentifier.init)
                == Optional(playerViewIdentity)
        )

        let stopCountBeforeBack = presentation.stopCount
        coordinator.playbackPath = []
        #expect(
            await waitUntil {
                playerSurface.dismantledIdentities == [surfaceIdentity]
                    && videoModel.presentedContext == nil
                    && self.playerViews(in: hostingView).isEmpty
                    && playerView.player == nil
            }
        )
        #expect(playerSurface.createdIdentities == [surfaceIdentity])
        #expect(player.stopCallCount == 3)
        #expect(
            !verticallyScrollableViews(in: hostingView).contains {
                $0 === detailScrollView
            }
        )
        #expect(
            presentation.startedIdentities == [
                first.identity,
                replacement.identity,
            ]
        )
        #expect(presentation.stopCount > stopCountBeforeBack)

        window.contentView = NSView()
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func backCancelsPendingUploaderSignatureRequest()
        async throws
    {
        let fixture = VideoDetailLifecycleFixture()
        let signatureRepository = PendingLifecycleUploaderSignatureRepository()
        let videoModel = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: VideoDetailLifecycleRepository(fixture: fixture)
            ),
            playback: RecordingLifecyclePlayback(),
            uploaderSignatureUseCase: UploaderSignatureUseCase(
                repository: signatureRepository
            )
        )
        let coordinator = AppNavigationCoordinator(
            startPlayback: { bvid in
                videoModel.loadVideo(bvid)
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
        let repository = VideoDetailLifecycleRepository(fixture: fixture)
        let playback = RecordingLifecyclePlayback()
        let browseModel = GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )
        let videoModel = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
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
            startPlayback: { bvid in
                videoModel.loadVideo(bvid)
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
                playerContent: AnyView(EmptyView())
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

        coordinator.openPlayback(fixture.bvid)
        await videoModel.waitForCurrentTask()
        #expect(
            await waitUntil {
                playback.loadedIdentities == [fixture.identity]
                    && videoModel.presentedContext?.detail.bvid == fixture.bvid
            }
        )

        let loadCountBeforeRestore = playback.loadedIdentities.count
        let stopCountBeforeRestore = playback.stopCallCount
        await authenticationService.releaseFirstRestore()
        await authenticationModel.waitForCurrentTask()
        #expect(authenticationModel.sessionState == .signedIn(nil))
        #expect(coordinator.currentPlaybackBVID == fixture.bvid)
        #expect(playback.loadedIdentities.count == loadCountBeforeRestore)
        #expect(playback.stopCallCount == stopCountBeforeRestore)

        let identity = AccountIdentity(
            id: 42,
            displayName: "测试账号",
            avatarURL: nil
        )
        await authenticationService.setRestoreState(.signedIn(identity))
        let stopCountBeforeIdentity = playback.stopCallCount
        authenticationModel.revalidate()
        await authenticationModel.waitForCurrentTask()
        #expect(authenticationModel.sessionState == .signedIn(identity))
        #expect(coordinator.currentPlaybackBVID == fixture.bvid)
        #expect(playback.stopCallCount == stopCountBeforeIdentity)

        let stopCountBeforeLogout = playback.stopCallCount
        authenticationModel.logout()
        await authenticationModel.waitForCurrentTask()
        #expect(
            await waitUntil {
                authenticationModel.sessionState == .signedOut
                    && videoModel.state == .idle
                    && coordinator.currentPlaybackBVID == nil
            }
        )
        #expect(playback.stopCallCount == stopCountBeforeLogout + 1)

        coordinator.openPlayback(fixture.bvid)
        await videoModel.waitForCurrentTask()
        #expect(
            await waitUntil {
                playback.loadedIdentities == [
                    fixture.identity,
                    fixture.identity,
                ]
                    && coordinator.currentPlaybackBVID == fixture.bvid
            }
        )
        let loadCountBeforeSignIn = playback.loadedIdentities.count
        let stopCountBeforeSignIn = playback.stopCallCount

        await authenticationService.setRestoreState(.signedIn(identity))
        authenticationModel.revalidate()
        await authenticationModel.waitForCurrentTask()
        #expect(
            await waitUntil {
                authenticationModel.sessionState == .signedIn(identity)
                    && videoModel.state == .idle
                    && coordinator.currentPlaybackBVID == nil
            }
        )
        #expect(playback.loadedIdentities.count == loadCountBeforeSignIn)
        #expect(playback.stopCallCount == stopCountBeforeSignIn + 1)

        window.contentView = NSView()
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func invalidPlaybackCredentialRevalidatesAndClosesPlayback() async throws {
        let fixture = VideoDetailLifecycleFixture()
        let repository = VideoDetailLifecycleRepository(
            fixture: fixture,
            playbackError: .authenticationInvalid
        )
        let playback = RecordingLifecyclePlayback()
        let videoModel = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: playback
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
            startPlayback: { videoModel.loadVideo($0) },
            stopPlayback: {
                videoModel.reset()
                danmakuModel.reset()
            }
        )
        let hostingView = NSHostingView(
            rootView: AppRootView(
                navigationCoordinator: coordinator,
                browseModel: GuestBrowseViewModel(
                    useCase: GuestFeedUseCase(repository: repository)
                ),
                videoModel: videoModel,
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
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        #expect(
            await waitUntilAsync {
                await authenticationService.restoreCallCount() == 1
                    && authenticationModel.sessionState == .signedIn(nil)
            }
        )

        await authenticationService.setRestoreState(.signedOut)
        coordinator.openPlayback(fixture.bvid)
        await videoModel.waitForCurrentTask()

        #expect(
            await waitUntilAsync {
                await authenticationService.restoreCallCount() == 2
                    && authenticationModel.sessionState == .signedOut
                    && coordinator.currentPlaybackBVID == nil
                    && videoModel.state == .idle
            }
        )
        #expect(playback.loadedIdentities.isEmpty)
        #expect(playback.stopCallCount == 1)
        window.contentView = NSView()
    }

    @MainActor
    private func playerViews(in root: NSView) -> [AVPlayerView] {
        var matches: [AVPlayerView] = []
        if let playerView = root as? AVPlayerView {
            matches.append(playerView)
        }
        for child in root.subviews {
            matches.append(contentsOf: playerViews(in: child))
        }
        return matches
    }

    @MainActor
    private func verticallyScrollableViews(in root: NSView) -> [NSScrollView] {
        var matches: [NSScrollView] = []
        if let scrollView = root as? NSScrollView,
            let documentView = scrollView.documentView,
            documentView.bounds.height > scrollView.contentView.bounds.height
        {
            matches.append(scrollView)
        }
        for child in root.subviews {
            matches.append(contentsOf: verticallyScrollableViews(in: child))
        }
        return matches
    }

    @MainActor
    private func firstAncestor<ViewType: NSView>(
        ofType type: ViewType.Type,
        from view: NSView
    ) -> ViewType? {
        var ancestor = view.superview
        while let current = ancestor {
            if let match = current as? ViewType {
                return match
            }
            ancestor = current.superview
        }
        return nil
    }

    @MainActor
    private func scrollToBottom(_ scrollView: NSScrollView) -> NSPoint {
        guard let documentView = scrollView.documentView else {
            return scrollView.contentView.bounds.origin
        }
        let origin = NSPoint(
            x: scrollView.contentView.bounds.origin.x,
            y: max(
                0,
                documentView.bounds.maxY
                    - scrollView.contentView.bounds.height
            )
        )
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return scrollView.contentView.bounds.origin
    }

    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    @MainActor
    private func waitUntilAsync(
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !(await condition()) {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}

private struct VideoDetailLifecycleFixture: Sendable {
    let bvid: String
    let page: VideoPage
    let title: String

    init(
        bvid: String = "BV1LifecycleFixture",
        cid: Int64 = 900_001,
        title: String = "生命周期测试视频"
    ) {
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
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
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

private actor VideoDetailLifecycleRepository: GuestContentRepository {
    let fixture: VideoDetailLifecycleFixture
    let playbackError: GuestApplicationError?

    init(
        fixture: VideoDetailLifecycleFixture,
        playbackError: GuestApplicationError? = nil
    ) {
        self.fixture = fixture
        self.playbackError = playbackError
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
        fixture.detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [fixture.page]
    }

    func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        if let playbackError { throw playbackError }
        return fixture.playback
    }
}

private actor ReplacementLifecycleRepository: GuestContentRepository {
    let first: VideoDetailLifecycleFixture
    let replacement: VideoDetailLifecycleFixture
    private var blocksFirst = true
    private var blocksReplacement = true
    private var firstRequestStarted = false
    private var replacementRequestStarted = false
    private var blockedFirstRequest: CheckedContinuation<Void, Never>?
    private var blockedRequest: CheckedContinuation<Void, any Error>?

    init(
        first: VideoDetailLifecycleFixture,
        replacement: VideoDetailLifecycleFixture
    ) {
        self.first = first
        self.replacement = replacement
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
        if bvid == first.bvid, blocksFirst {
            await withCheckedContinuation { continuation in
                blockedFirstRequest = continuation
                firstRequestStarted = true
            }
        }
        if bvid == replacement.bvid, blocksReplacement {
            try await withCheckedThrowingContinuation { continuation in
                blockedRequest = continuation
                replacementRequestStarted = true
            }
        }
        return fixture(for: bvid).detail
    }

    func firstRequestHasStarted() -> Bool {
        firstRequestStarted
    }

    func releaseFirstRequest() {
        blocksFirst = false
        blockedFirstRequest?.resume()
        blockedFirstRequest = nil
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [fixture(for: bvid).page]
    }

    func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        fixture(for: bvid).playback
    }

    func replacementRequestHasStarted() -> Bool {
        replacementRequestStarted
    }

    func failReplacementRequest() {
        blocksReplacement = false
        blockedRequest?.resume(
            throwing: GuestApplicationError.transportFailure
        )
        blockedRequest = nil
    }

    private func fixture(
        for bvid: String
    ) -> VideoDetailLifecycleFixture {
        bvid == first.bvid ? first : replacement
    }
}

private actor RelatedLifecycleRepository: RelatedVideoRepository {
    nonisolated let fixture: RelatedVideo
    private var didStartFirstRequest = false
    private var firstRequest: CheckedContinuation<[RelatedVideo], Never>?

    init(replacementBVID: String) {
        fixture = RelatedVideo(
            bvid: replacementBVID,
            title: "相关推荐",
            coverURL: nil,
            ownerName: "测试作者",
            viewCount: 100,
            danmakuCount: 10,
            durationSeconds: 120
        )
    }

    func relatedVideos(to bvid: String) async throws -> [RelatedVideo] {
        guard !didStartFirstRequest else { return [] }
        didStartFirstRequest = true
        return await withCheckedContinuation { continuation in
            firstRequest = continuation
        }
    }

    func firstRequestHasStarted() -> Bool {
        didStartFirstRequest && firstRequest != nil
    }

    func releaseFirstRequest() {
        firstRequest?.resume(returning: [fixture])
        firstRequest = nil
    }
}

private actor LifecycleUploaderSignatureRepository:
    UploaderSignatureRepository
{
    private(set) var callCount = 0

    func signature(for ownerID: Int64) async throws -> String? {
        callCount += 1
        return callCount == 1 ? "首个签名" : "替换后签名"
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

@MainActor
private final class ControlledFailingPlayback: PlaybackControlling {
    private(set) var loadCallCount = 0
    private var pendingLoad: CheckedContinuation<Void, any Error>?

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        finishedPlaybackFailureEvents()
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        loadCallCount += 1
        try await withCheckedThrowingContinuation { continuation in
            pendingLoad = continuation
        }
    }

    func pause() {}

    func stop() {}

    func failPendingLoad() {
        pendingLoad?.resume(throwing: ControlledPlaybackFailure())
        pendingLoad = nil
    }
}

@MainActor
private final class ControlledReplacementPlayback: PlaybackControlling {
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCallCount = 0
    private var pendingLoad: CheckedContinuation<Void, any Error>?

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        finishedPlaybackFailureEvents()
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        loadedIdentities.append(identity)
        guard loadedIdentities.count > 1 else { return }
        try await withCheckedThrowingContinuation { continuation in
            pendingLoad = continuation
        }
    }

    func pause() {}

    func stop() {
        stopCallCount += 1
    }

    func succeedPendingLoad() {
        pendingLoad?.resume()
        pendingLoad = nil
    }
}

private struct ControlledPlaybackFailure: Error {}

private func finishedPlaybackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
    AsyncStream { continuation in
        continuation.finish()
    }
}

@MainActor
private final class RecordingLifecyclePlayback: PlaybackControlling {
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCallCount = 0

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        finishedPlaybackFailureEvents()
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        loadedIdentities.append(identity)
    }

    func pause() {}

    func stop() {
        stopCallCount += 1
    }
}

@MainActor
private final class PlayerSurfaceRecorder {
    private(set) var createdIdentities: [ObjectIdentifier] = []
    private(set) var dismantledIdentities: [ObjectIdentifier] = []
    private(set) var updatedPhases: [PlayerSurfacePhase] = []

    var lastUpdatedPhase: PlayerSurfacePhase? {
        updatedPhases.last
    }

    func recordCreation(of view: NSView) {
        createdIdentities.append(ObjectIdentifier(view))
    }

    func recordDismantle(of view: NSView) {
        dismantledIdentities.append(ObjectIdentifier(view))
    }

    func recordUpdate(phase: PlayerSurfacePhase) {
        updatedPhases.append(phase)
    }
}

private struct PlayerSurfaceProbe: NSViewRepresentable {
    let recorder: PlayerSurfaceRecorder
    let phase: PlayerSurfacePhase

    func makeCoordinator() -> PlayerSurfaceRecorder {
        recorder
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.recordCreation(of: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.recordUpdate(phase: phase)
    }

    static func dismantleNSView(
        _ nsView: NSView,
        coordinator: PlayerSurfaceRecorder
    ) {
        coordinator.recordDismantle(of: nsView)
    }
}

private enum PlayerSurfacePhase: Equatable {
    case idle
    case loading
    case preparing
    case ready
    case failed

    init(_ state: GuestVideoState) {
        switch state {
        case .idle:
            self = .idle
        case .loading:
            self = .loading
        case .loadingPage:
            self = .loading
        case .preparingPlayback:
            self = .preparing
        case .ready:
            self = .ready
        case .failed:
            self = .failed
        case .failedPage:
            self = .failed
        }
    }
}

@MainActor
private final class RecordingPresentation: DanmakuPresentationControlling {
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCount = 0

    func start(for identity: PlaybackItemIdentity) {
        startedIdentities.append(identity)
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
    func requestQRCode() async -> AuthenticationState { .signedOut }
    func pollOnce() async -> AuthenticationState { .signedOut }
    func finalizeLogin() async -> AuthenticationState { .signedOut }
    func cancelLogin() async -> AuthenticationState { .signedOut }
    func logout() async -> AuthenticationState { .signedOut }
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
