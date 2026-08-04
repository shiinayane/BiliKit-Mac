import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import SwiftUI

@MainActor
/// 保存一个窗口内必须同代且跨 SwiftUI `body` 重算保持稳定的对象图。
///
/// 尤其是视频、字幕、弹幕模型与 `playerContent` 必须共享 `AppEnvironment` 中同一个
/// `AVPlayerEngine`；分别重建会造成画面、时间线与 overlay 指向不同播放项目。
final class AppWindowOwner {
    let navigationCoordinator: AppNavigationCoordinator
    let browseModel: GuestBrowseViewModel
    let videoModel: GuestVideoViewModel
    let subtitleModel: SubtitleViewModel
    let danmakuModel: DanmakuControlsViewModel
    let authenticationModel: AuthenticationViewModel
    let historyModel: WatchHistoryViewModel
    let playerContent: AnyView

    convenience init(environment: AppEnvironment) {
        let browseModel = environment.makeBrowseViewModel()
        let videoModel = environment.makeVideoViewModel()
        let subtitleModel = environment.makeSubtitleViewModel()
        let danmakuModel = environment.makeDanmakuViewModel()
        let navigationCoordinator = AppNavigationCoordinator(
            startPlayback: { bvid in
                videoModel.loadVideo(bvid)
            },
            stopPlayback: {
                videoModel.reset()
                subtitleModel.reset()
                danmakuModel.reset()
            }
        )
        self.init(
            navigationCoordinator: navigationCoordinator,
            browseModel: browseModel,
            videoModel: videoModel,
            subtitleModel: subtitleModel,
            danmakuModel: danmakuModel,
            authenticationModel: environment.makeAuthenticationViewModel(),
            historyModel: environment.makeWatchHistoryViewModel(),
            playerContent: environment.makePlayerView(
                subtitleModel: subtitleModel
            )
        )
    }

    init(
        navigationCoordinator: AppNavigationCoordinator,
        browseModel: GuestBrowseViewModel,
        videoModel: GuestVideoViewModel,
        subtitleModel: SubtitleViewModel,
        danmakuModel: DanmakuControlsViewModel,
        authenticationModel: AuthenticationViewModel,
        historyModel: WatchHistoryViewModel,
        playerContent: AnyView
    ) {
        self.navigationCoordinator = navigationCoordinator
        self.browseModel = browseModel
        self.videoModel = videoModel
        self.subtitleModel = subtitleModel
        self.danmakuModel = danmakuModel
        self.authenticationModel = authenticationModel
        self.historyModel = historyModel
        self.playerContent = playerContent
    }
}
