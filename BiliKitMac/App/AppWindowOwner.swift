import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import SwiftUI

@MainActor
/// 保存一个窗口内必须同代且跨 SwiftUI `body` 重算保持稳定的对象图。
///
/// 尤其是视频、弹幕模型与 `playerContent` 必须共享 `AppEnvironment` 中同一个
/// `AVPlayerEngine`；分别重建会造成画面、时间线与弹幕指向不同播放项目。
final class AppWindowOwner {
    let benchmarkAuthenticationOwnerID = UUID()
    let navigationCoordinator: AppNavigationCoordinator
    let browseModel: GuestBrowseViewModel
    let videoModel: GuestVideoViewModel
    let commentsModel: PlaybackCommentsViewModel?
    let danmakuModel: DanmakuControlsViewModel
    let authenticationModel: AuthenticationViewModel
    let historyModel: WatchHistoryViewModel
    let playerContent: AnyView
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentVideoLinkResolver: CommentVideoLinkResolver
    let commentLinkURLResolver: CommentLinkURLResolver
    let commentImagePipeline: NativeVideoImagePipeline
    private let commentImagePipelineOwner: NativeVideoImagePipelineOwner
    private let playbackPreferencesController: PlaybackPreferencesController?
    private let systemNowPlayingCoordinator: SystemNowPlayingWindowCoordinator?
    private let openEnvironment: (@MainActor @Sendable () -> Void)?
    private let closeEnvironment: (@MainActor @Sendable () -> Void)?
    private var isOpen = false
    private var isClosed = false

    convenience init(
        environment: AppEnvironment,
        systemNowPlayingController: SystemNowPlayingController? = nil
    ) {
        let browseModel = environment.makeBrowseViewModel()
        let videoModel = environment.makeVideoViewModel()
        let commentsModel = environment.makeCommentsViewModel()
        let danmakuModel = environment.makeDanmakuViewModel()
        let navigationCoordinator = AppNavigationCoordinator(
            startPlayback: { intent in
                AppWindowOwner.handlePlaybackSelection(
                    intent,
                    with: videoModel
                )
            },
            stopPlayback: {
                videoModel.reset()
                danmakuModel.reset()
            }
        )
        self.init(
            navigationCoordinator: navigationCoordinator,
            browseModel: browseModel,
            videoModel: videoModel,
            commentsModel: commentsModel,
            danmakuModel: danmakuModel,
            authenticationModel: environment.makeAuthenticationViewModel(),
            historyModel: environment.makeWatchHistoryViewModel(),
            playerContent: environment.makePlayerView(
                videoModel: videoModel,
                danmakuModel: danmakuModel
            ),
            commentAssetURLResolver: environment.commentAssetURLResolver,
            commentVideoLinkResolver: environment.commentVideoLinkResolver,
            commentLinkURLResolver: environment.commentLinkURLResolver,
            playbackPreferencesController: environment.playbackPreferencesController,
            systemNowPlayingController: systemNowPlayingController,
            systemNowPlayingConnection:
                environment.makeSystemNowPlayingPlaybackConnection(),
            openEnvironment: environment.open,
            closeEnvironment: environment.close
        )
    }

    static func handlePlaybackSelection(
        _ intent: PlaybackSelectionIntent,
        with videoModel: GuestVideoViewModel
    ) {
        guard videoModel.presentedBVID == intent.bvid,
            let preferredCID = intent.preferredCID
        else {
            videoModel.loadVideo(
                intent.bvid,
                preferredCID: intent.preferredCID
            )
            return
        }
        if videoModel.failedPageCID == preferredCID {
            videoModel.retry()
        } else {
            videoModel.selectPage(cid: preferredCID)
        }
    }

    init(
        navigationCoordinator: AppNavigationCoordinator,
        browseModel: GuestBrowseViewModel,
        videoModel: GuestVideoViewModel,
        commentsModel: PlaybackCommentsViewModel? = nil,
        danmakuModel: DanmakuControlsViewModel,
        authenticationModel: AuthenticationViewModel,
        historyModel: WatchHistoryViewModel,
        playerContent: AnyView,
        commentAssetURLResolver: @escaping CommentAssetURLResolver = { _ in nil },
        commentVideoLinkResolver: @escaping CommentVideoLinkResolver = { _ in nil },
        commentLinkURLResolver: @escaping CommentLinkURLResolver = { _ in nil },
        commentImagePipelineOwner: NativeVideoImagePipelineOwner =
            NativeVideoImagePipelineOwner(),
        playbackPreferencesController: PlaybackPreferencesController? = nil,
        systemNowPlayingController: SystemNowPlayingController? = nil,
        systemNowPlayingConnection: SystemNowPlayingPlaybackConnection? = nil,
        openEnvironment: (@MainActor @Sendable () -> Void)? = nil,
        closeEnvironment: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.navigationCoordinator = navigationCoordinator
        self.browseModel = browseModel
        self.videoModel = videoModel
        self.commentsModel = commentsModel
        self.danmakuModel = danmakuModel
        self.authenticationModel = authenticationModel
        self.historyModel = historyModel
        self.playerContent = playerContent
        self.commentAssetURLResolver = commentAssetURLResolver
        self.commentVideoLinkResolver = commentVideoLinkResolver
        self.commentLinkURLResolver = commentLinkURLResolver
        self.commentImagePipelineOwner = commentImagePipelineOwner
        commentImagePipeline = commentImagePipelineOwner.pipeline
        self.playbackPreferencesController = playbackPreferencesController
        if let systemNowPlayingController, let systemNowPlayingConnection {
            systemNowPlayingCoordinator = SystemNowPlayingWindowCoordinator(
                controller: systemNowPlayingController,
                connection: systemNowPlayingConnection,
                videoModel: videoModel
            )
        } else {
            systemNowPlayingCoordinator = nil
        }
        self.openEnvironment = openEnvironment
        self.closeEnvironment = closeEnvironment
    }

    func open() {
        guard !isOpen, !isClosed else { return }
        isOpen = true
        openEnvironment?()
        systemNowPlayingCoordinator?.start()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        systemNowPlayingCoordinator?.close()
        commentImagePipelineOwner.shutdown()
        if isOpen {
            closeEnvironment?()
        }
    }

    func markWindowActive() {
        systemNowPlayingCoordinator?.markWindowActive()
    }
}
