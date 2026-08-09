import BiliModels

public struct PlaybackRequest: Sendable, Equatable {
    public let manifest: PlaybackManifest
    public let preferredVideoRepresentationID: Int?
    public let preferredAudioRepresentationIDs: [String: Int]
    public let mediaHeaders: [String: String]

    public init(
        manifest: PlaybackManifest,
        preferredVideoRepresentationID: Int? = nil,
        preferredAudioRepresentationIDs: [String: Int] = [:],
        mediaHeaders: [String: String] = [:]
    ) {
        self.manifest = manifest
        self.preferredVideoRepresentationID = preferredVideoRepresentationID
        self.preferredAudioRepresentationIDs = preferredAudioRepresentationIDs
        self.mediaHeaders = mediaHeaders
    }
}

/// 一条语义音轨及其在本次加载中选定的媒体 representation。
///
/// `track` 保留用户可选择的语义 identity；`representation` 只能是该轨内部的一个码率候选。
public struct SelectedPlaybackAudioTrack: Sendable, Equatable {
    public let track: PlaybackAudioTrack
    public let representation: MediaRepresentation

    public init(
        track: PlaybackAudioTrack,
        representation: MediaRepresentation
    ) {
        self.track = track
        self.representation = representation
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
