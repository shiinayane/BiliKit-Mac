import AppKit
import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliDanmaku
import BiliLibraryFeature
import BiliModels
import BiliVideoDetailFeature
import CoreGraphics
import SwiftUI
import Testing

@testable import BiliKit

/// 播放页挂进真实窗口后的生命周期：播放失败停止弹幕、重试重新开始，返回取消在途的名片请求。
///
/// 只有解析出的账户边界才关闭播放；凭据失效触发复核并关闭播放；评论按 aid 激活、返回时清空。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct VideoDetailLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func playbackFailureStopsPresentationAndRetryStartsItAgain() async {
        let fixture = VideoFixture()
        let player = RecordingPlayback(holdsLoads: true)
        let videoModel = makeVideoViewModel(
            useCase: VideoUseCase(
                repository: FixtureVideoRepository(fixtures: [fixture])
            ),
            playback: player
        )
        let presentation = RecordingDanmakuPresentation()
        let danmakuModel = DanmakuControlsViewModel(presentation: presentation)
        let window = mountedWindow(
            AnyView(
                VideoPlaybackView(
                    model: videoModel,
                    danmakuModel: danmakuModel,
                    engagementModel: VideoEngagementModel(
                        useCase: VideoEngagementUseCase(repository: AccountWriteRepositoryStub()),
                        accountID: { nil }
                    ),
                    onRetry: {},
                    relatedImageLoader: NoImageCardLoader()
                ) {
                    EmptyView()
                }
            ),
            width: 800,
            height: 600
        )
        await presentation.waitForStopCount(1)
        let baselineStopCount = presentation.stopCount

        videoModel.loadVideo(fixture.bvid)
        await player.waitForLoadCallCount(1)
        await presentation.waitForStartedCount(1)
        #expect(player.loadedIdentities.count == 1)
        #expect(presentation.startedIdentities.count == 1)
        #expect(videoModel.presentedContext?.detail.bvid == fixture.bvid)

        player.failPendingLoad()
        await waitUntilSettled(videoModel)
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
        await waitUntilSettled(videoModel)
        await presentation.waitForStopCount(baselineStopCount + 2)
        #expect(presentation.stopCount == baselineStopCount + 2)

        window.contentView = NSView()
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func backCancelsPendingUploaderProfileRequest()
        async throws
    {
        let fixture = VideoFixture()
        let profileRepository = UploaderProfileRepositoryStub(holdsRequests: true)
        let composition = WindowComposition(
            process: makeTestProcess(),
            adapters: makeTestAdapters(
                video: FixtureVideoRepository(fixtures: [fixture]),
                uploaderProfile: profileRepository
            )
        )
        let videoModel = composition.videoModel
        let coordinator = composition.navigationCoordinator

        coordinator.openPlayback(fixture.bvid)
        await waitUntilSettled(videoModel)
        try await profileRepository.waitForRequest()
        #expect(videoModel.uploaderProfileState == .loading)

        coordinator.playbackPath = []
        await profileRepository.releaseLateResult()
        try await profileRepository.waitForCompletion()

        #expect(videoModel.state == .idle)
        #expect(videoModel.presentedContext == nil)
        #expect(videoModel.uploaderProfileState == .loaded(UploaderProfile()))
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func onlyResolvedAuthenticationBoundaryClosesPlayback() async throws {
        let fixture = VideoFixture()
        let watchProgressProbe = WatchProgressConnectionProbe()
        let repository = FixtureVideoRepository(fixtures: [fixture])
        let playback = RecordingPlayback()
        let authenticationService = AuthenticationServiceStub(
            restoreState: .signedIn(nil),
            blocksFirstRestore: true
        )
        let composition = WindowComposition(
            process: makeTestProcess(),
            adapters: makeTestAdapters(
                video: repository,
                authentication: authenticationService,
                playback: playback,
                watchProgress: watchProgressProbe.connection
            )
        )
        let videoModel = composition.videoModel
        let authenticationModel = composition.authenticationModel
        let coordinator = composition.navigationCoordinator
        let window = mountedWindow(
            AppRootView(window: composition),
            width: 800,
            height: 600
        )
        try await authenticationService.waitForFirstRestoreStart()
        #expect(authenticationModel.sessionState == .unresolved)
        #expect(watchProgressProbe.startCount == 1)
        #expect(watchProgressProbe.accessValues == [false])

        coordinator.openPlayback(fixture.bvid)
        await waitUntilSettled(videoModel)
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
        await waitUntilSettled(videoModel)
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
        await waitUntilSettled(videoModel)
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
        let fixture = VideoFixture()
        let repository = FixtureVideoRepository(
            fixtures: [fixture],
            playbackError: source == .playback ? .authenticationInvalid : nil
        )
        let playback = RecordingPlayback()
        let authenticationService = AuthenticationServiceStub(restoreState: .signedIn(nil))
        let composition = WindowComposition(
            process: makeTestProcess(),
            adapters: makeTestAdapters(
                video: repository,
                comments: CommentRepositoryStub(
                    rootError: source == .comments ? .authenticationInvalid : nil
                ),
                authentication: authenticationService,
                playback: playback
            )
        )
        let videoModel = composition.videoModel
        let commentsModel = composition.commentsModel
        let authenticationModel = composition.authenticationModel
        let coordinator = composition.navigationCoordinator
        let window = mountedWindow(
            AppRootView(window: composition),
            width: 1_080,
            height: 680
        )
        await authenticationService.waitForRestoreCallCount(1)
        await authenticationModel.waitForCurrentTask()
        #expect(authenticationModel.sessionState == .signedIn(nil))

        await authenticationService.setRestoreState(.signedOut)
        coordinator.openPlayback(fixture.bvid)
        await waitUntilSettled(videoModel)
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

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func appRootActivatesCommentsByAIDAndClearsThemOnBack() async {
        let first = VideoFixture(
            aid: 700_001,
            bvid: "BV1CommentLifecycleA",
            cid: 900_001,
            title: "评论生命周期 A"
        )
        let replacement = VideoFixture(
            aid: 700_002,
            bvid: "BV1CommentLifecycleB",
            cid: 900_002,
            title: "评论生命周期 B"
        )
        let repository = FixtureVideoRepository(
            fixtures: [first, replacement]
        )
        let commentsRepository = CommentRepositoryStub()
        let composition = WindowComposition(
            process: makeTestProcess(),
            adapters: makeTestAdapters(
                video: repository,
                comments: commentsRepository,
                authentication: AuthenticationServiceStub(restoreState: .signedOut)
            )
        )
        let videoModel = composition.videoModel
        let commentsModel = composition.commentsModel
        let coordinator = composition.navigationCoordinator
        let window = mountedWindow(
            AppRootView(window: composition),
            width: 1_080,
            height: 680
        )

        coordinator.openPlayback(first.bvid)
        await waitUntilSettled(videoModel)
        await commentsRepository.waitForRequestCount(1)
        await commentsModel.waitForCurrentRootTask()
        #expect(commentsModel.subject == .video(aid: first.aid))
        #expect(commentsModel.rootState == .empty)

        coordinator.openPlayback(replacement.bvid)
        await waitUntilSettled(videoModel)
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
}

/// 把 SwiftUI 根视图挂进一个无边框窗口并完成一次布局，让视图的出现与消失回调真正运行；调用方结束时把
/// `contentView` 换成空视图，触发消失回调。
@MainActor
private func mountedWindow(_ rootView: some View, width: CGFloat, height: CGFloat) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = NSHostingView(rootView: rootView)
    window.layoutIfNeeded()
    return window
}

enum VideoDetailCredentialFailureSource: CaseIterable, Sendable {
    case playback
    case comments
}
