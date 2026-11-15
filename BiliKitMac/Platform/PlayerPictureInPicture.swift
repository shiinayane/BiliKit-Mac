import AVKit

/// 画中画的状态与「还原」的交接：记录画中画是否进行中，把「还原」与“没还原就关掉”交给窗口导航。
///
/// 由窗口的 `PlayerHostOwner` 持有一份并交给它留住的宿主；宿主的 `AVPlayerViewPictureInPictureDelegate` 回调转到这里。
/// 「还原」时先由导航弹回活视频所在的播放页（`onRestore`），等宿主随新页面回到窗口（`hostDidEnterWindow`）再告诉 AVKit
/// 已还原：太早回答时宿主还不在窗口里，AVKit 把画面还给一个没有窗口的视图。宿主到 `restoreDeadline` 还没回到窗口就回答
/// 没能还原，不让 AVKit 一直等。AVKit 先问「还原」、再报画中画已结束，所以结束时据 `isRestoring` 区分两种结束。
///
/// 待回答的「还原」同一时刻只有一个，连同它的兜底计时一起记在 `pendingRestore`：回答时先取消计时，计时不会答到后来的
/// 那次；新的「还原」到来时，上一次还没回答的先答没能还原。
@MainActor
final class PlayerPictureInPicture {
    /// 「还原」后等宿主回到窗口的上限：页面转场 0.3 秒，宿主在换页的那次更新里就挂回，这里留足余量。
    private static let restoreDeadline: Duration = .seconds(1)

    private(set) var isActive = false
    /// 「还原」：弹回活视频所在的播放页；返回是否能还原（活视频已不在历史里时不能）。
    var onRestore: (() -> Bool)?
    /// 画中画结束、但不是因为「还原」（用户点了关闭）。
    var onStopWithoutRestore: (() -> Void)?
    private var isRestoring = false
    private var pendingRestore: (completion: (Bool) -> Void, deadline: Task<Void, Never>)?

    func didStart() {
        isActive = true
        isRestoring = false
    }

    func didStop() {
        isActive = false
        let wasRestoring = isRestoring
        isRestoring = false
        if !wasRestoring { onStopWithoutRestore?() }
    }

    /// AVKit 请求还原界面；`hostIsInWindow` 为 true 时（播放页本来就在栈顶）立即回答。
    func restore(hostIsInWindow: Bool, completion: @escaping (Bool) -> Void) {
        isRestoring = true
        answerPendingRestore(restored: false)
        guard onRestore?() == true else {
            completion(false)
            return
        }
        guard !hostIsInWindow else {
            completion(true)
            return
        }
        let deadline = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: Self.restoreDeadline)) != nil else { return }
            self?.answerPendingRestore(restored: false)
        }
        pendingRestore = (completion, deadline)
    }

    /// 宿主回到窗口：有待回答的「还原」就告诉 AVKit 已还原。
    func hostDidEnterWindow() {
        answerPendingRestore(restored: true)
    }

    private func answerPendingRestore(restored: Bool) {
        guard let pendingRestore else { return }
        self.pendingRestore = nil
        pendingRestore.deadline.cancel()
        pendingRestore.completion(restored)
    }
}

extension NativePlayerHostView: AVPlayerViewPictureInPictureDelegate {
    func playerViewDidStartPicture(inPicture playerView: AVPlayerView) {
        pictureInPicture?.didStart()
    }

    func playerViewDidStopPicture(inPicture playerView: AVPlayerView) {
        pictureInPicture?.didStop()
    }

    func playerView(
        _ playerView: AVPlayerView,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
            @escaping (Bool) -> Void
    ) {
        guard let pictureInPicture else {
            completionHandler(window != nil)
            return
        }
        pictureInPicture.restore(hostIsInWindow: window != nil, completion: completionHandler)
    }
}
