import Foundation

public struct LabTelemetryTotals: Sendable, Equatable {
    public var generated: Int
    public var admitted: Int
    public var dropped: Int

    public init(generated: Int, admitted: Int, dropped: Int) {
        self.generated = generated
        self.admitted = admitted
        self.dropped = dropped
    }
}

public struct LabFrameTelemetrySnapshot: Sendable, Equatable {
    public var observedFramesPerSecond: Double
    public var targetFramesPerSecond: Double
    public var missedIntervals: Int
    public var longestIntervalMilliseconds: Double
    public var generatedPerSecond: Double
    public var admittedPerSecond: Double
    public var droppedPerSecond: Double
    public var sampledFrameIntervals: Int

    public init(
        observedFramesPerSecond: Double,
        targetFramesPerSecond: Double,
        missedIntervals: Int,
        longestIntervalMilliseconds: Double,
        generatedPerSecond: Double,
        admittedPerSecond: Double,
        droppedPerSecond: Double,
        sampledFrameIntervals: Int
    ) {
        self.observedFramesPerSecond = observedFramesPerSecond
        self.targetFramesPerSecond = targetFramesPerSecond
        self.missedIntervals = missedIntervals
        self.longestIntervalMilliseconds = longestIntervalMilliseconds
        self.generatedPerSecond = generatedPerSecond
        self.admittedPerSecond = admittedPerSecond
        self.droppedPerSecond = droppedPerSecond
        self.sampledFrameIntervals = sampledFrameIntervals
    }

    public static let zero = LabFrameTelemetrySnapshot(
        observedFramesPerSecond: 0,
        targetFramesPerSecond: 0,
        missedIntervals: 0,
        longestIntervalMilliseconds: 0,
        generatedPerSecond: 0,
        admittedPerSecond: 0,
        droppedPerSecond: 0,
        sampledFrameIntervals: 0
    )
}

public struct LabFrameTelemetryAccumulator: Sendable {
    private let publishInterval: Double
    private var previousTimestamp: Double?
    private var windowStartTimestamp: Double?
    private var startingTotals: LabTelemetryTotals?
    private var sampledFrameIntervals = 0
    private var targetDurationTotal = 0.0
    private var missedIntervals = 0
    private var longestInterval = 0.0

    public init(publishInterval: Double = 1) {
        precondition(publishInterval.isFinite && publishInterval > 0)
        self.publishInterval = publishInterval
    }

    public mutating func record(
        timestamp: Double,
        targetDuration: Double,
        totals: LabTelemetryTotals
    ) -> LabFrameTelemetrySnapshot? {
        guard timestamp.isFinite,
            targetDuration.isFinite,
            targetDuration > 0
        else {
            return nil
        }
        guard let previousTimestamp,
            let windowStartTimestamp,
            let startingTotals,
            timestamp > previousTimestamp
        else {
            beginWindow(timestamp: timestamp, totals: totals)
            return nil
        }

        let frameInterval = timestamp - previousTimestamp
        self.previousTimestamp = timestamp
        sampledFrameIntervals += 1
        targetDurationTotal += targetDuration
        longestInterval = max(longestInterval, frameInterval)
        missedIntervals = addingClamped(
            missedIntervals,
            missedCount(
                frameInterval: frameInterval,
                targetDuration: targetDuration
            )
        )

        let elapsed = timestamp - windowStartTimestamp
        guard elapsed >= publishInterval else { return nil }

        let snapshot = LabFrameTelemetrySnapshot(
            observedFramesPerSecond: Double(sampledFrameIntervals) / elapsed,
            targetFramesPerSecond: targetDurationTotal > 0
                ? Double(sampledFrameIntervals) / targetDurationTotal
                : 0,
            missedIntervals: missedIntervals,
            longestIntervalMilliseconds: longestInterval * 1_000,
            generatedPerSecond: rate(
                current: totals.generated,
                starting: startingTotals.generated,
                elapsed: elapsed
            ),
            admittedPerSecond: rate(
                current: totals.admitted,
                starting: startingTotals.admitted,
                elapsed: elapsed
            ),
            droppedPerSecond: rate(
                current: totals.dropped,
                starting: startingTotals.dropped,
                elapsed: elapsed
            ),
            sampledFrameIntervals: sampledFrameIntervals
        )
        beginWindow(timestamp: timestamp, totals: totals)
        return snapshot
    }

    public mutating func reset() {
        previousTimestamp = nil
        windowStartTimestamp = nil
        startingTotals = nil
        sampledFrameIntervals = 0
        targetDurationTotal = 0
        missedIntervals = 0
        longestInterval = 0
    }

    private mutating func beginWindow(
        timestamp: Double,
        totals: LabTelemetryTotals
    ) {
        previousTimestamp = timestamp
        windowStartTimestamp = timestamp
        startingTotals = totals
        sampledFrameIntervals = 0
        targetDurationTotal = 0
        missedIntervals = 0
        longestInterval = 0
    }

    private func missedCount(
        frameInterval: Double,
        targetDuration: Double
    ) -> Int {
        let ratio = frameInterval / targetDuration
        guard ratio.isFinite else { return Int.max }
        let rounded = ratio.rounded()
        guard rounded > 1 else { return 0 }
        guard rounded < Double(Int.max) else { return Int.max }
        return Int(rounded) - 1
    }

    private func addingClamped(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }

    private func rate(current: Int, starting: Int, elapsed: Double) -> Double {
        Double(max(current - starting, 0)) / elapsed
    }
}
