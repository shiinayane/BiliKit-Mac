import BiliAPI
import BiliPlayback

@MainActor
struct AppEnvironment {
    let api: any BiliAPIService
    let playerEngine: AVPlayerEngine
    let makePlaybackRequest: @Sendable (VideoPlayback) -> PlaybackRequest

    func makeGuestAppModel() -> GuestAppModel {
        GuestAppModel(
            api: api,
            playerEngine: playerEngine,
            makePlaybackRequest: makePlaybackRequest
        )
    }

    static let live = AppEnvironment(
        api: BiliAPIClient(),
        playerEngine: AVPlayerEngine(),
        makePlaybackRequest: {
            PlaybackRequest(
                manifest: $0.manifest,
                mediaHeaders: $0.mediaHeaders
            )
        }
    )
}
