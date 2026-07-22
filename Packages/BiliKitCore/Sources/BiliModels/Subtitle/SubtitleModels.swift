public enum SubtitleTrackKind: Sendable, Equatable {
    case standard
    case automatic
}

public struct SubtitleTrack: Sendable, Equatable, Identifiable {
    public let id: String
    public let languageCode: String
    public let displayName: String
    public let kind: SubtitleTrackKind

    public init(
        id: String,
        languageCode: String,
        displayName: String,
        kind: SubtitleTrackKind
    ) {
        self.id = id
        self.languageCode = languageCode
        self.displayName = displayName
        self.kind = kind
    }
}

public struct SubtitleCue: Sendable, Equatable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String

    public init(startSeconds: Double, endSeconds: Double, text: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }

    public func contains(positionSeconds: Double) -> Bool {
        startSeconds <= positionSeconds && positionSeconds < endSeconds
    }
}
