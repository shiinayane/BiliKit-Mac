import BiliApplication
import BiliAPI
import BiliAuth
import BiliAuthFeature
import BiliBrowseFeature
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
    private let authenticationService: any AuthenticationServicing
    private let authenticationQRCodeProvider: any AuthenticationQRCodeProviding

    init(
        repository: any GuestContentRepository,
        historyRepository: any WatchHistoryRepository,
        subtitleRepository: any SubtitleRepository,
        playerEngine: AVPlayerEngine,
        authenticationService: any AuthenticationServicing,
        authenticationQRCodeProvider: any AuthenticationQRCodeProviding
    ) {
        self.repository = repository
        self.historyRepository = historyRepository
        self.subtitleRepository = subtitleRepository
        self.playerEngine = playerEngine
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

    func makePlayerView(subtitleModel: SubtitleViewModel) -> AnyView {
        AnyView(
            PlayerHostView(player: playerEngine.player) {
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

    static let live: AppEnvironment = {
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
            playerEngine: AVPlayerEngine(),
            authenticationService: authenticationService,
            authenticationQRCodeProvider: AuthenticationQRCodeProvider(
                service: authenticationService
            )
        )
    }()
}

private struct AuthenticationQRCodeProvider: AuthenticationQRCodeProviding {
    let service: BiliAuthenticationService

    func makeQRCodeImage(scale: Int) async throws -> CGImage? {
        try await service.makeQRCodeImage(scale: scale)
    }
}
