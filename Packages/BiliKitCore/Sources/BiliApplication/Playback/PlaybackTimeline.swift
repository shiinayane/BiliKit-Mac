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

public enum PlaybackStartOutcome: Sendable, Equatable {
    case rejected
    case preparationFailed
    case startedAtBeginning
    case resumed(
        positionSeconds: Double,
        token: PlaybackResumeToken,
        discontinuityGeneration: UInt64
    )
}

public enum PlaybackResumePolicy {
    /// 接近片尾的服务器位置按已看完处理，避免恢复到结束画面。
    public static let completedThresholdSeconds = 5.0
}

public struct PlaybackFailureEvent: Sendable, Equatable {
    public let identity: PlaybackItemIdentity
    public let intent: PlaybackLoadIntent

    public init(identity: PlaybackItemIdentity, intent: PlaybackLoadIntent) {
        self.identity = identity
        self.intent = intent
    }
}

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
/// `discontinuityGeneration` 在换项、seek 或时间跳变时前进，消费者不能只比较秒数来判断连续性。
public struct PlaybackTimelineSnapshot: Sendable, Equatable {
    public let identity: PlaybackItemIdentity?
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
        discontinuityGeneration: UInt64
    ) {
        self.identity = identity
        self.positionSeconds = Self.nonnegativeFinite(positionSeconds) ?? 0
        self.durationSeconds = durationSeconds.flatMap(Self.nonnegativeFinite)
        self.rate = Self.nonnegativeFinite(rate) ?? 0
        self.state = state
        self.discontinuityGeneration = discontinuityGeneration
    }

    public static let idle = PlaybackTimelineSnapshot(
        identity: nil,
        positionSeconds: 0,
        durationSeconds: nil,
        rate: 0,
        state: .idle,
        discontinuityGeneration: 0
    )

    private static func nonnegativeFinite(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0 else { return nil }
        return value
    }
}

@MainActor
/// 字幕和弹幕消费的唯一播放时钟；新订阅者应先得到当前快照。
public protocol PlaybackTimelineProviding: AnyObject {
    var currentTimelineSnapshot: PlaybackTimelineSnapshot { get }
    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot>
}

@MainActor
/// Feature 可驱动的最小播放命令边界；具体 AVPlayer 和 bridge 生命周期留在 adapter。
public protocol PlaybackControlling: AnyObject {
    /// 只发布 adapter 已按当前 item token／generation 验证过的终态失败。
    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent>
    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws
    /// 为当前 load intent 原子完成可选首次定位与开播；用户意图可在任一 await 后否决提交。
    func beginPlayback(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        initialPositionSeconds: Double?
    ) async -> PlaybackStartOutcome
    /// 仅允许当前断点浮层把仍匹配的 item 定位到 0 秒并继续播放。
    func restartFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        resumeToken: PlaybackResumeToken
    ) async -> Bool
    func pause()
    func stop()
}

package struct PlaybackTimelineItemToken: Sendable, Equatable {
    fileprivate let value: UUID
}

@MainActor
/// 以不可复用 item token 拒绝旧 AVPlayer observer 写回的时间线状态容器。
package final class PlaybackTimelineStore {
    package private(set) var currentSnapshot = PlaybackTimelineSnapshot.idle
    package var subscriberCount: Int { continuations.count }

    private var currentToken: PlaybackTimelineItemToken?
    private var continuations: [UUID: AsyncStream<PlaybackTimelineSnapshot>.Continuation] = [:]

    package init() {}

    deinit {
        for continuation in continuations.values {
            continuation.finish()
        }
    }

    /// 创建只保留最新值的订阅，并在消费方结束时移除 continuation。
    package func updates() -> AsyncStream<PlaybackTimelineSnapshot> {
        let subscriptionID = UUID()
        let stream = AsyncStream<PlaybackTimelineSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[subscriptionID] = stream.continuation
        stream.continuation.yield(currentSnapshot)
        stream.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.continuations.removeValue(forKey: subscriptionID)
            }
        }
        return stream.stream
    }

    @discardableResult
    package func beginItem(
        identity: PlaybackItemIdentity
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
                discontinuityGeneration: nextGeneration()
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
            PlaybackTimelineSnapshot(
                identity: currentSnapshot.identity,
                positionSeconds: currentSnapshot.positionSeconds,
                durationSeconds: durationSeconds,
                rate: currentSnapshot.rate,
                state: state,
                discontinuityGeneration:
                    currentSnapshot.discontinuityGeneration
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
            PlaybackTimelineSnapshot(
                identity: currentSnapshot.identity,
                positionSeconds: positionSeconds
                    ?? currentSnapshot.positionSeconds,
                durationSeconds: currentSnapshot.durationSeconds,
                rate: rate ?? currentSnapshot.rate,
                state: state ?? currentSnapshot.state,
                discontinuityGeneration:
                    currentSnapshot.discontinuityGeneration
            )
        )
    }

    package func markDiscontinuity(
        token: PlaybackTimelineItemToken,
        positionSeconds: Double
    ) {
        guard token == currentToken else { return }
        publish(
            PlaybackTimelineSnapshot(
                identity: currentSnapshot.identity,
                positionSeconds: positionSeconds,
                durationSeconds: currentSnapshot.durationSeconds,
                rate: currentSnapshot.rate,
                state: currentSnapshot.state,
                discontinuityGeneration: nextGeneration()
            )
        )
    }

    package func markFailed(token: PlaybackTimelineItemToken) {
        update(token: token, rate: 0, state: .failed)
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
                discontinuityGeneration: nextGeneration()
            )
        )
    }

    private func nextGeneration() -> UInt64 {
        currentSnapshot.discontinuityGeneration &+ 1
    }

    private func publish(_ snapshot: PlaybackTimelineSnapshot) {
        guard snapshot != currentSnapshot else { return }
        currentSnapshot = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }
}
