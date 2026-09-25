import AVKit
import BiliPlayback

/// 打开时独占方向键等按键的浮层；播放器快捷键不会越过它。
@MainActor
protocol PlayerKeyboardFocusOwner: NSView {}

/// 播放器键盘快捷键：本地 key monitor、长按临时倍速、离散快捷键与焦点让渡规则。
///
/// 以 content overlay 中的捕获层为锚点取窗口与所属 `AVPlayerView`，因此 detached 全屏窗口里同样生效。
@MainActor
final class PlayerKeyboardShortcutController {
    private enum KeyboardKey: Sendable {
        case direction(PlayerKeyboardDirection)
        case shortcut(PlayerKeyboardShortcut)
    }

    private struct KeyboardEventSnapshot: Sendable {
        let type: NSEvent.EventType
        let key: KeyboardKey
        let hasDisallowedModifier: Bool
        let isRepeat: Bool
        let timestamp: TimeInterval
        let windowNumber: Int
    }

    weak var anchorView: NSView?
    weak var feedbackPresenter: PlayerOverlayModel?
    private var keyboardMonitor: Any?
    private var keyboardInputEnabled = true
    private var keyboardState = PlayerKeyboardInputState()
    private var keyboardLongPressTask: Task<Void, Never>?
    private var keyboardLongPressID: UUID?
    private var subtitleToggleTask: Task<Void, Never>?
    var onKeyboardMomentaryRateBegan: (PlayerMomentaryRate, UUID) -> Void = {
        _,
        _ in
    }
    var onKeyboardMomentaryRateEnded: (UUID) -> Void = { _ in }
    var onRelativeSeek: (Double) -> Bool = { _ in false }
    var onVolumeStep: (Float) -> Float? = { _ in nil }
    var onTogglePlayback: () -> Bool? = { nil }
    var onToggleDanmaku: () -> Bool? = { nil }
    var onToggleSubtitles: () async -> NativeSubtitleToggleResult = {
        .unavailable
    }

    func setKeyboardInputEnabled(_ enabled: Bool) {
        guard keyboardInputEnabled != enabled else { return }
        keyboardInputEnabled = enabled
        if !enabled {
            cancelInputSession()
        }
    }

    func cancelInputSession() {
        applyKeyboardActions(keyboardState.cancel())
        keyboardLongPressTask?.cancel()
        keyboardLongPressTask = nil
        keyboardLongPressID = nil
        subtitleToggleTask?.cancel()
        subtitleToggleTask = nil
        feedbackPresenter?.clearFeedback()
    }

