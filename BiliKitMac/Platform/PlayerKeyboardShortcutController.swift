import AppKit
import BiliPlayback

/// 播放器键盘快捷键：本地 key monitor、长按临时倍速、离散快捷键与焦点让渡规则。
///
/// 以 content overlay 中的弹幕层为锚点取所在窗口，因此 detached 全屏窗口里同样生效。由
/// `NativePlayerHostView` 持有：弹幕层挂上 content overlay 时 `startMonitoring()`，拆除时宿主先
/// `cancelInputSession()` 再 `stopMonitoring()`。拥有本地 key monitor、长按计时 Task、点赞键按住计时
/// Task 与字幕切换 Task；`cancelInputSession()` 取消三个 Task、结束仍在进行的长按并收起长按倍速与三连进度
/// 徽章。两个计时到时分别按 `keyboardLongPressID`、`likeHoldID` 与状态机的 `pressID` 比对，不符即丢弃。
/// 点赞、投币、收藏只调用宿主给的闭包，门槛与写入在 App 的写入协调者。MainActor 隔离，local monitor
/// 回调在主线程上同步决定是否吞掉事件。
@MainActor
final class PlayerKeyboardShortcutController {
    private enum KeyboardKey: Sendable {
        case direction(PlayerKeyboardDirection)
        case shortcut(PlayerKeyboardShortcut)
        case like
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
    private var likeHoldTask: Task<Void, Never>?
    private var likeHoldID: UUID?
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
    var onToggleFullScreen: () -> Void = {}
    var onToggleSubtitles: () async -> NativeSubtitleToggleResult = {
        .unavailable
    }
    /// 点赞、三连、投币与收藏：执行意图并返回要在播放器上显示的提示（nil 不显示，例如打开了面板）。
    var onToggleLike: () -> PlayerEngagementFeedback? = { nil }
    var onTriple: () -> PlayerEngagementFeedback? = { nil }
    var onOpenCoinPanel: () -> PlayerEngagementFeedback? = { nil }
    var onChooseFavoriteFolders: () -> PlayerEngagementFeedback? = { nil }
    /// 回车呼出发送弹幕的输入胶囊；输入框随即取得焦点，之后的按键不再经过这里（`focusedResponderOwnsKeys`）。
    var onOpenDanmakuComposer: () -> Void = {}

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
        likeHoldTask?.cancel()
        likeHoldTask = nil
        likeHoldID = nil
        subtitleToggleTask?.cancel()
        subtitleToggleTask = nil
        // 只收起按住期间的倍速与三连进度徽章；已完成操作的反馈照常到时淡出。暂停也会走到这里（播放器停下即结束
        // 长按），清掉全部反馈会让空格暂停的“暂停”徽章一出现就消失。
        feedbackPresenter?.endMomentaryRate()
        feedbackPresenter?.endTripleProgress()
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
            captureWindow.firstResponder
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
        case (.keyDown, .like):
            actions = keyboardState.likeKeyDown(isRepeat: event.isRepeat)
        case (.keyUp, .like):
            actions = keyboardState.likeKeyUp()
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
            case .toggleFullScreen:
                // 全屏过渡本身就是反馈，不再显示徽标。
                onToggleFullScreen()
            case .openCoinPanel:
                showEngagementFeedback(onOpenCoinPanel())
            case .chooseFavoriteFolders:
                showEngagementFeedback(onChooseFavoriteFolders())
            case .openDanmakuComposer:
                // 先结束仍按住的长按（临时倍速、三连进度），输入期间不再收到它们的抬起。
                cancelInputSession()
                onOpenDanmakuComposer()
            case .scheduleLikeHold(let pressID):
                scheduleLikeHold(pressID: pressID)
            case .cancelLikeHold(let pressID):
                guard likeHoldID == pressID else { break }
                likeHoldTask?.cancel()
                likeHoldTask = nil
                likeHoldID = nil
            case .beginTripleProgress:
                feedbackPresenter?.showTripleProgress()
            case .endTripleProgress:
                feedbackPresenter?.endTripleProgress()
            case .toggleLike:
                showEngagementFeedback(onToggleLike())
            case .triple:
                showEngagementFeedback(onTriple())
            }
        }
    }

    private func showEngagementFeedback(_ feedback: PlayerEngagementFeedback?) {
        guard let feedback else { return }
        feedbackPresenter?.showFeedback(.engagement(feedback))
    }

    /// 点赞键按住的两个时限：`longPressDelay` 时显示三连进度，`tripleHoldDuration` 时三连；都按 `pressID` 比对。
    private func scheduleLikeHold(pressID: UUID) {
        likeHoldTask?.cancel()
        likeHoldID = pressID
        likeHoldTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(PlayerKeyboardInputState.longPressDelay))
            } catch {
                return
            }
            guard let self, self.likeHoldID == pressID else { return }
            self.applyKeyboardActions(
                self.keyboardState.likeProgressDeadlineReached(pressID: pressID)
            )
            do {
                try await Task.sleep(
                    for: .seconds(
                        PlayerKeyboardInputState.tripleHoldDuration
                            - PlayerKeyboardInputState.longPressDelay
                    )
                )
            } catch {
                return
            }
            guard self.likeHoldID == pressID else { return }
            self.likeHoldTask = nil
            self.likeHoldID = nil
            self.applyKeyboardActions(
                self.keyboardState.likeTripleDeadlineReached(pressID: pressID)
            )
        }
    }

    private func cancelIfEditableResponder() {
        guard
            let window = anchorView?.window,
            Self.focusedResponderOwnsKeys(window.firstResponder)
        else { return }
        cancelInputSession()
    }

    /// 播放窗口里只有正在输入的文本拿走快捷键。
    ///
    /// 按钮、列表等其余控件即使持有焦点（点击空白、关闭评论图片预览后交还给缩略图、AVKit 全屏控件）
    /// 也不让出，空格、方向键始终控制播放；只可选择、不可编辑的文本同样不拦截。评论图片预览在自己的子窗口
    /// 面板里，事件不属于播放窗口，不经这里判断。
    static func focusedResponderOwnsKeys(_ responder: NSResponder?) -> Bool {
        switch responder {
        case let textView as NSTextView:
            return textView.isEditable
        case let textField as NSTextField:
            return textField.isEditable
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
        case .carriageReturn, .enter: key = .shortcut(.danmakuComposer)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ": key = .shortcut(.playback)
            case "d": key = .shortcut(.danmaku)
            case "c": key = .shortcut(.subtitles)
            case "f": key = .shortcut(.fullScreen)
            case "q": key = .like
            case "w": key = .shortcut(.coin)
            case "e": key = .shortcut(.favorite)
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
