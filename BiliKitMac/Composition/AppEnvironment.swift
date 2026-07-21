import BiliApplication
import BiliAPI
import BiliAuth
import BiliAuthFeature
import BiliGuestFeature
import BiliHistoryFeature
import BiliNetworking
import BiliPlayback
import Foundation
import SwiftUI

@MainActor
struct AppEnvironment {
    private let playerEngine: AVPlayerEngine
    private let repository: any GuestContentRepository
    private let historyRepository: any WatchHistoryRepository
    private let authenticationService: any AuthenticationServicing

    init(
        repository: any GuestContentRepository,
        historyRepository: any WatchHistoryRepository,
        playerEngine: AVPlayerEngine,
        authenticationService: any AuthenticationServicing
    ) {
        self.repository = repository
        self.historyRepository = historyRepository
        self.playerEngine = playerEngine
        self.authenticationService = authenticationService
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

    func makePlayerView() -> AnyView {
        AnyView(PlayerHostView(player: playerEngine.player))
    }

    func makeAuthenticationViewModel() -> AuthenticationViewModel {
        AuthenticationViewModel(service: authenticationService)
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
        return AppEnvironment(
            repository: BiliGuestRepository(service: api),
            historyRepository: BiliWatchHistoryRepository(service: api),
            playerEngine: AVPlayerEngine(),
            authenticationService: BiliAuthenticationService(
                additionalSessionInvalidators: [api]
            )
        )
    }()
}
