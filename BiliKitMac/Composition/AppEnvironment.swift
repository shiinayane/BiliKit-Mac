import AVFoundation
import BiliAPI
import BiliApplication
import BiliAuth
import BiliAuthFeature
import BiliBrowseFeature
import BiliDanmaku
import BiliLibraryFeature
import BiliNetworking
import BiliPlayback
import CoreGraphics
import Foundation
import SwiftUI

@MainActor
/// App 的 Composition Root：创建具体 adapter，并把它们收窄为 Feature 所需的 port。
///
/// 这里刻意同时看见 API、认证、播放和弹幕实现。一个环境只创建一个 `AVPlayerEngine`，
/// 原生字幕、弹幕、视频模型与 AppKit player host 必须共享它的播放 identity 和时间线。
struct AppEnvironment {
    private let playerEngine: AVPlayerEngine
    let playbackPreferencesController: PlaybackPreferencesController
    private let guestContentRepository: any GuestContentRepository
    private let relatedVideoRepository: any RelatedVideoRepository
    private let historyRepository: any WatchHistoryRepository
    private let danmakuSession: DanmakuSession
    private let danmakuController: DanmakuPresentationController
    private let danmakuRenderer: CoreAnimationDanmakuRenderer
    private let authenticationService: any AuthenticationServicing
    private let authenticationQRCodeProvider: any AuthenticationQRCodeProviding

    init(
        guestContentRepository: any GuestContentRepository,
        relatedVideoRepository: any RelatedVideoRepository,
        historyRepository: any WatchHistoryRepository,
        danmakuRepository: any DanmakuSegmentRepository,
        playerEngine: AVPlayerEngine,
        playbackPreferencesController: PlaybackPreferencesController,
        authenticationService: any AuthenticationServicing,
        authenticationQRCodeProvider: any AuthenticationQRCodeProviding
    ) {
        precondition(
            playerEngine.nativeSubtitlesEnabled,
            "AVPlayerEngine must own native subtitle presentation"
        )
        self.guestContentRepository = guestContentRepository
        self.relatedVideoRepository = relatedVideoRepository
        self.historyRepository = historyRepository
        self.playerEngine = playerEngine
        self.playbackPreferencesController = playbackPreferencesController
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
    }

    var nativeSubtitlesEnabled: Bool {
        playerEngine.nativeSubtitlesEnabled
    }

    func makeBrowseViewModel() -> GuestBrowseViewModel {
        GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: guestContentRepository)
        )
    }

    func makeVideoViewModel() -> GuestVideoViewModel {
        GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: guestContentRepository),
            playback: playerEngine,
            relatedVideoUseCase: RelatedVideoUseCase(
                repository: relatedVideoRepository
            )
        )
    }

    func makeDanmakuViewModel() -> DanmakuControlsViewModel {
        DanmakuControlsViewModel(presentation: danmakuSession)
    }

    func makePlayerView() -> AnyView {
        AnyView(
            PlayerHostView(
                player: playerEngine.player,
                danmakuRenderer: danmakuRenderer,
                danmakuController: danmakuController,
                beginMomentaryPlaybackRate: { [playerEngine] rate in
                    try? playerEngine.beginMomentaryPlaybackRate(Double(rate))
                },
                endMomentaryPlaybackRate: { [playerEngine] sessionID in
                    playerEngine.endMomentaryPlaybackRate(sessionID: sessionID)
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

    /// 创建生产对象图，并保持游客、媒体与字幕正文请求不自动继承登录 Cookie。
    ///
    /// 只有显式声明为已认证的 API 请求才经过 authorizer；登出还会替换 API 的
    /// ephemeral transport，使旧认证会话中的在途请求失效。
    static func live() -> AppEnvironment {
        let requestAuthorizer = BiliCredentialRequestAuthorizer()
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
        let api = BiliAPIClient(
            requestAuthorizer: requestAuthorizer,
            transportFactory: transportFactory
        )
        let authenticationService = BiliAuthenticationService(
            additionalSessionInvalidators: [api]
        )
        let player = AVPlayer()
        let playbackPreferencesController = PlaybackPreferencesController(
            player: player
        )
        let subtitleRepository = BiliSubtitleRepository(client: api)
        let playerEngine = AVPlayerEngine(
            player: player,
            subtitleUseCase: SubtitleUseCase(repository: subtitleRepository)
        )
        let guestRepository = BiliGuestRepository(client: api)
        return AppEnvironment(
            guestContentRepository: guestRepository,
            relatedVideoRepository: guestRepository,
            historyRepository: BiliWatchHistoryRepository(client: api),
            danmakuRepository: BiliDanmakuRepository(client: api),
            playerEngine: playerEngine,
            playbackPreferencesController: playbackPreferencesController,
            authenticationService: authenticationService,
            authenticationQRCodeProvider: AuthenticationQRCodeProvider(
                service: authenticationService
            )
        )
    }

    private static let emptyDanmakuConfiguration = DanmakuLaneConfiguration(
        surfaceWidth: 0,
        surfaceHeight: 0,
        laneHeight: 36,
        minimumHorizontalGap: 12,
        maximumActiveCount:
            DanmakuLaneConfiguration.hardMaximumActiveCount,
        displayAreaFraction: 1
    )
}

private struct AuthenticationQRCodeProvider: AuthenticationQRCodeProviding {
    let service: BiliAuthenticationService

    func makeQRCodeImage(scale: Int) async throws -> CGImage? {
        try await service.makeQRCodeImage(scale: scale)
    }
}
