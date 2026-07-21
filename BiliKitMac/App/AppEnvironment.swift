import BiliModels
import BiliNetworking
import BiliPlayback

struct AppEnvironment: Sendable {
    let httpClient: HTTPClient
    let makePlaybackRequest: @Sendable (PlaybackManifest) -> PlaybackRequest

    static let live = AppEnvironment(
        httpClient: HTTPClient(),
        makePlaybackRequest: { PlaybackRequest(manifest: $0) }
    )
}

