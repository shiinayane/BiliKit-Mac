import BiliModels
import Foundation

/// 跨播放器、字幕与弹幕共享的播放项目身份；日志描述会主动隐藏真实内容标识。
public struct PlaybackItemIdentity: Sendable, Hashable {
    public let bvid: String
    public let cid: Int64

    public init(bvid: String, cid: Int64) {
        self.bvid = bvid
        self.cid = cid
    }
}

extension PlaybackItemIdentity: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "PlaybackItemIdentity(redacted)" }
    public var debugDescription: String { description }
}

/// 一次不可复用的媒体加载意图；用于区分同一 `(bvid, cid)` 的 ABA 会话。
public struct PlaybackLoadIntent: Sendable, Hashable {
    private let value: UUID

    public init() {
        value = UUID()
    }
}

/// 一次成功断点定位的不可复用能力；旧浮层不能控制后来加载的 item。
public struct PlaybackResumeToken: Sendable, Hashable {
    private let value: UUID

    public init() {
        value = UUID()
    }
}

/// `PlaybackControlling.beginPlayback` 的结果。
///
/// `rejected`：intent 或 identity 已过期、item 未就绪、已在播放或已观察到用户操作；
/// `startedAtBeginning`：就绪位置接近开头；`resumed`：从续播位置开播，附带只对这次开播有效的
/// `PlaybackResumeToken`，供续播浮层“从头播放”使用。
public enum PlaybackStartOutcome: Sendable, Equatable {
    case rejected
    case startedAtBeginning
    case resumed(positionSeconds: Double, token: PlaybackResumeToken)
}

/// 续播位置的取舍规则，由 `VideoUseCase` 选择续播位置时读取。
public enum PlaybackResumePolicy {
    /// 接近片尾的服务器位置按已看完处理，避免恢复到结束画面。
    ///
    /// 调大会让更多接近片尾的位置改为从头播放，调小则可能续播到只剩几秒的片尾。
    public static let completedThresholdSeconds = 5.0
}

/// 播放器 adapter 发布的终态失败，带失败时的 identity 与 load intent。
///
/// 订阅方（播放页的 `VideoViewModel`）必须同时比对两者，只处理仍是当前加载意图的失败，丢弃旧 item
/// 的事件。
public struct PlaybackFailureEvent: Sendable, Equatable {
    public let identity: PlaybackItemIdentity
    public let intent: PlaybackLoadIntent

    public init(identity: PlaybackItemIdentity, intent: PlaybackLoadIntent) {
        self.identity = identity
        self.intent = intent
    }
}

/// 时间线的播放状态。
///
/// `ended` 只描述当前终点，seek 或重播形成新时间段后变回 `paused`；`failed` 由 adapter 在当前 item
/// 失败时写入，速率同时归零。
public enum PlaybackTimelineState: Sendable, Equatable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case buffering
    case ended
    case failed
}

/// 平台无关的媒体时间事实。
///
/// `discontinuityGeneration` 在换项、seek 或时间跳变时前进；需要识别 seek 的消费者（Now Playing、章节提示）用它，
/// 不能只比较秒数。弹幕不识别 seek，只按位置是否离开上次对齐后的一个步长对齐（见 docs/ARCHITECTURE.md
/// 「弹幕」）。
public struct PlaybackTimelineSnapshot: Sendable, Equatable {
    public let identity: PlaybackItemIdentity?
    /// 当前播放器 item 的不可复用加载意图；用于拒绝相同 identity 的 ABA 迟到结果。
    public let loadIntent: PlaybackLoadIntent?
    public let positionSeconds: Double
    public let durationSeconds: Double?
    public let rate: Double
    public let state: PlaybackTimelineState
    public let discontinuityGeneration: UInt64

    public init(
        identity: PlaybackItemIdentity?,
        positionSeconds: Double,
        durationSeconds: Double?,
        rate: Double,
        state: PlaybackTimelineState,
        discontinuityGeneration: UInt64,
        loadIntent: PlaybackLoadIntent? = nil
    ) {
        self.identity = identity
        self.loadIntent = loadIntent
        self.positionSeconds = Self.nonnegativeFinite(positionSeconds) ?? 0
        self.durationSeconds = durationSeconds.flatMap(Self.nonnegativeFinite)
        self.rate = Self.nonnegativeFinite(rate) ?? 0
        self.state = state
        self.discontinuityGeneration = discontinuityGeneration
    }

    /// 播放中周期快照的频率：每媒体秒 30 个，按 item 时间计，倍速下宿主时间的间隔随之缩放。
    ///
    /// 实现方按它安装周期观察器。弹幕以快照为检查节拍，步长加一个快照周期必须短于前瞻（见
    /// docs/ARCHITECTURE.md「弹幕」）。调高增加主线程回合，调低让进度显示与弹幕检查更稀。
    public static let periodicSnapshotsPerMediaSecond = 30

