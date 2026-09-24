import AVFoundation
import BiliAPI
import BiliApplication
import BiliAuth
import BiliAuthFeature
import BiliBrowseFeature
import BiliDanmaku
import BiliLibraryFeature
import BiliModels
import BiliNetworking
import BiliPlayback
import CoreGraphics
import Foundation
import SwiftUI

typealias CommentAssetURLResolver = @Sendable (CommentAssetReference) -> URL?
typealias CommentVideoLinkResolver = @Sendable (CommentLinkTarget) -> String?
typealias CommentLinkURLResolver = @Sendable (CommentLinkTarget) -> URL?

@MainActor
/// App 的 Composition Root：创建具体 adapter，并把它们收窄为 Feature 所需的 port。
///
/// 这里刻意同时看见 API、认证、播放和弹幕实现。一个环境只创建一个 `AVPlayerEngine`，
/// 原生字幕、弹幕、视频模型与 AppKit player host 必须共享它的播放 identity 和时间线。
struct AppEnvironment {
    private let playerEngine: AVPlayerEngine
    let playbackPreferencesController: PlaybackPreferencesController
    private let feedRepository: any FeedRepository
    private let videoRepository: any VideoRepository
    private let relatedVideoRepository: any RelatedVideoRepository
    private let uploaderSignatureRepository: any UploaderSignatureRepository
    private let commentRepository: any CommentRepository
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentVideoLinkResolver: CommentVideoLinkResolver
    let commentLinkURLResolver: CommentLinkURLResolver
    private let historyRepository: any WatchHistoryRepository
    private let watchProgressRepository: (any WatchProgressRepository)?
    private let danmakuSession: DanmakuSession
    private let danmakuController: DanmakuPresentationController
    private let danmakuRenderer: CoreAnimationDanmakuRenderer
    private let danmakuPreferencesStore: any DanmakuPreferencesStoring
    private let authenticationService: any AuthenticationServicing
    private let authenticationQRCodeProvider: any AuthenticationQRCodeProviding
    let open: @MainActor @Sendable () -> Void
    let close: @MainActor @Sendable () -> Void

