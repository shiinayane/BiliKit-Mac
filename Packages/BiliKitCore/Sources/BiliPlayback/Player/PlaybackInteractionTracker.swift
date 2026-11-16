import Synchronization

/// 记录当前 item 上是否发生过用户交互（暂停、seek、时间跳变），供起播与续播判定拒绝过期结果。
///
/// 拥有交互 revision 与内部 seek／内部起播的在途标记，不拥有 player 或时间线（交给
/// `AVPlayerTimelineAdapter`）。revision 在被判为用户操作时递增：seek 命令（含从头播放）在入口
/// 先递增一次并登记为内部 seek，之后这次 seek 引起的系统跳变与状态变化、内部起播，以及就绪时落在
/// 起播位置的系统跳变都不再递增；播到结尾时系统欠报的那次 paused 同样不递增。`AVPlayerEngine` 在
/// 入口之后取 revision、落点时比对，不一致即放弃落点。
/// 每个 item 一个实例，由 `AVPlayerTimelineAdapter.begin` 替换；KVO 回调在任意线程直接调用，
/// 状态只经 `Mutex` 访问。
final class PlaybackInteractionTracker: Sendable {
    /// playlist `EXT-X-START` 给出的起播位置；就绪附近落在这里的系统跳变不是用户操作。
    private let startPositionSeconds: Double

    /// 锁内状态：交互 revision、内部 seek 的目标与在途标记、内部起播在途标记、是否已开始播放，以及播到结尾
    /// 后是否还欠系统的一次 paused 报告。
    private struct State {
        var revision: UInt64 = 0
        var internalSeekTarget: Double?
        var internalSeekInFlight = false
        var internalPlayStartInFlight = false
        var hasPlaybackStarted = false
        var observedNonPausedDuringInternalSeek = false
        var owesEndOfItemPause = false
    }

    private let state = Mutex(State())

    init(startPositionSeconds: Double = 0) {
        self.startPositionSeconds = startPositionSeconds
    }

    var hasObservedInteraction: Bool {
        revision > 0
    }

    var revision: UInt64 {
        state.withLock { $0.revision }
    }

    func markObserved() {
        state.withLock {
            $0.revision &+= 1
            $0.internalSeekTarget = nil
            $0.internalSeekInFlight = false
            $0.internalPlayStartInFlight = false
            $0.observedNonPausedDuringInternalSeek = false
        }
    }

    func markObservedAllowingInternalSeek(to positionSeconds: Double) {
        state.withLock {
            $0.revision &+= 1
            $0.internalSeekTarget = positionSeconds
            $0.internalSeekInFlight = true
            $0.observedNonPausedDuringInternalSeek = false
        }
    }

    /// 新 item 的系统初始 paused 不算用户操作；会话已有交互后，paused 必须使在途提交失效。
    func observeTimeControlStatus(
        isPaused: Bool,
        isPlaying: Bool,
        playbackRate: Float
    ) {
        state.withLock {
            if $0.owesEndOfItemPause {
                $0.owesEndOfItemPause = false
                if isPaused { return }
            }
            if $0.internalPlayStartInFlight {
                if isPaused {
                    $0.revision &+= 1
                    $0.internalPlayStartInFlight = false
                } else if isPlaying {
                    $0.hasPlaybackStarted = true
                    $0.internalPlayStartInFlight = false
                }
                return
            }
            if $0.internalSeekInFlight, !isPaused {
                if isPlaying || playbackRate > 0 {
                    $0.observedNonPausedDuringInternalSeek = true
                }
                return
            }
            if $0.internalSeekInFlight,
                isPaused,
                $0.observedNonPausedDuringInternalSeek
            {
                $0.revision &+= 1
                $0.internalSeekTarget = nil
                $0.internalSeekInFlight = false
                $0.observedNonPausedDuringInternalSeek = false
                return
            }
            guard
                !isPaused || $0.revision > 0 || $0.hasPlaybackStarted
            else { return }
            $0.revision &+= 1
            if isPlaying {
                $0.hasPlaybackStarted = true
            }
            $0.internalSeekTarget = nil
            $0.internalSeekInFlight = false
            $0.observedNonPausedDuringInternalSeek = false
        }
    }

    /// 由 `AVPlayerTimelineAdapter` 的结束通知在系统尚未报 paused 时调用：之后第一次状态报告若是 paused，
    /// 就是播到结尾的系统暂停，不算用户操作。
    ///
    /// 这次 paused 可能晚于时间线发布 `.ended` 才到达，正落在单集循环重播的内部 seek 期间；按用户暂停计数会
    /// 作废重播的落点。只抵一次：先到的是非 paused 报告（重新开播）时直接作废，之后的暂停照常计数。
    func expectEndOfItemPause() {
        state.withLock { $0.owesEndOfItemPause = true }
    }

    func allowInternalPlayStart() {
        state.withLock { $0.internalPlayStartInFlight = true }
    }

    func completeInternalSeek(at positionSeconds: Double) {
        state.withLock {
            $0.internalSeekTarget = positionSeconds
            $0.internalSeekInFlight = false
            $0.observedNonPausedDuringInternalSeek = false
        }
    }

    func cancelInternalSeek() {
        state.withLock {
            $0.internalSeekTarget = nil
            $0.internalSeekInFlight = false
            $0.observedNonPausedDuringInternalSeek = false
        }
    }

    /// 内部 seek 允许同一目标产生一个或多个系统 time-jump；item 起播时落在起播位置的系统跳变
    /// 同样放行；其他跳变立即记为用户意图。
    func observeTimeJump(at positionSeconds: Double) {
        state.withLock {
            if $0.internalSeekInFlight {
                // 受控 seek 会在命令入口先推进 revision，因此这里不能按 HLS 实际落点与目标的距离
                // 猜测来源。
                return
            }
            if $0.revision == 0,
                $0.internalSeekTarget == nil,
                abs(positionSeconds - startPositionSeconds) <= 0.25
            {
                return
            }
            if let target = $0.internalSeekTarget,
                abs(target - positionSeconds) <= SeekPolicy.landingMatchToleranceSeconds
            {
                return
            }
            $0.revision &+= 1
            $0.internalSeekTarget = nil
        }
    }
}
