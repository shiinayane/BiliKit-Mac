import BiliApplication
import BiliAPI
import BiliGuestFeature
import BiliPlayback
import SwiftUI

@MainActor
struct AppEnvironment {
    private let playerEngine: AVPlayerEngine
    private let repository: any GuestContentRepository

    init(
        repository: any GuestContentRepository,
        playerEngine: AVPlayerEngine
    ) {
        self.repository = repository
        self.playerEngine = playerEngine
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

    static let live: AppEnvironment = {
        let api = BiliAPIClient()
        return AppEnvironment(
            repository: BiliGuestRepository(service: api),
            playerEngine: AVPlayerEngine()
        )
    }()
}