    public static let idle = PlaybackTimelineSnapshot(
        identity: nil,
        positionSeconds: 0,
        durationSeconds: nil,
        rate: 0,
        state: .idle,
        discontinuityGeneration: 0,
        loadIntent: nil
    )

    /// 以本快照为底、只替换给出的字段；store 的各写入口共用，`durationSeconds` 传 `.some(nil)` 表示清空。
    fileprivate func replacing(
        positionSeconds: Double? = nil,
        durationSeconds: Double?? = nil,
        rate: Double? = nil,
        state: PlaybackTimelineState? = nil,
        discontinuityGeneration: UInt64? = nil
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: positionSeconds ?? self.positionSeconds,
            durationSeconds: durationSeconds ?? self.durationSeconds,
            rate: rate ?? self.rate,
            state: state ?? self.state,
            discontinuityGeneration: discontinuityGeneration
                ?? self.discontinuityGeneration,
            loadIntent: loadIntent
        )
    }

    private static func nonnegativeFinite(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0 else { return nil }
        return value
    }
}

/// 播放器之外各消费方（弹幕、观看进度、播放器浮层、播放页章节与 Now Playing）共用的播放时钟。
///
/// 实现是 BiliPlayback 的 `AVPlayerEngine`，见 docs/ARCHITECTURE.md「媒体时间轴」。
/// 新订阅者应先得到当前快照；消费者不自建计时器。需要识别 seek 的消费者用 `discontinuityGeneration`
/// 而不是秒数判断；弹幕只按位置对齐，见 docs/ARCHITECTURE.md「弹幕」。
@MainActor
public protocol PlaybackTimelineProviding: AnyObject {
    var currentTimelineSnapshot: PlaybackTimelineSnapshot { get }
    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot>
    /// 边界敏感消费者在发布者的 MainActor 回合内同步接收每个快照；返回值负责取消观察。
    func observeTimeline(
        _ observer: @escaping @MainActor (PlaybackTimelineSnapshot) -> Void
    ) -> @MainActor @Sendable () -> Void
}

/// Feature 可驱动的最小播放命令边界；具体 AVPlayer 和 bridge 生命周期留在 adapter。
///
/// 实现是 BiliPlayback 的 `AVPlayerEngine`，调用方是播放页的 `VideoViewModel`，以及 App 的窗口组装（导航在播放页被盖住时
/// 暂停、回来时继续）。`beginPlayback`、`restartFromBeginning` 与 `replayFromBeginning` 在实现里与当前 item 的 identity、
/// intent 比对，已过期的意图被拒绝。
@MainActor
public protocol PlaybackControlling: AnyObject {
    /// 只发布 adapter 已按当前 item token／generation 验证过的终态失败。每次调用得到独立订阅，
    /// 只收到此后的事件；一个订阅者结束不影响其他订阅者。
    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent>
    /// 准备并安装播放项目；`startPositionSeconds` 为续播位置，就绪时 item 即位于该处
    /// （不支持起播位置的媒体忽略它、从头播放）。
    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        startPositionSeconds: Double?
    ) async throws
    /// 为当前 load intent 开播一次，并按就绪位置报告续播或从头开始；已有用户操作时拒绝。
    func beginPlayback(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async -> PlaybackStartOutcome
    /// 仅允许当前断点浮层把仍匹配的 item 定位到 0 秒并继续播放。
    func restartFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        resumeToken: PlaybackResumeToken
    ) async -> Bool
    /// 播完后从头再播（单集循环）：只在仍匹配的 item 停在结束处时定位到 0 秒并继续播放。
    func replayFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async -> Bool
    /// 继续播放当前 item；没有 item 时不动作。
    func play()
    func pause()
    func stop()
}

/// `PlaybackTimelineStore.beginItem` 发出的不可复用 item token；值只能在本文件构造，持有旧 token
/// 的写入会被 store 丢弃。
package struct PlaybackTimelineItemToken: Sendable, Equatable {
    fileprivate let value: UUID
}

