import BiliModels
import Foundation

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
public protocol PlaybackTimelineProviding: AnyObject {
    var currentTimelineSnapshot: PlaybackTimelineSnapshot { get }
    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot>
}

@MainActor
public protocol PlaybackControlling: AnyObject {
    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity
    ) async throws
    func pause()
    func stop()
}

package struct PlaybackTimelineItemToken: Sendable, Equatable {
    fileprivate let value: UUID
}

@MainActor
package final class PlaybackTimelineStore {
    package private(set) var currentSnapshot = PlaybackTimelineSnapshot.idle
    package var subscriberCount: Int { continuations.count }

    private var currentToken: PlaybackTimelineItemToken?
    private var continuations: [
        UUID: AsyncStream<PlaybackTimelineSnapshot>.Continuation
    ] = [:]

    package init() {}

    deinit {
        continuations.values.forEach { $0.finish() }
    }

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
        publish(
            PlaybackTimelineSnapshot(
                identity: currentSnapshot.identity,
                positionSeconds: 0,
                durationSeconds: durationSeconds,
                rate: 0,
                state: .ready,
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
        continuations.values.forEach { $0.yield(snapshot) }
    }
}
