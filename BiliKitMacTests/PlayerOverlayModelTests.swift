import AVFoundation
import AppKit
import BiliApplication
import BiliVideoDetailFeature
import SwiftUI
import Testing

@testable import BiliKit

/// 播放器浮层的临时提示、续播提示与转圈各自只在该出现时出现。
///
/// 按住的临时倍速徽章留到松开，其他徽章按各自计时消失；关掉的续播提示在撤回前不再出现，跳离续播位置即关闭；
/// 转圈只覆盖准备期没有 item 与等待画面且延迟到期仍在等的时候；浮层只在可交互区域拦截点击。
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
    }

    @Test
    func cancellingInputSessionEndsOnlyTheHeldMomentaryRateBadge() throws {
        let model = PlayerOverlayModel()
        let shortcuts = PlayerKeyboardShortcutController()
        shortcuts.feedbackPresenter = model

        // 空格暂停后播放器停下会取消输入会话，“暂停”徽章要照常停留到自动消失。
        model.showFeedback(.playback(false))
        let paused = try #require(model.feedback)
        shortcuts.cancelInputSession()
        #expect(model.feedback == paused)

        model.showMomentaryRate(.fast)
        shortcuts.cancelInputSession()
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

    /// 准备期间没有 item 时由浮层转圈；item 挂上后交给 AVKit 自己的转圈，两者不叠加。
    @Test(arguments: [
        (true, false, true),
        (true, true, false),
        (false, false, false),
        (false, true, false)
    ])
    func preparationActivityCoversOnlyThePreparationGapWithoutAnItem(
        isPreparing: Bool,
        hasCurrentItem: Bool,
        showsActivity: Bool
    ) {
        let model = PlayerOverlayModel()

        model.setPreparationActivity(isPreparing: isPreparing, hasCurrentItem: hasCurrentItem)

        #expect(model.showsPreparationActivity == showsActivity)
    }

    /// 用户在等画面才转：seek 未落地（无论播放、暂停还是 progressive 源 seek 期间仍为 playing），或要播却停着
    /// 等数据；缓冲充足的等待、暂停、准备期间与 item 未就绪都不转。
    @Test(arguments: [
        (false, true, true, AVPlayer.TimeControlStatus.paused, true, true),
        (false, true, true, .playing, true, true),
        (false, true, true, .waitingToPlayAtSpecifiedRate, false, true),
        (false, true, false, .waitingToPlayAtSpecifiedRate, false, true),
        (false, true, false, .waitingToPlayAtSpecifiedRate, true, false),
        (false, true, false, .paused, false, false),
        (false, true, false, .playing, true, false),
        (true, true, true, .waitingToPlayAtSpecifiedRate, false, false),
        (false, false, true, .waitingToPlayAtSpecifiedRate, false, false)
    ])
    func loadingCoversOnlyWaitingForThePictureAfterPlaybackIsReady(
        isPreparing: Bool,
        isItemReady: Bool,
        hasPendingSeek: Bool,
        timeControlStatus: AVPlayer.TimeControlStatus,
        isPlaybackLikelyToKeepUp: Bool,
        isWaiting: Bool
    ) {
        #expect(
            PlayerLoadingPolicy.isWaitingForPicture(
                isPreparing: isPreparing,
                isItemReady: isItemReady,
                hasPendingSeek: hasPendingSeek,
                timeControlStatus: timeControlStatus,
                isPlaybackLikelyToKeepUp: isPlaybackLikelyToKeepUp
            ) == isWaiting
        )
    }

    /// 转圈只在这次等待的延迟到期时仍未结束才呈现；结束立即撤下，再次等待重新计时。
    @Test
    func loadingActivityAppearsOnlyForTheWaitStillInProgress() throws {
        let model = PlayerOverlayModel()

        model.setWaitingForPicture(true, landedSeekCount: 0)
        let finished = try #require(model.loadingID)
        #expect(!model.showsLoadingActivity)
        model.setWaitingForPicture(false, landedSeekCount: 0)
        model.presentLoading(id: finished)
        #expect(!model.showsLoadingActivity)

        model.setWaitingForPicture(true, landedSeekCount: 0)
        let shown = try #require(model.loadingID)
        model.presentLoading(id: shown)
        #expect(model.showsLoadingActivity)

        model.setWaitingForPicture(false, landedSeekCount: 0)
        #expect(!model.showsLoadingActivity)
        #expect(model.loadingID == nil)
        model.setWaitingForPicture(true, landedSeekCount: 0)
        let again = try #require(model.loadingID)
        #expect(again != shown)
        model.presentLoading(id: shown)
        #expect(!model.showsLoadingActivity)
        model.presentLoading(id: again)
        #expect(model.showsLoadingActivity)
    }

    /// 计时起点是最近一次画面更新：还没呈现时有 seek 落地就重新计时（拖动已缓冲区间不转），没落地的新 seek
    /// 不重新计时（未缓冲区连按照常转）；已经呈现后再落地也不让转圈闪一下。
    @Test
    func landedSeekRestartsTheDelayOnlyBeforeTheActivityIsShown() throws {
        let model = PlayerOverlayModel()

        model.setWaitingForPicture(true, landedSeekCount: 1)
        let first = try #require(model.loadingID)
        model.setWaitingForPicture(true, landedSeekCount: 1)
        #expect(model.loadingID == first)
        model.setWaitingForPicture(true, landedSeekCount: 2)
        let second = try #require(model.loadingID)
        #expect(second != first)
        model.presentLoading(id: first)
        #expect(!model.showsLoadingActivity)

        model.presentLoading(id: second)
        #expect(model.showsLoadingActivity)
        model.setWaitingForPicture(true, landedSeekCount: 3)
        #expect(model.loadingID == second)
        #expect(model.showsLoadingActivity)
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
        host.interactiveFrames = { [CGRect(x: 0, y: 0, width: 200, height: 150)] }
        #expect(host.hitTest(nearTopLeading) != nil)
        #expect(host.hitTest(nearBottomLeading) == nil)
    }
}
