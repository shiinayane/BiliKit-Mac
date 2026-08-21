import BiliPlayback
import Foundation
import Testing

@testable import BiliKit

struct PlayerKeyboardInputStateTests {
    @Test
    func shortAndLongPressAreMutuallyExclusiveAndRepeatIndependent() {
        var shortState = PlayerKeyboardInputState()
        let shortID = UUID()
        #expect(
            shortState.keyDown(.right, isRepeat: false, timestamp: 0) {
                shortID
            } == [.scheduleLongPress(pressID: shortID)]
        )
        #expect(shortState.keyDown(.right, isRepeat: true, timestamp: 0.1).isEmpty)
        #expect(
            shortState.keyUp(.right) == [
                .cancelLongPress(pressID: shortID),
                .seekBy(seconds: 5),
            ]
        )
        #expect(shortState.deadlineReached(pressID: shortID).isEmpty)

        var longState = PlayerKeyboardInputState()
        let longID = UUID()
        _ = longState.keyDown(.left, isRepeat: false, timestamp: 0) { longID }
        #expect(
            longState.deadlineReached(pressID: longID) == [
                .beginMomentaryRate(rate: .slow, pressID: longID)
            ]
        )
        #expect(longState.keyUp(.left) == [.endMomentaryRate(pressID: longID)])
    }

    @Test
    func staleKeyUpAndLifecycleCancellationCannotEndNewPress() {
        var state = PlayerKeyboardInputState()
        let leftID = UUID()
        let rightID = UUID()
        _ = state.keyDown(.left, isRepeat: false, timestamp: 0) { leftID }
        _ = state.deadlineReached(pressID: leftID)
        #expect(
            state.keyDown(.right, isRepeat: false, timestamp: 1) { rightID }
                == [
                    .endMomentaryRate(pressID: leftID),
                    .scheduleLongPress(pressID: rightID),
                ]
        )
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
        ]
        for (shortcut, action) in cases {
            #expect(state.shortcutKeyDown(shortcut, isRepeat: false) == [action])
            #expect(state.shortcutKeyDown(shortcut, isRepeat: true).isEmpty)
            _ = state.shortcutKeyUp(shortcut)
        }
    }

    @Test
    func detailWindowScopeExcludesModifiersEditingAndOtherWindows() {
        #expect(
            PlayerKeyboardEventScope.captures(
                isEnabled: true,
                isSupportedKey: true,
                hasDisallowedModifier: false,
                eventMatchesCaptureWindow: true,
                isEditableResponder: false
            )
        )
        for excluded in [
            (false, true, false, true, false),
            (true, false, false, true, false),
            (true, true, true, true, false),
            (true, true, false, false, false),
            (true, true, false, true, true),
        ] {
            #expect(
                !PlayerKeyboardEventScope.captures(
                    isEnabled: excluded.0,
                    isSupportedKey: excluded.1,
                    hasDisallowedModifier: excluded.2,
                    eventMatchesCaptureWindow: excluded.3,
                    isEditableResponder: excluded.4
                )
            )
        }
    }

    @Test
    func feedbackDismissalUsesStaleIdentityGuard() {
        let identity = UUID()
        #expect(PlayerShortcutFeedbackDismissalPolicy.delay == .milliseconds(800))
        #expect(PlayerShortcutFeedbackDismissalPolicy.fadeDuration == 0.16)
        #expect(
            PlayerShortcutFeedbackDismissalPolicy.shouldAnimate(
                reduceMotion: false
            )
        )
        #expect(
            !PlayerShortcutFeedbackDismissalPolicy.shouldAnimate(
                reduceMotion: true
            )
        )
        #expect(
            PlayerShortcutFeedbackDismissalPolicy.shouldDismiss(
                displayedID: identity,
                scheduledID: identity
            )
        )
        #expect(
            !PlayerShortcutFeedbackDismissalPolicy.shouldDismiss(
                displayedID: UUID(),
                scheduledID: identity
            )
        )
        #expect(PlayerShortcutFeedback.volume(55).label == "55%")
        #expect(PlayerShortcutFeedback.relativeSeek(-5).label == "后退 5 秒")
        #expect(PlayerShortcutFeedback.relativeSeek(5).label == "前进 5 秒")
        #expect(
            PlayerShortcutFeedback.relativeSeek(-5).symbolName
                == "gobackward.5"
        )
        #expect(
            PlayerShortcutFeedback.relativeSeek(5).accessibilityLabel
                == "已前进 5 秒"
        )
        #expect(PlayerShortcutFeedback.playback(true).label == "播放")
        #expect(PlayerShortcutFeedback.playback(false).label == "暂停")
        #expect(PlayerShortcutFeedback.playback(true).symbolName == "play.fill")
        #expect(
            PlayerShortcutFeedback.playback(false).accessibilityLabel
                == "已暂停播放"
        )
        #expect(PlayerShortcutFeedback.danmaku(false).label == "弹幕 关")
        #expect(
            PlayerShortcutFeedback.subtitles(.unavailable).label == "无可用字幕"
        )
    }
}
