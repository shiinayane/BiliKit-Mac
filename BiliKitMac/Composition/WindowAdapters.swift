import AVFoundation
import BiliAPI
import BiliApplication
import BiliAuth
import BiliAuthFeature
import BiliDanmaku
import BiliModels
import BiliPlayback
import BiliVideoDetailFeature
import CoreGraphics
import Foundation
import SwiftUI

/// 一个窗口可替换的 adapter 与 port：内容、稍后再看写入与认证仓库、播放控制与播放器视图、弹幕呈现、Now Playing 与观看进度
/// 的连接，以及窗口打开、关闭时 adapter 自己的登记与清理。
///
/// `WindowComposition` 只经它拿到具体实现；生产实现只由 `live(process:)` 一处构造。
/// 本类型不持有状态；live 的具体对象（窗口 API、`AVPlayerEngine`、播放偏好、弹幕 renderer 与会话、
/// 内存压力监听）由这些闭包捕获，随 `WindowComposition` 存活，`close` 依次取消内存压力监听、
/// 停止播放偏好的持久化、注销会话并失效短链 session。
@MainActor
struct WindowAdapters {
    let feedRepository: any FeedRepository
    let videoRepository: any VideoRepository
    let relatedVideoRepository: any RelatedVideoRepository
    let trendingSearchRepository: any TrendingSearchRepository
    let searchSuggestionRepository: any SearchSuggestionRepository
    let uploaderProfileRepository: any UploaderProfileRepository
    let uploaderVideoRepository: any UploaderVideoRepository
    let commentRepository: any CommentRepository
    let historyRepository: any WatchHistoryRepository
    let watchLaterRepository: any WatchLaterRepository
    /// 稍后再看的加入与移除；生产实现走窗口 API 的账户写授权器，绑定窗口账户。
    let watchLaterWriteRepository: any WatchLaterWriteRepository
    let favoritesRepository: any FavoritesRepository
    /// 收藏到收藏夹与从收藏夹移除；生产实现走窗口 API 的账户写授权器，绑定窗口账户。
    let favoritesWriteRepository: any FavoritesWriteRepository
    /// 播放页的互动读取与点赞、投币、三连；生产实现走窗口 API 的账户读取与账户写授权器。
    let videoEngagementRepository: any VideoEngagementRepository
    /// 首页推荐的「不感兴趣」与撤销；生产实现走窗口 API 的账户写授权器，绑定窗口账户。
    let recommendationFeedbackRepository: any RecommendationFeedbackRepository
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentLinkRouter: CommentLinkRouter
    let authenticationService: any AuthenticationServicing
    let authenticationQRCodeProvider: any AuthenticationQRCodeProviding
    /// 窗口唯一的播放控制；视频模型、播放器视图、弹幕、Now Playing 与观看进度必须指向同一个播放器。
    let playback: any PlaybackControlling
    /// 播放附带的账户读取（字幕目录）发现的凭据失效；每构造一个视频模型调用一次，只有最新的流收到事件。
    let makePlaybackAuthenticationInvalidations: @MainActor () -> AsyncStream<Void>
    let danmakuPresentation: any DanmakuSessionControlling
    let danmakuPreferences: any DanmakuPreferencesStoring
    /// 播放器宿主视图；窗口组装时调用一次，结果随窗口存活。
    let makePlayerContent:
        @MainActor (
            VideoViewModel, DanmakuControlsViewModel, PlayerEngagementShortcuts, PlayerWindowContext
        ) -> AnyView
    /// 在当前视频的播放器里跳到某秒并播放；播放器 item 不属于该视频时不动作。
    let seekPlayback: @MainActor (_ bvid: String, _ seconds: Int) -> Void
    let nowPlayingConnection: SystemNowPlayingPlaybackConnection
    let makeWatchProgressConnection: @MainActor (VideoViewModel) -> WatchProgressWindowConnection
    /// 窗口出现时调用一次：登记窗口 API 的会话失效。
    let open: @MainActor () -> Void
    /// 窗口关闭的最后一步调用一次（只在 `open` 之后）：取消 adapter 自己的监听，注销会话，失效短链 session。
    let close: @MainActor () -> Void
    /// 主 API 的「已确认未登录」；由 `AccountSignedOutConfirmation.isConfirmed` 判定后传入。
    let synchronizeSignedOutConfirmation: @MainActor (Bool) -> Void
}

