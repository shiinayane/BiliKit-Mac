import Foundation

public enum LabRunPollution: Sendable, Equatable {
    case wallClockOverflow
    case backlogExceeded(pendingTicks: Int, maximumTicks: Int)
    case eventBatchExceeded(pendingEvents: Int, maximumEvents: Int)
    case surfaceChangedDuringMeasurement
}

public enum LabLogicalAdvanceState: Sendable, Equatable {
    case running
    case completed
    case polluted(LabRunPollution)
}

public struct LabLogicalAdvance: Sendable, Equatable {
    public let tickOrdinals: Range<Int>
    public let state: LabLogicalAdvanceState

    public init(
        tickOrdinals: Range<Int>,
        state: LabLogicalAdvanceState
    ) {
        self.tickOrdinals = tickOrdinals
        self.state = state
    }
}

public struct LabLogicalClock: Sendable, Equatable {
    public let ticksPerSecond: Int
    public let maximumTicksPerWallAdvance: Int
    public let durationSeconds: Double

    public private(set) var tickOrdinal: Int
    public private(set) var isPlaying: Bool

    private let nanosecondsPerTick: Int64
    private let finalTickOrdinal: Int
    private var accumulatedWallNanoseconds: Int64 = 0

    public init(
        ticksPerSecond: Int,
        maximumTicksPerWallAdvance: Int,
        durationSeconds: Double,
        initialPositionSeconds: Double = 0,
        isPlaying: Bool
    ) {
        precondition(ticksPerSecond > 0)
        precondition(maximumTicksPerWallAdvance > 0)
        precondition(durationSeconds.isFinite && durationSeconds > 0)
        self.ticksPerSecond = ticksPerSecond
        self.maximumTicksPerWallAdvance = maximumTicksPerWallAdvance
        self.durationSeconds = durationSeconds
        nanosecondsPerTick = Int64(1_000_000_000 / ticksPerSecond)
        finalTickOrdinal = Int((durationSeconds * Double(ticksPerSecond)).rounded(.down))
        tickOrdinal = min(
            max(
                Int(
                    (max(
                        initialPositionSeconds.isFinite
                            ? initialPositionSeconds : 0,
                        0
                    ) * Double(ticksPerSecond)).rounded(.down)
                ),
                0
            ),
            finalTickOrdinal
        )
        self.isPlaying = isPlaying && tickOrdinal < finalTickOrdinal
    }

    public var positionSeconds: Double {
        Double(tickOrdinal) / Double(ticksPerSecond)
    }

    public mutating func setPlaying(_ playing: Bool) {
        isPlaying = playing && tickOrdinal < finalTickOrdinal
        accumulatedWallNanoseconds = 0
    }

    public mutating func advance(wallNanoseconds: Int64) -> LabLogicalAdvance {
        guard isPlaying, wallNanoseconds > 0 else {
            return LabLogicalAdvance(
                tickOrdinals: tickOrdinal..<tickOrdinal,
                state: tickOrdinal >= finalTickOrdinal ? .completed : .running
            )
        }
        let sum = accumulatedWallNanoseconds.addingReportingOverflow(wallNanoseconds)
        guard !sum.overflow else {
            isPlaying = false
            return LabLogicalAdvance(
                tickOrdinals: tickOrdinal..<tickOrdinal,
                state: .polluted(.wallClockOverflow)
            )
        }
        accumulatedWallNanoseconds = sum.partialValue
        let pendingTicks64 = accumulatedWallNanoseconds / nanosecondsPerTick
        guard pendingTicks64 <= Int64(maximumTicksPerWallAdvance) else {
            isPlaying = false
            let pendingTicks =
                pendingTicks64 > Int64(Int.max)
                ? Int.max : Int(pendingTicks64)
            return LabLogicalAdvance(
                tickOrdinals: tickOrdinal..<tickOrdinal,
                state: .polluted(
                    .backlogExceeded(
                        pendingTicks: pendingTicks,
                        maximumTicks: maximumTicksPerWallAdvance
                    )
                )
            )
        }
        guard pendingTicks64 > 0 else {
            return LabLogicalAdvance(
                tickOrdinals: tickOrdinal..<tickOrdinal,
                state: .running
            )
        }

        accumulatedWallNanoseconds %= nanosecondsPerTick
        let requestedEnd = tickOrdinal + Int(pendingTicks64)
        let end = min(requestedEnd, finalTickOrdinal)
        let ticks = tickOrdinal..<end
        tickOrdinal = end
        if tickOrdinal >= finalTickOrdinal {
            isPlaying = false
            accumulatedWallNanoseconds = 0
            return LabLogicalAdvance(tickOrdinals: ticks, state: .completed)
        }
        return LabLogicalAdvance(tickOrdinals: ticks, state: .running)
    }
}
