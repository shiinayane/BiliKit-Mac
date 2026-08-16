import BiliApplication

public struct LabPlaybackState: Sendable, Equatable {
    public private(set) var positionSeconds = 0.0
    public private(set) var discontinuityGeneration: UInt64 = 1
    public private(set) var isPlaying = false
    public private(set) var scenarioStartSeconds = 0.0

    public init() {}

    public mutating func advance(by elapsedSeconds: Double) {
        guard isPlaying, elapsedSeconds.isFinite, elapsedSeconds > 0 else { return }
        positionSeconds += elapsedSeconds
    }

    public mutating func advance(to logicalPositionSeconds: Double) {
        guard isPlaying,
            logicalPositionSeconds.isFinite,
            logicalPositionSeconds >= positionSeconds
        else {
            return
        }
        positionSeconds = logicalPositionSeconds
    }

    public mutating func play() {
        isPlaying = true
    }

    public mutating func pause() {
        isPlaying = false
    }

    public mutating func reset(play: Bool) {
        discontinuityGeneration &+= 1
        positionSeconds = 0
        scenarioStartSeconds = 0
        isPlaying = play
    }

    public mutating func seekForward(by seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        discontinuityGeneration &+= 1
        positionSeconds += seconds
        scenarioStartSeconds = positionSeconds
    }

    public func snapshot(identity: PlaybackItemIdentity) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: positionSeconds,
            durationSeconds: nil,
            rate: isPlaying ? 1 : 0,
            state: isPlaying ? .playing : .paused,
            discontinuityGeneration: discontinuityGeneration
        )
    }
}
