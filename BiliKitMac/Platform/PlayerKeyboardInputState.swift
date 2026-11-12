import Foundation

/// 播放器方向键：左右短按跳转 5 秒、长按临时倍速（左 0.5 倍、右 2 倍），上下按 5% 调音量。
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

/// 播放器的离散快捷键：播放／暂停、弹幕、字幕、全屏、投币与收藏。
///
/// 按键映射在 `PlayerKeyboardShortcutController`。点赞（Q）有短按与长按，单独跟踪，不在这里。
enum PlayerKeyboardShortcut: Equatable, Hashable, Sendable {
    case playback
    case danmaku
    case subtitles
    case fullScreen
    case coin
    case favorite
    /// 回车：呼出发送弹幕的输入胶囊。
    case danmakuComposer
}

/// 播放器键盘输入的纯状态机：把按下、抬起与长按到时转成动作，由 `PlayerKeyboardShortcutController`
/// 执行。
///
/// 长按计时 Task 由 controller 持有。左右键同时只跟踪一个按压，`pressID` 在每次新按压时生成，
/// 长按到时（`deadlineReached`）与结束都按它比对，不符的迟到事件丢弃。点赞键（Q）另有一个按压：
/// 松开时还没到 `longPressDelay` 是点赞或取消（在 keyUp 执行，按下时还不知道是不是长按）；按住到
/// `longPressDelay` 显示三连进度，到 `tripleHoldDuration` 执行三连；进度出现后、三连之前松开则什么都不做。`cancel()`（失焦、禁用、
/// 输入框取得焦点）时仍按住的键记入 suppressed 集合：其后的系统重复事件被忽略，
/// 直到松开或一次新的非重复按下，避免取消后同一次按住又触发。
struct PlayerKeyboardInputState: Equatable, Sendable {
    /// 按住超过这么久才算长按并开始临时倍速，之前松开算短按跳转。
    ///
    /// 调大让临时倍速更迟生效，调小容易把稍慢的点按误判为长按。
    static let longPressDelay: TimeInterval = 0.35
    /// 按住音量键时系统重复事件的最短生效间隔，每秒最多约 12 步。
    ///
    /// 调小音量变化更快、更难停在想要的值，调大则变化更慢。
    static let minimumVolumeRepeatInterval: TimeInterval = 0.08
    /// 按住点赞键多久执行三连（从按下算起）；三连会扣硬币且不可撤回，按住满这么久本身就是确认。
    ///
    /// 与网页长按三连的手感相近；调短容易误触扣币，调长要按太久。
    static let tripleHoldDuration: TimeInterval = 1.0

    /// 状态机交给 controller 执行的动作；长按相关动作都带 `pressID`，
    /// 执行方据此忽略过期的计时与结束。
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
        case toggleFullScreen
        case openCoinPanel
        case chooseFavoriteFolders
        case openDanmakuComposer
        /// 点赞键按下：controller 先在 `longPressDelay` 后调用 `likeProgressDeadlineReached`，再在
        /// `tripleHoldDuration` 时调用 `likeTripleDeadlineReached`。
        case scheduleLikeHold(pressID: UUID)
        case cancelLikeHold(pressID: UUID)
        case beginTripleProgress(pressID: UUID)
        case endTripleProgress(pressID: UUID)
        case toggleLike
        case triple
    }

    /// 当前跟踪的点赞键按压：`pressID` 与阶段（短按窗口内、已显示三连进度、已执行三连）。
    private struct LikePress: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case waitingForProgress
            case showingProgress
            case tripled
        }

        let pressID: UUID
        var phase: Phase
    }

    /// 当前跟踪的左右键按压：方向、`pressID` 与阶段（等待长按到时，或已进入临时倍速）。
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
    private var likePress: LikePress?
    private var suppressesLikeKey = false

    mutating func keyDown(
        _ direction: PlayerKeyboardDirection,
        isRepeat: Bool,
        timestamp: TimeInterval
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
        let pressID = UUID()
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
                .seekBy(seconds: offset)
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
        case .fullScreen: [.toggleFullScreen]
        case .coin: [.openCoinPanel]
        case .favorite: [.chooseFavoriteFolders]
        case .danmakuComposer: [.openDanmakuComposer]
        }
    }

    mutating func likeKeyDown(isRepeat: Bool) -> [Action] {
        if suppressesLikeKey {
            guard !isRepeat else { return [] }
            suppressesLikeKey = false
        }
        guard !isRepeat, likePress == nil else { return [] }
        let pressID = UUID()
        likePress = LikePress(pressID: pressID, phase: .waitingForProgress)
        return [.scheduleLikeHold(pressID: pressID)]
    }

    mutating func likeKeyUp() -> [Action] {
        suppressesLikeKey = false
        guard let likePress else { return [] }
        self.likePress = nil
        switch likePress.phase {
        case .waitingForProgress:
            return [.cancelLikeHold(pressID: likePress.pressID), .toggleLike]
        case .showingProgress:
            return [
                .cancelLikeHold(pressID: likePress.pressID),
                .endTripleProgress(pressID: likePress.pressID)
            ]
        case .tripled:
            return []
        }
    }

    mutating func likeProgressDeadlineReached(pressID: UUID) -> [Action] {
        guard var likePress, likePress.pressID == pressID,
            likePress.phase == .waitingForProgress
        else { return [] }
        likePress.phase = .showingProgress
        self.likePress = likePress
        return [.beginTripleProgress(pressID: pressID)]
    }

    mutating func likeTripleDeadlineReached(pressID: UUID) -> [Action] {
        guard var likePress, likePress.pressID == pressID,
            likePress.phase == .showingProgress
        else { return [] }
        likePress.phase = .tripled
        self.likePress = likePress
        return [.endTripleProgress(pressID: pressID), .triple]
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
        return cancelHorizontalPress(suppressHeldKey: true) + cancelLikePress()
    }

    /// 取消仍在跟踪的点赞键按压：不点赞、不三连，收起三连进度；仍按住的键在松开前不再触发。
    private mutating func cancelLikePress() -> [Action] {
        guard let likePress else { return [] }
        self.likePress = nil
        suppressesLikeKey = true
        switch likePress.phase {
        case .waitingForProgress:
            return [.cancelLikeHold(pressID: likePress.pressID)]
        case .showingProgress:
            return [
                .cancelLikeHold(pressID: likePress.pressID),
                .endTripleProgress(pressID: likePress.pressID)
            ]
        case .tripled:
            return []
        }
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

/// 播放器是否接管一个按键事件的判定。
///
/// 快捷键启用、没有 ⌘⌃⌥⇧ 修饰键、事件来自锚点所在窗口，且焦点不在拿走按键的响应者（可编辑文本）上时
/// 才接管。其他窗口（含评论图片预览的子窗口面板）里的事件一律放行。
enum PlayerKeyboardEventScope {
    static func captures(
        isEnabled: Bool,
        hasDisallowedModifier: Bool,
        eventMatchesCaptureWindow: Bool,
        focusedResponderOwnsKeys: Bool
    ) -> Bool {
        isEnabled
            && !hasDisallowedModifier
            && eventMatchesCaptureWindow
            && !focusedResponderOwnsKeys
    }
}
