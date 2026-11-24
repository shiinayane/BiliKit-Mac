import BiliApplication
import BiliModels

/// 播放地址过期后的换源：重取当前分 P 的 playurl，交给播放器在原处继续，页面状态一直是 `.ready`。
///
/// 换源跑在 `loadTask` 上，新视频、换分 P、重试与 reset 会一并取消它。它的每个出口要么调用 `refreshSource`，要么
/// 经 `presentPlaybackFailure` 停下播放器，播放器不会一直停在等换源的状态。
extension VideoViewModel {
    /// 与失败事件一样先按 identity 与 intent 丢弃旧 item 的事件，同一 intent 已在换源时忽略重复事件。
    ///
    /// 页面还没就绪（开播前）不能就地换源，按播放失败处理。重取或重建失败时进入 `.failedPage`，重试从事件给出的
    /// 位置继续。换源成功后不替换 `presentedContext` 与 `ready` 里的那一项：详情与分 P 不变，充电提示与可跳转时长
    /// 只取决于同一分 P 的媒体时长，新清单不会改变它们。
    func handlePlaybackSourceExpiry(_ event: PlaybackSourceExpiryEvent) {
        guard requestedPlaybackIdentity == event.identity,
            playbackIntent == event.intent
        else { return }
        guard case .ready(let playable) = state,
            presentedPlaybackIdentity == event.identity
        else {
            handlePlaybackFailure(
                PlaybackFailureEvent(
                    identity: event.identity,
                    intent: event.intent,
                    positionSeconds: event.positionSeconds
                )
            )
            return
        }
        guard sourceRefreshIntent != event.intent else { return }
        sourceRefreshIntent = event.intent
        let useCase = useCase
        let playback = playback
        loadTask.replace { [weak self] isCurrent in
            do {
                let replacement = try await useCase.preparePage(
                    in: playable.context,
                    cid: event.identity.cid
                )
                try Task.checkCancellation()
                guard isCurrent() else { return }
                try await playback.refreshSource(
                    replacement.playback,
                    identity: event.identity,
                    intent: event.intent
                )
                guard let self, isCurrent() else { return }
                self.sourceRefreshIntent = nil
                // 续播提示的“从头播放”只对旧 item 有效。
                self.clearResumeNotice()
            } catch {
                guard let self, isCurrent() else { return }
                self.sourceRefreshIntent = nil
                let failure: VideoLoadFailure
                if let error = error as? ContentApplicationError {
                    self.recordAuthenticationInvalidationIfNeeded(error)
                    failure = .content(error)
                } else {
                    failure = .playback
                }
                self.presentPlaybackFailure(
                    of: event.identity,
                    failure: failure,
                    retryPositionSeconds: event.positionSeconds
                )
            }
        }
    }
}