/// 以不可复用 item token 拒绝旧 AVPlayer observer 写回的时间线状态容器。
///
/// 由 BiliPlayback 的 `AVPlayerTimelineAdapter` 持有并写入，它在每个新 item 时调用 `beginItem`
/// 取得 token。拥有当前快照、当前 token、`AsyncBroadcast` 订阅与同步 observer 表，不拥有 AVPlayer
/// 或 KVO observation。只有当前 token 的写入生效，`clear(token: nil)` 不比对 token；
/// 相同快照不重复发布。`discontinuityGeneration` 在 `beginItem`、`markDiscontinuity` 与 `clear`
/// 时递增。
@MainActor
package final class PlaybackTimelineStore {
    package private(set) var currentSnapshot = PlaybackTimelineSnapshot.idle

    private var currentToken: PlaybackTimelineItemToken?
    private let broadcast = AsyncBroadcast<PlaybackTimelineSnapshot>()
    private var observers: [UUID: @MainActor (PlaybackTimelineSnapshot) -> Void] = [:]

    package init() {}

    /// 创建只保留最新值的订阅，先补发当前快照；消费方结束时只移除它自己的订阅。
    package func updates() -> AsyncStream<PlaybackTimelineSnapshot> {
        broadcast.subscribe(startingWith: currentSnapshot)
    }

    /// heartbeat 等边界敏感消费者不经过只保留最新值的 AsyncStream 缓冲。
    package func observe(
        _ observer: @escaping @MainActor (PlaybackTimelineSnapshot) -> Void
    ) -> @MainActor @Sendable () -> Void {
        let observationID = UUID()
        observers[observationID] = observer
        observer(currentSnapshot)
        return { [weak self] in
            self?.observers[observationID] = nil
        }
    }

    @discardableResult
    package func beginItem(
        identity: PlaybackItemIdentity,
        loadIntent: PlaybackLoadIntent? = nil
    ) -> PlaybackTimelineItemToken {
        let token = PlaybackTimelineItemToken(value: UUID())
        currentToken = token
        publish(
            PlaybackTimelineSnapshot(
                identity: identity,
                positionSeconds: 0,
                durationSeconds: nil,
                rate: 0,
                state: .loading,
                discontinuityGeneration: nextDiscontinuityGeneration(),
                loadIntent: loadIntent
            )
        )
        return token
    }

    package func markReady(
        token: PlaybackTimelineItemToken,
        durationSeconds: Double?
    ) {
        guard token == currentToken else { return }
        let state =
            currentSnapshot.state == .loading
            ? PlaybackTimelineState.ready
            : currentSnapshot.state
        publish(
            currentSnapshot.replacing(
                durationSeconds: .some(durationSeconds),
                state: state
            )
        )
    }

    package func update(
        token: PlaybackTimelineItemToken,
        positionSeconds: Double? = nil,
        rate: Double? = nil,
        state: PlaybackTimelineState? = nil
    ) {
        guard token == currentToken else { return }
        publish(
            currentSnapshot.replacing(
                positionSeconds: positionSeconds,
                rate: rate,
                state: state
            )
        )
    }

    package func markDiscontinuity(
        token: PlaybackTimelineItemToken,
        positionSeconds: Double
    ) {
        guard token == currentToken else { return }
        // ended 只描述当前终点；seek/replay 一旦形成新时间段就不再是 ended。
        let state =
            currentSnapshot.state == .ended
            ? PlaybackTimelineState.paused
            : currentSnapshot.state
        publish(
            currentSnapshot.replacing(
                positionSeconds: positionSeconds,
                state: state,
                discontinuityGeneration: nextDiscontinuityGeneration()
            )
        )
    }

    package func markFailed(token: PlaybackTimelineItemToken) {
        guard token == currentToken else { return }
        publish(currentSnapshot.replacing(rate: 0, state: .failed))
    }

    package func clear(token: PlaybackTimelineItemToken?) {
        if let token, token != currentToken { return }
        guard currentToken != nil || currentSnapshot.state != .idle else {
            return
        }
        currentToken = nil
        publish(
            PlaybackTimelineSnapshot(
                identity: nil,
                positionSeconds: 0,
                durationSeconds: nil,
                rate: 0,
                state: .idle,
                discontinuityGeneration: nextDiscontinuityGeneration(),
                loadIntent: nil
            )
        )
    }

    private func nextDiscontinuityGeneration() -> UInt64 {
        currentSnapshot.discontinuityGeneration &+ 1
    }

    private func publish(_ snapshot: PlaybackTimelineSnapshot) {
        guard snapshot != currentSnapshot else { return }
        currentSnapshot = snapshot
        let currentObservers = Array(observers.values)
        for observer in currentObservers {
            observer(snapshot)
        }
        broadcast.yield(snapshot)
    }
}

/// 播放器接受的倍速范围；偏好恢复、键盘临时倍速与 AVPlayer 写入共用。
public enum PlaybackRate {
    public static let supported: ClosedRange<Double> = 0.25...4

    public static func isSupported(_ rate: Double) -> Bool {
        rate.isFinite && supported.contains(rate)
    }

    public static func isSupported(_ rate: Float) -> Bool {
        isSupported(Double(rate))
    }
}
