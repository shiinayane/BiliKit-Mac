import BiliApplication
import BiliAPI
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
struct AppEnvironment {
    private let playerEngine: AVPlayerEngine
    private let repository: any GuestContentRepository
    private let historyRepository: any WatchHistoryRepository
    private let subtitleRepository: any SubtitleRepository
    private let danmakuSession: DanmakuSession
    private let danmakuController: DanmakuPresentationController
    private let danmakuRenderer: CoreAnimationDanmakuRenderer
    private let authenticationService: any AuthenticationServicing
    private let authenticationQRCodeProvider: any AuthenticationQRCodeProviding

    init(
        repository: any GuestContentRepository,
        historyRepository: any WatchHistoryRepository,
        subtitleRepository: any SubtitleRepository,
        danmakuRepository: any DanmakuSegmentRepository,
        playerEngine: AVPlayerEngine,
        authenticationService: any AuthenticationServicing,
        authenticationQRCodeProvider: any AuthenticationQRCodeProviding
    ) {
        self.repository = repository
        self.historyRepository = historyRepository
        self.subtitleRepository = subtitleRepository
        self.playerEngine = playerEngine
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

    func makeFeedViewModel() -> GuestFeedViewModel {
        GuestFeedViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )
    }

    func makeVideoViewModel() -> GuestVideoViewModel {
        GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: playerEngine
        )
    }

    func makeSubtitleViewModel() -> SubtitleViewModel {
        SubtitleViewModel(
            useCase: SubtitleUseCase(repository: subtitleRepository),
            timeline: playerEngine
        )
    }

    func makeDanmakuViewModel() -> DanmakuControlsViewModel {
        DanmakuControlsViewModel(presentation: danmakuSession)
    }

    func makePlayerView(subtitleModel: SubtitleViewModel) -> AnyView {
        AnyView(
            PlayerHostView(
                player: playerEngine.player,
                danmakuRenderer: danmakuRenderer,
                danmakuController: danmakuController
            ) {
                SubtitleOverlayView(model: subtitleModel)
            }
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
        return AppEnvironment(
            repository: BiliGuestRepository(service: api),
            historyRepository: BiliWatchHistoryRepository(service: api),
            subtitleRepository: BiliSubtitleRepository(client: api),
            danmakuRepository: BiliDanmakuRepository(client: api),
            playerEngine: AVPlayerEngine(),
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
