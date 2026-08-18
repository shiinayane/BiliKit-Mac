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
    let navigationCoordinator: AppNavigationCoordinator
    let browseModel: GuestBrowseViewModel
    let videoModel: GuestVideoViewModel
    let commentsModel: PlaybackCommentsViewModel?
    let danmakuModel: DanmakuControlsViewModel
    let authenticationModel: AuthenticationViewModel
    let historyModel: WatchHistoryViewModel
    let playerContent: AnyView
    private let playbackPreferencesController: PlaybackPreferencesController?
    private let openEnvironment: (@MainActor @Sendable () -> Void)?
    private let closeEnvironment: (@MainActor @Sendable () -> Void)?
    private var isOpen = false
    private var isClosed = false

    convenience init(environment: AppEnvironment) {
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
            playerContent: environment.makePlayerView(videoModel: videoModel),
            playbackPreferencesController: environment.playbackPreferencesController,
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
        playbackPreferencesController: PlaybackPreferencesController? = nil,
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
        self.playbackPreferencesController = playbackPreferencesController
        self.openEnvironment = openEnvironment
        self.closeEnvironment = closeEnvironment
    }

    func open() {
        guard !isOpen, !isClosed else { return }
        isOpen = true
        openEnvironment?()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if isOpen {
            closeEnvironment?()
        }
    }
}
