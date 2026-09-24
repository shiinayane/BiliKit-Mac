import AppKit
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
                .seekBy(seconds: 5)
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
                    .scheduleLongPress(pressID: rightID)
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
            (.subtitles, .toggleSubtitles)
        ]
        for (shortcut, action) in cases {
            #expect(state.shortcutKeyDown(shortcut, isRepeat: false) == [action])
            #expect(state.shortcutKeyDown(shortcut, isRepeat: true).isEmpty)
            _ = state.shortcutKeyUp(shortcut)
        }
    }

    @Test
    func detailWindowScopeExcludesModifiersFocusedControlsAndOtherWindows() {
        #expect(
            PlayerKeyboardEventScope.captures(
                isEnabled: true,
                hasDisallowedModifier: false,
                eventMatchesCaptureWindow: true,
                focusedResponderOwnsKeys: false
            )
        )
        for excluded in [
            (false, false, true, false),
            (true, true, true, false),
            (true, false, false, false),
            (true, false, true, true)
        ] {
            #expect(
                !PlayerKeyboardEventScope.captures(
                    isEnabled: excluded.0,
                    hasDisallowedModifier: excluded.1,
                    eventMatchesCaptureWindow: excluded.2,
                    focusedResponderOwnsKeys: excluded.3
                )
            )
        }
    }

    @Test
    @MainActor
    func controlsOutsideThePlayerKeepTheirKeys() {
        let playerView = NSView()
        let playerButton = NSButton()
        playerView.addSubview(playerButton)
        let sidebarButton = NSButton()
        let readOnlyText = NSTextView()
        readOnlyText.isEditable = false
        let editableText = NSTextView()
        let overlay = KeyboardOwningOverlay()
        let overlayChild = NSView()
        overlay.addSubview(overlayChild)
        let listView = NSCollectionView()
        listView.isSelectable = true
        let staticListView = NSCollectionView()
        staticListView.isSelectable = false

        func ownsKeys(_ responder: NSResponder?) -> Bool {
            PlayerScrollWheelCaptureView.focusedResponderOwnsKeys(
                responder,
                playerView: playerView
            )
        }

        #expect(ownsKeys(sidebarButton))
        #expect(ownsKeys(editableText))
        #expect(ownsKeys(overlayChild))
        #expect(ownsKeys(listView))
        #expect(!ownsKeys(playerButton))
        #expect(!ownsKeys(readOnlyText))
        #expect(!ownsKeys(staticListView))
        #expect(!ownsKeys(NSView()))
        #expect(!ownsKeys(nil))
    }

    @Test
    func feedbackDismissalUsesStaleIdentityGuardAndRespectsReduceMotion() {
        let identity = UUID()
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
    }
}

@MainActor
private final class KeyboardOwningOverlay: NSView, PlayerKeyboardFocusOwner {}