extension WindowAdapters {
    /// 生产窗口：保持游客、媒体与字幕正文请求不自动继承登录 Cookie。
    ///
    /// 只有 BiliAPI 私有标记的账户读取才经过 authorizer；公开 Browse、Search、评论、playurl 与 WBI 弹幕分段在明确
    /// 无本地凭据时仍请求同一个 endpoint。登出还会替换 API 的 ephemeral transport，使旧认证会话中的在途请求
    /// 失效。一个窗口只创建一个 `AVPlayerEngine`，原生字幕、弹幕、视频模型与 AppKit player host 共享它的播放
    /// identity 和时间线。
    static func live(process: ProcessComposition) -> WindowAdapters {
        let settings = process.settings
        let signedOutConfirmation = AccountSignedOutConfirmation()
        let api = LiveAPIClients.main(
            isConfirmedSignedOut: { signedOutConfirmation.isConfirmed }
        )
        let sessionRegistration = WindowSessionRegistration(
            coordinator: process.accountSession,
            invalidator: api
        )
        let authenticationService = BiliAuthenticationService(
            accountReadAllowedPaths: LiveAPIClients.accountSessionValidationAllowedPaths,
            additionalSessionInvalidators: [process.accountSession]
        )
        // 记录在途 seek 的子类：播放器浮层据此在 seek 未落地时转圈，见 `SeekTrackingPlayer`。
        let player = SeekTrackingPlayer()
        // 窗口播放器的音量、静音与倍速偏好（KVO 持久化）：与弹幕一样是本窗口的具名 live 对象，由 `close`
        // 显式停止，音量快捷键也经它调整。
        let playbackPreferences = PlaybackPreferencesController(player: player)
        let subtitleAuthenticationInvalidations = SubtitleAuthenticationInvalidationRelay()
        let hdrEnvironment = PlaybackHDREnvironment()
        let playerEngine = AVPlayerEngine(
            player: player,
            subtitleUseCase: SubtitleUseCase(
                repository: BiliSubtitleRepository(client: api),
                reportAuthenticationInvalidation: subtitleAuthenticationInvalidations.report
            ),
            loadPreferencesProvider: {
                PlaybackLoadPreferences(
                    sourcePreference: settings.playbackSourcePreference,
                    allowsHDRVideo: settings.hdrVideoEnabled && hdrEnvironment.allowsHDR
                )
            }
        )
        // 「播放结束后」偏好：设备级，动作菜单与播完的处理读写同一处。
        let endBehavior = PlaybackEndBehaviorStore()
        let danmaku = LiveDanmaku(
            repository: BiliDanmakuRepository(client: api),
            timeline: playerEngine
        )
        let contentRepository = BiliContentRepository(client: api)
        let commentAssetResolver = BiliCommentAssetResolver()
        let commentLinkRouting = CommentLinkRouting(
            linkResolver: BiliCommentLinkResolver(),
            shortLinkResolver: BiliShortLinkResolver()
        )
        return WindowAdapters(
            feedRepository: contentRepository,
            videoRepository: contentRepository,
            relatedVideoRepository: contentRepository,
            trendingSearchRepository: contentRepository,
            searchSuggestionRepository: contentRepository,
            uploaderProfileRepository: contentRepository,
            uploaderVideoRepository: contentRepository,
            commentRepository: BiliCommentRepository(client: api),
            historyRepository: BiliWatchHistoryRepository(client: api),
            watchLaterRepository: BiliWatchLaterRepository(client: api),
            watchLaterWriteRepository: BiliWatchLaterWriteRepository(client: api),
            favoritesRepository: BiliFavoritesRepository(client: api),
            favoritesWriteRepository: BiliFavoritesWriteRepository(client: api),
            videoEngagementRepository: BiliVideoEngagementRepository(client: api),
            recommendationFeedbackRepository: BiliRecommendationFeedbackRepository(client: api),
            commentAssetURLResolver: { reference, box in
                commentAssetResolver.imageURL(for: reference, fitting: box)
            },
            commentLinkRouter: commentLinkRouting.route(for:),
            authenticationService: authenticationService,
            authenticationQRCodeProvider: AuthenticationQRCodeProvider(
                service: authenticationService
            ),
            playback: playerEngine,
            makePlaybackAuthenticationInvalidations: subtitleAuthenticationInvalidations.makeStream,
            danmakuPresentation: danmaku.session,
            danmakuPreferences: UserDefaultsDanmakuPreferencesStore(),
            makePlayerContent: { videoModel, danmakuModel, engagementShortcuts, playerWindow in
                danmaku.renderer.coverImages = playerWindow.imagePipeline
                return AnyView(
                    PlayerHostView(
                        player: player,
                        danmakuRenderer: danmaku.renderer,
                        danmakuController: danmaku.controller,
                        videoModel: videoModel,
                        beginMomentaryPlaybackRate: { rate in
                            try? playerEngine.beginMomentaryPlaybackRate(Double(rate))
                        },
                        endMomentaryPlaybackRate: { sessionID in
                            playerEngine.endMomentaryPlaybackRate(sessionID: sessionID)
                        },
                        seekByTransportOffset: { offset in
                            playerEngine.seekByTransportOffset(offset)
                        },
                        adjustVolume: { offset in
                            playbackPreferences.adjustVolume(by: offset)
                        },
                        togglePlayback: {
                            playerEngine.togglePlayback()
                        },
                        toggleDanmaku: { [danmakuModel] in
                            danmakuModel.toggleEnabled()
                        },
                        toggleSubtitles: {
                            await playerEngine.toggleNativeSubtitles()
                        },
                        engagementShortcuts: engagementShortcuts,
                        openDanmakuLinkedVideo: playerWindow.openVideo,
                        actionMenu: .make(
                            videoModel: videoModel,
                            timeline: { playerEngine.currentTimelineSnapshot },
                            pausePlayback: { playerEngine.pause() },
                            endBehavior: endBehavior,
                            window: playerWindow
                        ),
                        playbackEnd: .make(
                            videoModel: videoModel,
                            observeTimeline: playerEngine.observeTimeline,
                            currentTimeline: { playerEngine.currentTimelineSnapshot },
                            store: endBehavior,
                            continuePlayback: playerWindow.continuePlayback
                        ),
                        timelineUpdates: {
                            playerEngine.timelineUpdates()
                        },
                        hdrEnvironment: hdrEnvironment
                    )
                )
            },
            seekPlayback: { bvid, seconds in
                guard seconds >= 0,
                    playerEngine.currentTimelineSnapshot.identity?.bvid == bvid,
                    playerEngine.requestSeek(to: .seconds(seconds))
                else { return }
                playerEngine.play()
            },
            nowPlayingConnection: .live(engine: playerEngine),
            makeWatchProgressConnection: { videoModel in
                .live(
                    repository: process.watchProgressRepository,
                    timeline: playerEngine,
                    videoModel: videoModel
                )
            },
            open: { sessionRegistration.open() },
            close: {
                danmaku.memoryPressure.cancel()
                playbackPreferences.invalidate()
                sessionRegistration.close()
                commentLinkRouting.shortLinkResolver.invalidate()
            },
            synchronizeSignedOutConfirmation: signedOutConfirmation.synchronize
        )
    }
}

