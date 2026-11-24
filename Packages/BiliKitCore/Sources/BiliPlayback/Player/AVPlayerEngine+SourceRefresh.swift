@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import Foundation

/// 媒体地址过期后的换源：继续播放、拖动与播放中失败前的过期检查，换源请求，以及在原位置重建 item。
///
/// 只写本 engine 的 `sourceExpiry`、`pendingSourceRefresh`、`sourceRefreshResumesPlayback` 与
/// `mediaSelectionGroups`，并经 `install` 复用 load 的准备、回退阶梯与清理。换源请求只是事件：重取 playurl 的是
/// 订阅方（`VideoViewModel`），它调用 `refreshSource` 或 `stop`。
extension AVPlayerEngine {
    public func refreshSource(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        guard loadIntent == intent,
            timeline.currentSnapshot.identity == identity,
            let item = player.currentItem
        else { throw CancellationError() }
        // 选择要在释放旧 item 前记下；位置与是否播放优先取被推迟的意图（拖动目标、等待期间的暂停）。
        let snapshot = timeline.currentSnapshot
        let continuation = PlaybackSourceContinuation(
            positionSeconds: pendingSourceRefresh?.positionSeconds
                ?? Self.validSeconds(player.currentTime()) ?? snapshot.positionSeconds,
            resumesPlayback: pendingSourceRefresh?.resumesPlayback
                ?? Self.isPlaybackActive(snapshot.state),
            mediaSelection: mediaSelectionGroups.snapshot(
                of: item,
                subtitlePreference: lastSubtitleSelection
            )
        )
        try await install(
            PlaybackRequest(
                media: playback.media,
                mediaHeaders: playback.mediaHeaders,
                startPositionSeconds: continuation.positionSeconds,
                mediaExpiresAt: playback.mediaExpiresAt
            ),
            identity: identity,
            intent: intent,
            continuing: continuation
        )
    }

    /// 继续播放或拖动前的过期检查：地址已过期或即将过期时停住播放器、记下被推迟的意图并请求换源。
    ///
    /// `resumesPlayback` 为 nil 表示沿用当前状态（拖动不改变是否在播放）；`targetSeconds` 为 nil 表示从当前位置继续。
    /// 已在等待换源时只改写被推迟的意图，并再发一次事件：订阅方若已丢弃上一次（例如当时页面还没就绪），用户
    /// 再操作一次仍能触发换源。返回 true 表示这次动作已被接管，调用方不得再动旧 item。
    func deferToSourceRefresh(resumesPlayback: Bool?, targetSeconds: Double?) -> Bool {
        let snapshot = timeline.currentSnapshot
        guard player.currentItem != nil,
            let identity = snapshot.identity,
            let intent = loadIntent,
            pendingSourceRefresh != nil || sourceExpiry.requiresRefresh(at: Date())
        else { return false }
        let pending = PendingSourceRefresh(
            positionSeconds: targetSeconds
                ?? pendingSourceRefresh?.positionSeconds
                ?? Self.validSeconds(player.currentTime()) ?? snapshot.positionSeconds,
            resumesPlayback: resumesPlayback
                ?? pendingSourceRefresh?.resumesPlayback
                ?? Self.isPlaybackActive(snapshot.state)
        )
        requestSourceRefresh(pending, identity: identity, intent: intent)
        return true
    }

    /// adapter 在当前 item 失败、写 failed 之前调用：地址已过期或即将过期时改为请求换源，返回 true。
    ///
    /// 每个 item 只兜底一次：adapter 对同一 item 只报告一次失败，换源得到的 item 若一就绪就在余量内也不再检查
    /// （见 `PlaybackSourceExpiry`）。失败的 item 留在播放器上直到换源或 `stop`，换源时还要从它读选择。
    func recoverFromExpiredSourceFailure(_ snapshot: PlaybackTimelineSnapshot) -> Bool {
        guard let identity = snapshot.identity,
            let intent = loadIntent,
            pendingSourceRefresh != nil || sourceExpiry.requiresRefresh(at: Date())
        else { return false }
        requestSourceRefresh(
            pendingSourceRefresh
                ?? PendingSourceRefresh(
                    positionSeconds: snapshot.positionSeconds,
                    resumesPlayback: Self.isPlaybackActive(snapshot.state)
                ),
            identity: identity,
            intent: intent
        )
        return true
    }

    /// 就绪 item 的收尾：读选项组；换源时选回音轨与字幕、progressive 定位到原处；建立地址有效期；标记就绪；
    /// 换源前在播放、重建期间也没有暂停的继续播放。
    ///
    /// 选择在标记就绪与开播之前恢复，播放器不会先用默认音轨出声。每次 await 之后比对 generation。
    func finishInstalling(
        _ item: AVPlayerItem,
        expiresAt: Date?,
        isProgressive: Bool,
        continuing continuation: PlaybackSourceContinuation?,
        generation: UUID
    ) async throws {
        let groups =
            isProgressive
            ? NativeMediaSelectionGroups.none
            : await NativeMediaSelectionGroups.load(from: item.asset)
        try requireCurrentLoad(generation)
        mediaSelectionGroups = groups
        if let continuation {
            groups.restore(continuation.mediaSelection, on: item)
            lastSubtitleSelection = continuation.mediaSelection.subtitlePreference
            // progressive 没有 playlist 的起播位置，只能就绪后 seek 回去。
            if isProgressive, continuation.positionSeconds > 0 {
                _ = await seek(to: continuation.positionSeconds, tolerance: .zero)
                try requireCurrentLoad(generation)
            }
        }
        sourceExpiry = PlaybackSourceExpiry(
            expiresAt: expiresAt,
            installedAt: Date(),
            isReplacement: continuation != nil
        )
        timeline.markReady(duration: item.duration)
        if continuation != nil, sourceRefreshResumesPlayback {
            timeline.play()
        }
    }

    private func requestSourceRefresh(
        _ pending: PendingSourceRefresh,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) {
        pendingSourceRefresh = pending
        timeline.pause()
        sourceExpiryEvents.yield(
            PlaybackSourceExpiryEvent(
                identity: identity,
                intent: intent,
                positionSeconds: pending.positionSeconds
            )
        )
    }

    private func requireCurrentLoad(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard loadGeneration == generation else { throw CancellationError() }
    }

    private static func isPlaybackActive(_ state: PlaybackTimelineState) -> Bool {
        state == .playing || state == .buffering
    }
}
