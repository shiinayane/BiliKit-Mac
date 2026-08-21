import Foundation

enum PlayerKeyboardDirection: Equatable, Hashable, Sendable {
    case left
    case right
    case up
    case down

    var momentaryRate: PlayerMomentaryRate? {
        switch self {
        case .left: .slow
        case .right: .fast
        case .up, .down: nil
        }
    }

    var seekOffsetSeconds: Double? {
        switch self {
        case .left: -5
        case .right: 5
        case .up, .down: nil
        }
    }

    var volumeOffset: Float? {
        switch self {
        case .up: 0.05
        case .down: -0.05
        case .left, .right: nil
        }
    }
}

enum PlayerKeyboardShortcut: Equatable, Hashable, Sendable {
    case playback
    case danmaku
    case subtitles
}

struct PlayerKeyboardInputState: Equatable, Sendable {
    static let longPressDelay: TimeInterval = 0.35
    static let minimumVolumeRepeatInterval: TimeInterval = 0.08

    enum Action: Equatable, Sendable {
        case scheduleLongPress(pressID: UUID)
        case cancelLongPress(pressID: UUID)
        case beginMomentaryRate(rate: PlayerMomentaryRate, pressID: UUID)
        case endMomentaryRate(pressID: UUID)
        case seekBy(seconds: Double)
        case adjustVolume(by: Float)
        case togglePlayback
        case toggleDanmaku
        case toggleSubtitles
    }

    private struct HorizontalPress: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case waitingForDeadline
            case longActivated
        }

        let direction: PlayerKeyboardDirection
        let pressID: UUID
        var phase: Phase
    }

    private var horizontalPress: HorizontalPress?
    private var suppressedHorizontalKeys: Set<PlayerKeyboardDirection> = []
    private var heldVolumeKeys: Set<PlayerKeyboardDirection> = []
    private var suppressedVolumeKeys: Set<PlayerKeyboardDirection> = []
    private var lastVolumeStepTime: [PlayerKeyboardDirection: TimeInterval] = [:]
    private var heldShortcuts: Set<PlayerKeyboardShortcut> = []
    private var suppressedShortcuts: Set<PlayerKeyboardShortcut> = []

    mutating func keyDown(
        _ direction: PlayerKeyboardDirection,
        isRepeat: Bool,
        timestamp: TimeInterval,
        makePressID: () -> UUID = UUID.init
    ) -> [Action] {
        if let volumeOffset = direction.volumeOffset {
            return volumeKeyDown(
                direction,
                offset: volumeOffset,
                isRepeat: isRepeat,
                timestamp: timestamp
            )
        }

        if suppressedHorizontalKeys.contains(direction) {
            guard !isRepeat else { return [] }
            suppressedHorizontalKeys.remove(direction)
        }
        if horizontalPress?.direction == direction {
            return []
        }
        guard !isRepeat else { return [] }

        var actions = cancelHorizontalPress(suppressHeldKey: true)
        let pressID = makePressID()
        horizontalPress = HorizontalPress(
            direction: direction,
            pressID: pressID,
            phase: .waitingForDeadline
        )
        actions.append(.scheduleLongPress(pressID: pressID))
        return actions
    }

    mutating func keyUp(_ direction: PlayerKeyboardDirection) -> [Action] {
        if direction.volumeOffset != nil {
            heldVolumeKeys.remove(direction)
            suppressedVolumeKeys.remove(direction)
            lastVolumeStepTime[direction] = nil
            return []
        }
        if suppressedHorizontalKeys.remove(direction) != nil {
            return []
        }
        guard let horizontalPress,
            horizontalPress.direction == direction
        else { return [] }
        self.horizontalPress = nil
        switch horizontalPress.phase {
        case .waitingForDeadline:
            guard let offset = direction.seekOffsetSeconds else { return [] }
            return [
                .cancelLongPress(pressID: horizontalPress.pressID),
                .seekBy(seconds: offset),
            ]
        case .longActivated:
            return [.endMomentaryRate(pressID: horizontalPress.pressID)]
        }
    }

    mutating func deadlineReached(pressID: UUID) -> [Action] {
        guard var horizontalPress,
            horizontalPress.pressID == pressID,
            horizontalPress.phase == .waitingForDeadline,
            let rate = horizontalPress.direction.momentaryRate
        else { return [] }
        horizontalPress.phase = .longActivated
        self.horizontalPress = horizontalPress
        return [.beginMomentaryRate(rate: rate, pressID: pressID)]
    }

    mutating func shortcutKeyDown(
        _ shortcut: PlayerKeyboardShortcut,
        isRepeat: Bool
    ) -> [Action] {
        if suppressedShortcuts.contains(shortcut) {
            guard !isRepeat else { return [] }
            suppressedShortcuts.remove(shortcut)
        }
        guard !isRepeat, heldShortcuts.insert(shortcut).inserted else {
            return []
        }
        return switch shortcut {
        case .playback: [.togglePlayback]
        case .danmaku: [.toggleDanmaku]
        case .subtitles: [.toggleSubtitles]
        }
    }

    mutating func shortcutKeyUp(_ shortcut: PlayerKeyboardShortcut) -> [Action] {
        heldShortcuts.remove(shortcut)
        suppressedShortcuts.remove(shortcut)
        return []
    }

    mutating func cancel() -> [Action] {
        suppressedVolumeKeys.formUnion(heldVolumeKeys)
        heldVolumeKeys.removeAll(keepingCapacity: true)
        lastVolumeStepTime.removeAll(keepingCapacity: true)
        suppressedShortcuts.formUnion(heldShortcuts)
        heldShortcuts.removeAll(keepingCapacity: true)
        return cancelHorizontalPress(suppressHeldKey: true)
    }

    private mutating func volumeKeyDown(
        _ direction: PlayerKeyboardDirection,
        offset: Float,
        isRepeat: Bool,
        timestamp: TimeInterval
    ) -> [Action] {
        if suppressedVolumeKeys.contains(direction) {
            guard !isRepeat else { return [] }
            suppressedVolumeKeys.remove(direction)
        }
        heldVolumeKeys.insert(direction)
        if isRepeat,
            let previous = lastVolumeStepTime[direction],
            timestamp - previous < Self.minimumVolumeRepeatInterval
        {
            return []
        }
        lastVolumeStepTime[direction] = timestamp
        return [.adjustVolume(by: offset)]
    }

    private mutating func cancelHorizontalPress(
        suppressHeldKey: Bool
    ) -> [Action] {
        guard let horizontalPress else { return [] }
        self.horizontalPress = nil
        if suppressHeldKey {
            suppressedHorizontalKeys.insert(horizontalPress.direction)
        }
        switch horizontalPress.phase {
        case .waitingForDeadline:
            return [.cancelLongPress(pressID: horizontalPress.pressID)]
        case .longActivated:
            return [.endMomentaryRate(pressID: horizontalPress.pressID)]
        }
    }
}

enum PlayerKeyboardEventScope {
    static func captures(
        isEnabled: Bool,
        isSupportedKey: Bool,
        hasDisallowedModifier: Bool,
        eventMatchesCaptureWindow: Bool,
        isEditableResponder: Bool
    ) -> Bool {
        isEnabled
            && isSupportedKey
            && !hasDisallowedModifier
            && eventMatchesCaptureWindow
            && !isEditableResponder
    }
}
