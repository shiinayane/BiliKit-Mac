import AppKit
import BiliApplication
import BiliBrowseFeature
import SwiftUI
import Testing

@testable import BiliKit

@MainActor
struct PlayerOverlayModelTests {
    @Test
    func heldMomentaryRateStaysUntilEndedWhileOtherFeedbackExpires() throws {
        let model = PlayerOverlayModel()

        model.showFeedback(.volume(40))
        let transient = try #require(model.feedback)
        #expect(transient.dismissesAutomatically)
        model.endMomentaryRate()
        #expect(model.feedback == transient)

        model.showMomentaryRate(.fast)
        let held = try #require(model.feedback)
        #expect(held.content == .momentaryRate(.fast))
        #expect(!held.dismissesAutomatically)
        model.expireFeedback(id: transient.id)
        #expect(model.feedback == held)

        model.endMomentaryRate()
        #expect(model.feedback == nil)
    }

    @Test
    func feedbackExpiryOnlyRemovesTheScheduledBadge() throws {
        let model = PlayerOverlayModel()
        model.showFeedback(.playback(true))
        let first = try #require(model.feedback)
        model.showFeedback(.playback(false))
        let replacement = try #require(model.feedback)

        model.expireFeedback(id: first.id)
        #expect(model.feedback == replacement)

        model.expireFeedback(id: replacement.id)
        #expect(model.feedback == nil)

        model.showFeedback(.danmaku(true))
        model.clearFeedback()
        #expect(model.feedback == nil)
    }

    @Test
    func dismissedResumeNoticeDoesNotReturnUntilTheNoticeIsWithdrawn() {
        let model = PlayerOverlayModel()
        let notice = PlaybackResumeNotice(positionSeconds: 30, token: PlaybackResumeToken())
        var restartCount = 0

        model.setResumeNotice(notice) {}
        #expect(model.resumeNotice == notice)
        model.setResumeNotice(notice) { restartCount += 1 }
        model.restartFromBeginning()
        #expect(restartCount == 1)

        model.expireResumeNotice(token: PlaybackResumeToken())
        #expect(model.resumeNotice == notice)
        model.expireResumeNotice(token: notice.token)
        #expect(model.resumeNotice == nil)
        model.setResumeNotice(notice) {}
        #expect(model.resumeNotice == nil)

        let next = PlaybackResumeNotice(positionSeconds: 12, token: PlaybackResumeToken())
        model.setResumeNotice(next) {}
        #expect(model.resumeNotice == next)

        model.setResumeNotice(nil) {}
        #expect(model.resumeNotice == nil)
        model.setResumeNotice(notice) {}
        #expect(model.resumeNotice == notice)
    }

    @Test(arguments: [
        (30.4, true),
        (29.6, true),
        (30.6, false),
        (0, false),
        (Double.nan, false),
        (Double.infinity, false)
    ])
    func timeJumpAwayFromResumePositionDismissesTheNotice(
        seconds: Double,
        keepsNotice: Bool
    ) {
        let model = PlayerOverlayModel()
        let notice = PlaybackResumeNotice(positionSeconds: 30, token: PlaybackResumeToken())
        model.setResumeNotice(notice) {}

        model.observeTimeJump(toSeconds: seconds)

        #expect((model.resumeNotice == notice) == keepsNotice)
        model.setResumeNotice(notice) {}
        #expect((model.resumeNotice == notice) == keepsNotice)
    }

    @Test
    func overlayHostPassesThroughEverywhereExceptTheInteractiveFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container
        let host = PassthroughHostingView(rootView: Color.clear)
        host.frame = container.bounds
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let nearTopLeading = NSPoint(x: 10, y: container.bounds.maxY - 10)
        let nearBottomLeading = NSPoint(x: 10, y: 10)

        #expect(host.hitTest(nearTopLeading) == nil)

        // 可交互区域使用 SwiftUI 的左上原点坐标。
        host.interactiveFrame = { CGRect(x: 0, y: 0, width: 200, height: 150) }
        #expect(host.hitTest(nearTopLeading) != nil)
        #expect(host.hitTest(nearBottomLeading) == nil)
    }
}