    func startMonitoring() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .leftMouseDown]
        ) { [weak self] event in
            if event.type == .leftMouseDown {
                DispatchQueue.main.async { @MainActor [weak self] in
                    self?.cancelIfEditableResponder()
                }
                return event
            }
            guard let snapshot = Self.keyboardSnapshot(from: event) else {
                DispatchQueue.main.async { @MainActor [weak self] in
                    self?.cancelIfEditableResponder()
                }
                return event
            }
            let consumed = MainActor.assumeIsolated {
                self?.handleKeyboardEvent(snapshot) == true
            }
            return consumed ? nil : event
        }
    }

    func stopMonitoring() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }

    private func handleKeyboardEvent(_ event: KeyboardEventSnapshot) -> Bool {
        guard let captureWindow = anchorView?.window else { return false }
        let responderOwnsKeys = Self.focusedResponderOwnsKeys(
            captureWindow.firstResponder,
            playerView: enclosingPlayerView
        )
        guard
            PlayerKeyboardEventScope.captures(
                isEnabled: keyboardInputEnabled,
                hasDisallowedModifier: event.hasDisallowedModifier,
                eventMatchesCaptureWindow:
                    event.windowNumber == captureWindow.windowNumber,
                focusedResponderOwnsKeys: responderOwnsKeys
            )
        else {
            if !keyboardInputEnabled
                || event.hasDisallowedModifier
                || responderOwnsKeys
            {
                cancelInputSession()
            }
            return false
        }

        let actions: [PlayerKeyboardInputState.Action]
        switch (event.type, event.key) {
        case (.keyDown, .direction(let direction)):
            actions = keyboardState.keyDown(
                direction,
                isRepeat: event.isRepeat,
                timestamp: event.timestamp
            )
        case (.keyUp, .direction(let direction)):
            actions = keyboardState.keyUp(direction)
        case (.keyDown, .shortcut(let shortcut)):
            actions = keyboardState.shortcutKeyDown(
                shortcut,
                isRepeat: event.isRepeat
            )
        case (.keyUp, .shortcut(let shortcut)):
            actions = keyboardState.shortcutKeyUp(shortcut)
        default:
            return false
        }
        applyKeyboardActions(actions)
        return true
    }

    private func applyKeyboardActions(
        _ actions: [PlayerKeyboardInputState.Action]
    ) {
        for action in actions {
            switch action {
            case .scheduleLongPress(let pressID):
                keyboardLongPressTask?.cancel()
                keyboardLongPressID = pressID
                keyboardLongPressTask = Task { [weak self] in
                    do {
                        try await Task.sleep(
                            for: .seconds(
                                PlayerKeyboardInputState.longPressDelay
                            )
                        )
                    } catch {
                        return
                    }
                    guard let self, self.keyboardLongPressID == pressID else {
                        return
                    }
                    self.keyboardLongPressTask = nil
                    self.keyboardLongPressID = nil
                    self.applyKeyboardActions(
                        self.keyboardState.deadlineReached(pressID: pressID)
                    )
                }
            case .cancelLongPress(let pressID):
                guard keyboardLongPressID == pressID else { break }
                keyboardLongPressTask?.cancel()
                keyboardLongPressTask = nil
                keyboardLongPressID = nil
            case .beginMomentaryRate(let rate, let pressID):
                onKeyboardMomentaryRateBegan(rate, pressID)
            case .endMomentaryRate(let pressID):
                onKeyboardMomentaryRateEnded(pressID)
            case .seekBy(let seconds):
                if onRelativeSeek(seconds) {
                    feedbackPresenter?.showFeedback(
                        .relativeSeek(Int(seconds.rounded()))
                    )
                }
            case .adjustVolume(let offset):
                if let volume = onVolumeStep(offset) {
                    feedbackPresenter?.showFeedback(
                        .volume(Int((volume * 100).rounded()))
                    )
                }
            case .togglePlayback:
                if let isPlaying = onTogglePlayback() {
                    feedbackPresenter?.showFeedback(.playback(isPlaying))
                }
            case .toggleDanmaku:
                if let enabled = onToggleDanmaku() {
                    feedbackPresenter?.showFeedback(.danmaku(enabled))
                }
            case .toggleSubtitles:
                subtitleToggleTask?.cancel()
                subtitleToggleTask = Task { [weak self] in
                    guard let self else { return }
                    let result = await self.onToggleSubtitles()
                    guard !Task.isCancelled else { return }
                    self.subtitleToggleTask = nil
                    self.feedbackPresenter?.showFeedback(.subtitles(result))
                }
            }
        }
    }

    private func cancelIfEditableResponder() {
        guard
            let window = anchorView?.window,
            Self.focusedResponderOwnsKeys(
                window.firstResponder,
                playerView: enclosingPlayerView
            )
        else { return }
        cancelInputSession()
    }

    private var enclosingPlayerView: AVPlayerView? {
        var ancestor = anchorView?.superview
        while let current = ancestor {
            if let playerView = current as? AVPlayerView { return playerView }
            ancestor = current.superview
        }
        return nil
    }

    /// 键盘焦点位于播放器之外的可交互控件时，快捷键交还给该控件。
    ///
    /// 包括可编辑文本、全键盘访问聚焦的按钮／分段控件、可键盘导航的列表，以及声明为
    /// `PlayerKeyboardFocusOwner` 的浮层（例如评论图片预览）。播放器自身及其子视图仍由播放器处理；
    /// 只可选择、不可编辑的文本不拦截空格等快捷键。
    static func focusedResponderOwnsKeys(
        _ responder: NSResponder?,
        playerView: NSView?
    ) -> Bool {
        guard let view = responder as? NSView else { return false }
        if let playerView, view === playerView || view.isDescendant(of: playerView) {
            return false
        }
        var ancestor: NSView? = view
        while let current = ancestor {
            if current is PlayerKeyboardFocusOwner { return true }
            ancestor = current.superview
        }
        switch view {
        case let textView as NSTextView:
            return textView.isEditable
        case let textField as NSTextField:
            return textField.isEditable
        case let collectionView as NSCollectionView:
            return collectionView.isSelectable
        case is NSControl:
            return true
        default:
            return false
        }
    }

    private nonisolated static func keyboardSnapshot(
        from event: NSEvent
    ) -> KeyboardEventSnapshot? {
        let key: KeyboardKey
        switch event.specialKey {
        case .leftArrow: key = .direction(.left)
        case .rightArrow: key = .direction(.right)
        case .upArrow: key = .direction(.up)
        case .downArrow: key = .direction(.down)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ": key = .shortcut(.playback)
            case "d": key = .shortcut(.danmaku)
            case "c": key = .shortcut(.subtitles)
            default: return nil
            }
        }
        let disallowedModifiers: NSEvent.ModifierFlags = [
            .command, .control, .option, .shift
        ]
        return KeyboardEventSnapshot(
            type: event.type,
            key: key,
            hasDisallowedModifier:
                !event.modifierFlags.intersection(disallowedModifiers).isEmpty,
            isRepeat: event.isARepeat,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber
        )
    }
}