    init(
        feedRepository: any FeedRepository,
        videoRepository: any VideoRepository,
        relatedVideoRepository: any RelatedVideoRepository,
        uploaderSignatureRepository: any UploaderSignatureRepository,
        commentRepository: any CommentRepository,
        commentAssetURLResolver: @escaping CommentAssetURLResolver,
        commentVideoLinkResolver: @escaping CommentVideoLinkResolver,
        commentLinkURLResolver: @escaping CommentLinkURLResolver,
        historyRepository: any WatchHistoryRepository,
        watchProgressRepository: (any WatchProgressRepository)?,
        danmakuRepository: any DanmakuSegmentRepository,
        playerEngine: AVPlayerEngine,
        playbackPreferencesController: PlaybackPreferencesController,
        danmakuPreferencesStore: any DanmakuPreferencesStoring,
        authenticationService: any AuthenticationServicing,
        authenticationQRCodeProvider: any AuthenticationQRCodeProviding,
        open: @escaping @MainActor @Sendable () -> Void,
        close: @escaping @MainActor @Sendable () -> Void
    ) {
        precondition(
            playerEngine.nativeSubtitlesEnabled,
            "AVPlayerEngine must own native subtitle presentation"
        )
        self.feedRepository = feedRepository
        self.videoRepository = videoRepository
        self.relatedVideoRepository = relatedVideoRepository
        self.uploaderSignatureRepository = uploaderSignatureRepository
        self.commentRepository = commentRepository
        self.commentAssetURLResolver = commentAssetURLResolver
        self.commentVideoLinkResolver = commentVideoLinkResolver
        self.commentLinkURLResolver = commentLinkURLResolver
        self.historyRepository = historyRepository
        self.watchProgressRepository = watchProgressRepository
        self.playerEngine = playerEngine
        self.playbackPreferencesController = playbackPreferencesController
        self.danmakuPreferencesStore = danmakuPreferencesStore
        let renderer = CoreAnimationDanmakuRenderer()
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: Self.emptyDanmakuConfiguration
        )
        self.danmakuRenderer = renderer
        self.danmakuController = controller
        self.danmakuSession = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: danmakuRepository),
            timeline: playerEngine,
            presentationSink: controller
        )
        self.authenticationService = authenticationService
        self.authenticationQRCodeProvider = authenticationQRCodeProvider
        self.open = open
        self.close = close
    }

    func makeSystemNowPlayingPlaybackConnection()
        -> SystemNowPlayingPlaybackConnection
    {
        .live(engine: playerEngine)
    }

    func makeBrowseViewModel() -> BrowseViewModel {
        BrowseViewModel(
            useCase: FeedUseCase(repository: feedRepository)
        )
    }

    func makeVideoViewModel() -> VideoViewModel {
        VideoViewModel(
            useCase: VideoUseCase(repository: videoRepository),
            playback: playerEngine,
            relatedVideoUseCase: RelatedVideoUseCase(
                repository: relatedVideoRepository
            ),
            uploaderSignatureUseCase: UploaderSignatureUseCase(
                repository: uploaderSignatureRepository
            )
        )
    }

    func makeCommentsViewModel() -> PlaybackCommentsViewModel {
        PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: commentRepository)
        )
    }

    func makeDanmakuViewModel() -> DanmakuControlsViewModel {
        let preferences = danmakuPreferencesStore.load()
        return DanmakuControlsViewModel(
            presentation: danmakuSession,
            initialSpeedLevel: preferences.speedLevel,
            initialOpacity: preferences.opacity,
            initialDisplayArea: preferences.displayArea,
            initialDensity: preferences.density,
            saveSpeedLevel: { [danmakuPreferencesStore] speedLevel in
                danmakuPreferencesStore.saveSpeedLevel(speedLevel)
            },
            saveOpacity: { [danmakuPreferencesStore] opacity in
                danmakuPreferencesStore.saveOpacity(opacity)
            },
            saveDisplayArea: { [danmakuPreferencesStore] displayArea in
                danmakuPreferencesStore.saveDisplayArea(displayArea)
            },
            saveDensity: { [danmakuPreferencesStore] density in
                danmakuPreferencesStore.saveDensity(density)
            }
        )
    }

    func makePlayerView(
        videoModel: VideoViewModel,
        danmakuModel: DanmakuControlsViewModel
    ) -> AnyView {
        AnyView(
            PlayerHostView(
                player: playerEngine.player,
                danmakuRenderer: danmakuRenderer,
                danmakuController: danmakuController,
                videoModel: videoModel,
                beginMomentaryPlaybackRate: { [playerEngine] rate in
                    try? playerEngine.beginMomentaryPlaybackRate(Double(rate))
                },
                endMomentaryPlaybackRate: { [playerEngine] sessionID in
                    playerEngine.endMomentaryPlaybackRate(sessionID: sessionID)
                },
                seekByTransportOffset: { [playerEngine] offset in
                    playerEngine.seekByTransportOffset(offset)
                },
                adjustVolume: { [playbackPreferencesController] offset in
                    playbackPreferencesController.adjustVolume(by: offset)
                },
                togglePlayback: { [playerEngine] in
                    playerEngine.togglePlayback()
                },
                toggleDanmaku: { [danmakuModel] in
                    danmakuModel.toggleEnabled()
                },
                toggleSubtitles: { [playerEngine] in
                    await playerEngine.toggleNativeSubtitles()
                },
                timelineUpdates: { [playerEngine] in
                    playerEngine.timelineUpdates()
                }
            )
        )
    }

    func makeAuthenticationViewModel() -> AuthenticationViewModel {
        AuthenticationViewModel(
            service: authenticationService,
            qrCodeProvider: authenticationQRCodeProvider
        )
    }

    func makeWatchHistoryViewModel() -> WatchHistoryViewModel {
        WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: historyRepository)
        )
    }

    func makeWatchProgressConnection(
        videoModel: VideoViewModel
    ) -> WatchProgressWindowConnection? {
        watchProgressRepository.map {
            .live(repository: $0, timeline: playerEngine, videoModel: videoModel)
        }
    }

    static func liveAppSettingsModel(
        accountSessionCoordinator: AccountSessionCoordinator
    ) -> AppSettingsModel {
        let api = makeLiveAPIClient(
            accountReadAllowedPaths: cdnBenchmarkAccountReadAllowedPaths
        )
        _ = accountSessionCoordinator.registerSessionInvalidator(api)
        let discoverer = CDNBenchmarkSampleDiscoverer(client: api)
        let benchmark = BilivideoRouteBenchmark()
        return AppSettingsModel(
            store: UserDefaultsPlaybackSourcePreferenceStore(),
            benchmarkAccess: .resolving,
            discover: { targetCount in
                do {
                    return try await discoverer.discover(targetCount: targetCount).map {
                        PlaybackRouteBenchmarkSample(
                            template: $0.videoRepresentation,
                            headers: $0.mediaHeaders
                        )
                    }
                } catch {
                    throw PlaybackRouteBenchmarkOperationError.mappingDiscoveryError(error)
                }
            },
            resetDiscovery: { await discoverer.resetSeenSamples() },
            run: { samples, progress in
                try await benchmark.benchmarkUnifiedPool(
                    samples: samples,
                    progress: progress
                )
            }
        )
    }

    /// 在 App Composition 初始化期间安装唯一进程 writer；窗口 View 构造只读取结果。
    static func prepareLiveWatchProgressRepository(
        accountSessionCoordinator: AccountSessionCoordinator
    ) {
        _ = accountSessionCoordinator.resolveWatchProgressRepository {
            let writeAPI = makeLiveAPIClient(
                accountReadAllowedPaths: watchProgressAccountReadAllowedPaths,
                historyWriteEnabled: true
            )
            return (
                BiliWatchProgressRepository(client: writeAPI),
                writeAPI
            )
        }
    }

    /// 创建生产对象图，并保持游客、媒体与字幕正文请求不自动继承登录 Cookie。
    ///
    /// 只有 BiliAPI 私有标记的账户读取才经过 authorizer；公开 Browse、Search、评论、
    /// playurl 与 WBI 弹幕分段在明确无本地凭据时仍请求同一个 endpoint。登出还会替换 API 的
    /// ephemeral transport，使旧认证会话中的在途请求失效。
    static func live(
        accountSessionCoordinator: AccountSessionCoordinator,
        appSettingsModel: AppSettingsModel? = nil
    ) -> AppEnvironment {
        let api = makeLiveAPIClient(
            accountReadAllowedPaths: mainAccountReadAllowedPaths
        )
        let sessionRegistration = AppEnvironmentSessionRegistration(
            coordinator: accountSessionCoordinator,
            invalidator: api
        )
        let authenticationService = BiliAuthenticationService(
            accountReadAllowedPaths: accountSessionValidationAllowedPaths,
            additionalSessionInvalidators: [accountSessionCoordinator]
        )
        let player = AVPlayer()
        let playbackPreferencesController = PlaybackPreferencesController(
            player: player
        )
        let subtitleRepository = BiliSubtitleRepository(client: api)
        let playerEngine = AVPlayerEngine(
            player: player,
            subtitleUseCase: SubtitleUseCase(repository: subtitleRepository),
            sourcePreferenceProvider: {
                appSettingsModel?.playbackSourcePreference ?? .serverDefault
            },
            loudnessNormalizationEnabledProvider: {
                if #available(macOS 26.0, *) {
                    appSettingsModel?.loudnessNormalizationEnabled ?? false
                } else {
                    false
                }
            }
        )
        let contentRepository = BiliContentRepository(client: api)
        let commentAssetResolver = BiliCommentAssetResolver()
        let commentLinkResolver = BiliCommentLinkResolver()
        return AppEnvironment(
            feedRepository: contentRepository,
            videoRepository: contentRepository,
            relatedVideoRepository: contentRepository,
            uploaderSignatureRepository: contentRepository,
            commentRepository: BiliCommentRepository(client: api),
            commentAssetURLResolver: { reference in
                commentAssetResolver.imageURL(for: reference)
            },
            commentVideoLinkResolver: { target in
                guard case .video(let bvid) = target else { return nil }
                return bvid
            },
            commentLinkURLResolver: { target in
                commentLinkResolver.externalURL(for: target)
            },
            historyRepository: BiliWatchHistoryRepository(client: api),
            watchProgressRepository: accountSessionCoordinator.watchProgressRepository,
            danmakuRepository: BiliDanmakuRepository(client: api),
            playerEngine: playerEngine,
            playbackPreferencesController: playbackPreferencesController,
            danmakuPreferencesStore: UserDefaultsDanmakuPreferencesStore(),
            authenticationService: authenticationService,
            authenticationQRCodeProvider: AuthenticationQRCodeProvider(
                service: authenticationService
            ),
            open: { sessionRegistration.open() },
            close: { sessionRegistration.close() }
        )
    }

    private static let emptyDanmakuConfiguration = DanmakuLaneConfiguration.production(
        surfaceWidth: 0,
        surfaceHeight: 0
    )

    static let accountSessionValidationAllowedPaths: Set<String> = [
        "/x/web-interface/nav"
    ]

    static let mainAccountReadAllowedPaths: Set<String> = [
        "/x/player/pagelist",
        "/x/player/playurl",
        "/x/player/wbi/v2",
        "/x/v2/dm/wbi/web/seg.so",
        "/x/v2/reply/reply",
        "/x/v2/reply/wbi/main",
        "/x/web-interface/archive/related",
        "/x/web-interface/card",
        "/x/web-interface/history/cursor",
        "/x/web-interface/popular",
        "/x/web-interface/view",
        "/x/web-interface/wbi/index/top/feed/rcmd",
        "/x/web-interface/wbi/search/type"
    ]

    static let cdnBenchmarkAccountReadAllowedPaths: Set<String> = [
        "/x/player/playurl"
    ]

    static let watchProgressAccountReadAllowedPaths: Set<String>? = nil

    private static func makeLiveAPIClient(
        accountReadAllowedPaths: Set<String>?,
        historyWriteEnabled: Bool = false
    ) -> BiliAPIClient {
        let requestAuthorizer = accountReadAllowedPaths.map {
            BiliCredentialRequestAuthorizer(allowedPaths: $0)
        }
        let historyWriteAuthorizer: (any HTTPRequestAuthorizing)? =
            historyWriteEnabled ? BiliPlaybackHeartbeatRequestAuthorizer() : nil
        let transportFactory: @Sendable () -> any HTTPTransport = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            return URLSessionTransport(
                configuration: configuration,
                redirectPolicy: .reject
            )
        }
        return BiliAPIClient(
            requestAuthorizer: requestAuthorizer,
            historyWriteAuthorizer: historyWriteAuthorizer,
            transportFactory: transportFactory
        )
    }
}

private struct AuthenticationQRCodeProvider: AuthenticationQRCodeProviding {
    let service: BiliAuthenticationService

    func makeQRCodeImage(scale: Int) async throws -> CGImage? {
        try await service.makeQRCodeImage(scale: scale)
    }
}
