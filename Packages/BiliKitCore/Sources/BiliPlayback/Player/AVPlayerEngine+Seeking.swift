@preconcurrency import AVFoundation
import BiliApplication
import Foundation

/// 精确 seek、transport 相对跳转与它们共用的收尾；只写本 engine 的 seek 操作状态与时间线待定 seek。
///
/// 地址将过期时两种 seek 都不发给旧 item，改为推迟到换源之后（见 `deferToSourceRefresh`）。
extension AVPlayerEngine {
    /// 在当前 VOD item 上累计执行播放器 transport 的相对跳转。
    @discardableResult
    public func seekByTransportOffset(_ offsetSeconds: Double) -> Bool {
        guard let item = player.currentItem,
            let currentSeconds = Self.validSeconds(player.currentTime()),
            let durationSeconds = Self.validSeconds(item.duration)
        else { return false }
        // 地址将过期时不动旧 item：在被推迟的目标（或当前位置）上累计这次跳转，换源后从那里继续。
        if offsetSeconds.isFinite,
            deferToSourceRefresh(
                resumesPlayback: nil,
                targetSeconds: min(
                    max(
                        (pendingSourceRefresh?.positionSeconds ?? currentSeconds)
                            + offsetSeconds,
                        0
                    ),
                    durationSeconds
                )
            )
        {
            return true
        }
        let generation = loadGeneration
        let itemIdentity = ObjectIdentifier(item)
        guard
            let operation = transportSeek.prepare(
                offsetSeconds: offsetSeconds,
                currentSeconds: currentSeconds,
                durationSeconds: durationSeconds,
                generation: generation,
                itemIdentity: itemIdentity
            )
        else { return false }

        restartOperation = nil
        activeSeekOperationID = operation.id
        timeline.prepareObservedSeek(
            operationID: operation.id,
            to: operation.targetSeconds
        )
        issueSeek(
            to: operation.targetSeconds,
            tolerance: SeekPolicy.relativeSeekTolerance,
            generation: generation,
            item: item
        ) { engine, finished in
            let isOwned =
                engine.activeSeekOperationID == operation.id
                && engine.transportSeek.matches(operation)
            var landing: Double?
            if isOwned,
                case .completed(let positionSeconds) = engine.transportSeek.complete(
                    operation,
                    finished: finished,
                    resolvedPositionSeconds: finished
                        ? Self.validSeconds(engine.player.currentTime()) : nil
                )
            {
                landing = positionSeconds
            }
            engine.settleSeek(
                operation.id,
                didSeek: finished,
                isOwned: isOwned,
                item: item
            ) { landing }
        }
        return true
    }

    /// 同步接受当前 item 上的精确 seek，并在 engine 内完成 generation-safe 的异步收尾。
    ///
    /// 返回 `true` 表示 AVPlayer 已经收到请求；系统远程命令的同步 handler 无法等待完成回调。
    @discardableResult
    public func requestSeek(to time: Duration) -> Bool {
        guard let item = player.currentItem,
            let duration = currentTimelineSnapshot.durationSeconds
        else { return false }
        let seconds = time / .seconds(1)
        guard seconds.isFinite, seconds >= 0, seconds <= duration else {
            return false
        }
        if deferToSourceRefresh(resumesPlayback: nil, targetSeconds: seconds) {
            return true
        }

        let generation = loadGeneration
        let operation = UUID()
        restartOperation = nil
        supersedeTransportSeek()
        activeSeekOperationID = operation
        timeline.prepareObservedSeek(operationID: operation, to: seconds)
        issueSeek(
            to: seconds,
            tolerance: .zero,
            generation: generation,
            item: item
        ) { engine, didSeek in
            engine.settleSeek(
                operation,
                didSeek: didSeek,
                isOwned: engine.activeSeekOperationID == operation,
                item: item
            ) { seconds }
        }
        return true
    }

    /// 以 AVPlayer 的异步接口等待 seek 完成。
    func seek(to seconds: Double, tolerance: CMTime) async -> Bool {
        await player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: SeekPolicy.timescale),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    /// 同步向 AVPlayer 发出 seek，调用方可立即返回；完成回调回到 main actor，旧 load 或旧 item
    /// 的回调静默丢弃。
    func issueSeek(
        to seconds: Double,
        tolerance: CMTime,
        generation: UUID,
        item: AVPlayerItem,
        settle: @escaping @MainActor (AVPlayerEngine, Bool) -> Void
    ) {
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: SeekPolicy.timescale),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self, weak item] finished in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item,
                    self.loadGeneration == generation,
                    self.player.currentItem === item
                else { return }
                settle(self, finished)
            }
        }
    }

    /// 所有 seek 入口共用的收尾：只有仍拥有该操作的调用方才能写回时间线并结束 `activeSeekOperationID`。
    ///
    /// 被取代的操作只丢弃失败落点；等待期间上下文变化时，仅当 item 仍在播放器上才撤销时间线的
    /// 待定 seek；`landing` 返回 nil 表示落点不合格。
    @discardableResult
    func settleSeek(
        _ operationID: UUID,
        didSeek: Bool,
        isOwned: Bool,
        item: AVPlayerItem,
        contextIsValid: Bool = true,
        landing: () -> Double?
    ) -> SeekSettlement {
        guard isOwned else {
            if !didSeek {
                timeline.discardStaleSeekLanding(operationID: operationID)
            }
            return .superseded
        }
        guard didSeek else {
            timeline.seekFailed(operationID: operationID)
            activeSeekOperationID = nil
            return .failed
        }
        guard contextIsValid else {
            if player.currentItem === item {
                timeline.seekFailed(operationID: operationID)
            }
            activeSeekOperationID = nil
            return .contextChanged
        }
        guard let positionSeconds = landing() else {
            timeline.seekFailed(operationID: operationID)
            activeSeekOperationID = nil
            return .failed
        }
        timeline.seekCompleted(operationID: operationID, at: positionSeconds)
        activeSeekOperationID = nil
        return .landed(positionSeconds: positionSeconds)
    }

    func invalidateTransportSeek() {
        guard let operation = transportSeek.invalidate() else { return }
        timeline.seekFailed(operationID: operation.id)
        if activeSeekOperationID == operation.id {
            activeSeekOperationID = nil
        }
    }

    func supersedeTransportSeek() {
        guard let operation = transportSeek.invalidate() else { return }
        if activeSeekOperationID == operation.id {
            activeSeekOperationID = nil
        }
    }

    func handleSeekSupersededByExternalJump(_ operationID: UUID) {
        guard activeSeekOperationID == operationID else { return }
        activeSeekOperationID = nil
        if restartOperation == operationID {
            restartOperation = nil
        }
        if transportSeek.current?.id == operationID {
            transportSeek.invalidate()
        }
    }
}