/// 播放器在窗口层的依赖，构造窗口 adapter 时还不存在，由窗口组装播放器时交给 `makePlayerContent`。
///
/// 弹幕关联视频卡片的封面经窗口的图片管线加载，点击经窗口导航在应用内打开视频；动作菜单的「添加到稍后再看」经窗口的
/// 写入协调者，门槛（`canWriteAccount`）也由它判断；播完后的自动连播经 `continuePlayback` 走与侧栏选分 P、选集相同的
/// 导航意图，但保留侧栏上下文层。
struct PlayerWindowContext {
    let imagePipeline: NativeVideoImagePipeline
    let openVideo: @MainActor (_ bvid: String) -> Void
    let canWriteAccount: @MainActor () -> Bool
    /// 返回是否发出（`AccountWriteCoordinator.addToWatchLater`）。
    let addToWatchLater: @MainActor (_ bvid: String) -> Bool
    let continuePlayback: @MainActor (_ bvid: String, _ preferredCID: Int64?) -> Void
}

/// 一个窗口的弹幕实现：Core Animation renderer、呈现控制器、加载分段并转发时间线的会话，以及系统内存压力监听。
///
/// 内存压力时清空 renderer 的纹理缓存与在途准备；监听由窗口 adapter 的 `close` 先取消。
@MainActor
private struct LiveDanmaku {
    let renderer: CoreAnimationDanmakuRenderer
    let controller: DanmakuPresentationController
    let session: DanmakuSession
    let memoryPressure: SystemMemoryPressureObserver

    init(
        repository: any DanmakuSegmentRepository & DanmakuCommandRepository,
        timeline: AVPlayerEngine
    ) {
        // 弹幕 layer 挂在弹幕 overlay 的时钟层下，本地时间就是媒体时间；时间点 0 用时钟定义的哨兵。
        let renderer = CoreAnimationDanmakuRenderer(
            beginTimeAtMediaZero: DanmakuTimebaseClock.beginTimeAtMediaZero
        )
        let controller = DanmakuPresentationController(backend: renderer)
        self.renderer = renderer
        self.controller = controller
        // 主队列投递，处理在 MainActor 上清空 renderer 的纹理缓存与在途准备。
        memoryPressure = SystemMemoryPressureObserver(queue: .main) { [weak renderer] in
            MainActor.assumeIsolated {
                renderer?.handleMemoryPressure()
            }
        }
        session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            commandUseCase: DanmakuCommandUseCase(repository: repository),
            timeline: timeline,
            presentationSink: controller
        )
    }
}

private struct AuthenticationQRCodeProvider: AuthenticationQRCodeProviding {
    let service: BiliAuthenticationService

    func makeQRCodeImage(scale: Int) async throws -> CGImage? {
        try await service.makeQRCodeImage(scale: scale)
    }
}
