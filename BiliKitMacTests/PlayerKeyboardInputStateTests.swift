import AppKit
import BiliPlayback
import Foundation
import Testing

@testable import BiliKit

/// 左右键短按跳转、长按临时变速且两者互斥，旧按键与生命周期取消不会结束新的按压。
///
/// 音量键的系统重复按间隔限速，离散快捷键不重复；只有启用、无修饰键、事件来自播放窗口且焦点不在可编辑文本上时
/// 才接管按键。
struct PlayerKeyboardInputStateTests {
    @Test
    func shortAndLongPressAreMutuallyExclusiveAndRepeatIndependent() throws {
        var shortState = PlayerKeyboardInputState()
        let shortActions = shortState.keyDown(.right, isRepeat: false, timestamp: 0)
        let shortID = try scheduledPressID(shortActions)
        #expect(shortActions == [.scheduleLongPress(pressID: shortID)])
        #expect(shortState.keyDown(.right, isRepeat: true, timestamp: 0.1).isEmpty)
        #expect(
            shortState.keyUp(.right) == [
                .cancelLongPress(pressID: shortID),
                .seekBy(seconds: 5)
            ]
        )
        #expect(shortState.deadlineReached(pressID: shortID).isEmpty)

        var longState = PlayerKeyboardInputState()
        let longID = try scheduledPressID(
            longState.keyDown(.left, isRepeat: false, timestamp: 0)
        )
        #expect(
            longState.deadlineReached(pressID: longID) == [
                .beginMomentaryRate(rate: .slow, pressID: longID)
            ]
        )
        #expect(longState.keyUp(.left) == [.endMomentaryRate(pressID: longID)])
    }

    @Test
    func staleKeyUpAndLifecycleCancellationCannotEndNewPress() throws {
        var state = PlayerKeyboardInputState()
        let leftID = try scheduledPressID(
            state.keyDown(.left, isRepeat: false, timestamp: 0)
        )
        _ = state.deadlineReached(pressID: leftID)
        let rightActions = state.keyDown(.right, isRepeat: false, timestamp: 1)
        let rightID = try scheduledPressID(rightActions)
        #expect(
            rightActions == [
                .endMomentaryRate(pressID: leftID),
                .scheduleLongPress(pressID: rightID)
            ]
        )
        #expect(rightID != leftID)
        #expect(state.keyUp(.left).isEmpty)
        #expect(
            state.cancel() == [.cancelLongPress(pressID: rightID)]
        )
        #expect(state.keyDown(.right, isRepeat: true, timestamp: 2).isEmpty)
    }

    @Test
    func volumeAndDiscreteShortcutsHaveBoundedRepeatBehavior() {
        var state = PlayerKeyboardInputState()
        #expect(
            state.keyDown(.up, isRepeat: false, timestamp: 1)
                == [.adjustVolume(by: 0.05)]
        )
        #expect(state.keyDown(.up, isRepeat: true, timestamp: 1.04).isEmpty)
        #expect(
            state.keyDown(.up, isRepeat: true, timestamp: 1.08)
                == [.adjustVolume(by: 0.05)]
        )

        let cases: [(PlayerKeyboardShortcut, PlayerKeyboardInputState.Action)] = [
            (.playback, .togglePlayback),
            (.danmaku, .toggleDanmaku),
            (.subtitles, .toggleSubtitles),
            (.fullScreen, .toggleFullScreen)
        ]
        for (shortcut, action) in cases {
            #expect(state.shortcutKeyDown(shortcut, isRepeat: false) == [action])
            #expect(state.shortcutKeyDown(shortcut, isRepeat: true).isEmpty)
            _ = state.shortcutKeyUp(shortcut)
        }
    }

    @Test
    func detailWindowScopeCapturesOnlyAnEnabledUnmodifiedPlayerWindow() {
        #expect(
            PlayerKeyboardEventScope.captures(
                isEnabled: true,
                hasDisallowedModifier: false,
                eventMatchesCaptureWindow: true,
                focusedResponderOwnsKeys: false
            )
        )
    }

    /// 依次为：未启用、带修饰键、不是捕获窗口、焦点控件自行处理按键。
    @Test(
        arguments: [
            (false, false, true, false),
            (true, true, true, false),
            (true, false, false, false),
            (true, false, true, true)
        ]
    )
    func detailWindowScopeExcludesModifiersFocusedControlsAndOtherWindows(
        isEnabled: Bool,
        hasDisallowedModifier: Bool,
        eventMatchesCaptureWindow: Bool,
        focusedResponderOwnsKeys: Bool
    ) {
        #expect(
            !PlayerKeyboardEventScope.captures(
                isEnabled: isEnabled,
                hasDisallowedModifier: hasDisallowedModifier,
                eventMatchesCaptureWindow: eventMatchesCaptureWindow,
                focusedResponderOwnsKeys: focusedResponderOwnsKeys
            )
        )
    }

    @Test
    @MainActor
    func onlyTextInputTakesPlayerKeys() {
        let editableText = NSTextView()
        let editableField = NSTextField()
        let readOnlyText = NSTextView()
        readOnlyText.isEditable = false
        let selectableList = NSCollectionView()
        selectableList.isSelectable = true

        func ownsKeys(_ responder: NSResponder?) -> Bool {
            PlayerKeyboardShortcutController.focusedResponderOwnsKeys(responder)
        }

        #expect(ownsKeys(editableText))
        #expect(ownsKeys(editableField))
        // 点击或程序交还焦点的按钮、列表不拦截空格与方向键（关闭预览回到缩略图、点推荐列表空白）。
        #expect(!ownsKeys(NSButton()))
        #expect(!ownsKeys(selectableList))
        #expect(!ownsKeys(readOnlyText))
        #expect(!ownsKeys(NSView()))
        #expect(!ownsKeys(nil))
    }
}

/// 取出按下左右键时安排的长按计时 ID；没有安排长按就记录失败。
private func scheduledPressID(
    _ actions: [PlayerKeyboardInputState.Action]
) throws -> UUID {
    let ids = actions.compactMap { action -> UUID? in
        guard case .scheduleLongPress(let pressID) = action else { return nil }
        return pressID
    }
    return try #require(ids.count == 1 ? ids.first : nil)
}
