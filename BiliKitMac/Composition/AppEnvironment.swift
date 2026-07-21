import BiliApplication
import BiliAPI
import BiliAuth
import BiliAuthFeature
import BiliGuestFeature
import BiliPlayback
import SwiftUI

@MainActor
struct AppEnvironment {
    private let playerEngine: AVPlayerEngine
    private let repository: any GuestContentRepository
    private let authenticationService: any AuthenticationServicing

    init(
        repository: any GuestContentRepository,
        playerEngine: AVPlayerEngine,
        authenticationService: any AuthenticationServicing
    ) {
        self.repository = repository
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

    static let live: AppEnvironment = {
        let api = BiliAPIClient()
        return AppEnvironment(
            repository: BiliGuestRepository(service: api),
            playerEngine: AVPlayerEngine(),
            authenticationService: BiliAuthenticationService()
        )
    }()
}
