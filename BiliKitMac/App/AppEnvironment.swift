import BiliModels
import BiliNetworking
import BiliPlayback

@MainActor
struct AppEnvironment {
    let httpClient: HTTPClient
    let playerEngine: AVPlayerEngine
    let makePlaybackRequest: @Sendable (PlaybackManifest) -> PlaybackRequest

    static let live = AppEnvironment(
        httpClient: HTTPClient(),
        playerEngine: AVPlayerEngine(),
        makePlaybackRequest: { PlaybackRequest(manifest: $0) }
    )
}
