import BiliModels
import Foundation

public struct PlaybackRequest: Sendable, Equatable {
    public let manifest: PlaybackManifest
    public let preferredVideoRepresentationID: Int?
    public let preferredAudioRepresentationID: Int?

    public init(
        manifest: PlaybackManifest,
        preferredVideoRepresentationID: Int? = nil,
        preferredAudioRepresentationID: Int? = nil
    ) {
        self.manifest = manifest
        self.preferredVideoRepresentationID = preferredVideoRepresentationID
        self.preferredAudioRepresentationID = preferredAudioRepresentationID
    }
}

public enum PlayerState: Sendable, Equatable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case ended
}

public enum PlayerEvent: Sendable, Equatable {
    case stateChanged(PlayerState)
    case failed(message: String)
}

@MainActor
public protocol PlayerEngine: AnyObject {
    var events: AsyncStream<PlayerEvent> { get }

    func load(_ request: PlaybackRequest) async throws
    func play()
    func pause()
    func seek(to time: Duration) async throws
}

