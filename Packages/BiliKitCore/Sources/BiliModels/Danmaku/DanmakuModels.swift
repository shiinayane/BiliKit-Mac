public enum DanmakuPresentationMode: Sendable, Hashable {
    case scrolling
    case top
    case bottom
}

public struct DanmakuEvent: Sendable, Hashable, Identifiable {
    public let id: String
    public let timeSeconds: Double
    public let mode: DanmakuPresentationMode
    public let text: String
    public let fontSize: Double
    public let colorRGB: UInt32
    public let weight: Int

    public init(
        id: String,
        timeSeconds: Double,
        mode: DanmakuPresentationMode,
        text: String,
        fontSize: Double,
        colorRGB: UInt32,
        weight: Int
    ) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.mode = mode
        self.text = text
        self.fontSize = fontSize
        self.colorRGB = colorRGB
        self.weight = weight
    }
}

extension DanmakuEvent: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "DanmakuEvent(redacted)" }
    public var debugDescription: String { description }
}

public struct DanmakuSegment: Sendable, Equatable {
    public let index: Int
    public let events: [DanmakuEvent]

    public init(index: Int, events: [DanmakuEvent]) {
        self.index = index
        self.events = events
    }
}
