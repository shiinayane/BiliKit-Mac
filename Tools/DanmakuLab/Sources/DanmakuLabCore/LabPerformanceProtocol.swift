import BiliDanmaku
import Foundation

public struct LabPerformancePresetID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty)
        self.rawValue = rawValue
    }
}

public struct LabPerformancePreset: Identifiable, Sendable, Equatable {
    public let id: LabPerformancePresetID
    public let version: Int
    public let displayName: String
    public let scenario: LabScenario
    public let seed: UInt64
    public let eventRate: Double
    public let burstSize: Int
    public let canvasSize: CGSize
    public let requiredBackingScale: Double
    public let warmupSeconds: Double
    public let measurementSeconds: Double
    public let repetitions: Int
    public let logicalTicksPerSecond: Int

    public init(
        id: LabPerformancePresetID,
        version: Int,
        displayName: String,
        scenario: LabScenario,
        seed: UInt64,
        eventRate: Double,
        burstSize: Int,
        canvasSize: CGSize,
        requiredBackingScale: Double,
        warmupSeconds: Double,
        measurementSeconds: Double,
        repetitions: Int,
        logicalTicksPerSecond: Int = 30
    ) {
        precondition(version > 0)
        precondition(!displayName.isEmpty)
        precondition(canvasSize.width > 0 && canvasSize.height > 0)
        precondition(
            requiredBackingScale.isFinite && requiredBackingScale > 0
        )
        precondition(warmupSeconds.isFinite && warmupSeconds > 0)
        precondition(
            measurementSeconds.isFinite && measurementSeconds > 0
        )
        precondition(repetitions > 0)
        precondition(logicalTicksPerSecond > 0)
        self.id = id
        self.version = version
        self.displayName = displayName
        self.scenario = scenario
        self.seed = seed
        self.eventRate = min(
            max(eventRate, LabScenarioPlan.eventRateRange.lowerBound),
            LabScenarioPlan.eventRateRange.upperBound
        )
        self.burstSize = min(
            max(burstSize, LabScenarioPlan.burstSizeRange.lowerBound),
            LabScenarioPlan.burstSizeRange.upperBound
        )
        self.canvasSize = canvasSize
        self.requiredBackingScale = requiredBackingScale
        self.warmupSeconds = warmupSeconds
        self.measurementSeconds = measurementSeconds
        self.repetitions = repetitions
        self.logicalTicksPerSecond = logicalTicksPerSecond
    }

    public var catalogIdentity: String {
        "\(id.rawValue)@\(version)"
    }

    public var traceTimeLimitSeconds: Int {
        Int(ceil(warmupSeconds + measurementSeconds + 60))
    }

    public var expectedMeasurementTicks: Int {
        Int((measurementSeconds * Double(logicalTicksPerSecond)).rounded(.down))
    }

    public var expectedGeneratedEvents: Int {
        LabScenarioPlan(
            scenario: scenario,
            seed: seed,
            eventRate: eventRate,
            burstSize: burstSize
        ).scheduledCount(at: measurementSeconds)
    }

    public func matches(_ manifest: LabRunManifest) -> Bool {
        manifest.scenario == scenario
            && manifest.descriptor.id == scenario.catalogID
            && manifest.descriptor.version == 1
            && manifest.seed == seed
            && manifest.eventRate == eventRate
            && manifest.burstSize == burstSize
            && manifest.filter == LabEventFilter()
            && manifest.speedLevel == .three
            && manifest.opacity == 0.9
            && manifest.displayArea == .full
            && manifest.density == .normal
            && manifest.rendererStyle == .production
            && manifest.initialPositionSeconds == 0
            && manifest.descriptor.logicalTicksPerSecond
                == logicalTicksPerSecond
    }
}

public enum LabPerformancePresetCatalog {
    public static let steady80 = LabPerformancePreset(
        id: LabPerformancePresetID(rawValue: "steady-80"),
        version: 1,
        displayName: "Steady 80 events/s",
        scenario: .steady,
        seed: 44,
        eventRate: 80,
        burstSize: 120,
        canvasSize: CGSize(width: 854, height: 480),
        requiredBackingScale: 2,
        warmupSeconds: 5,
        measurementSeconds: 30,
        repetitions: 3
    )

    public static let burst320 = LabPerformancePreset(
        id: LabPerformancePresetID(rawValue: "burst-320"),
        version: 1,
        displayName: "Burst 320",
        scenario: .burst,
        seed: 44,
        eventRate: 80,
        burstSize: 320,
        canvasSize: CGSize(width: 854, height: 480),
        requiredBackingScale: 2,
        warmupSeconds: 5,
        measurementSeconds: 30,
        repetitions: 3
    )

    public static let capacity640 = LabPerformancePreset(
        id: LabPerformancePresetID(rawValue: "capacity-640"),
        version: 1,
        displayName: "Capacity 640",
        scenario: .capacity,
        seed: 44,
        eventRate: 120,
        burstSize: 640,
        canvasSize: CGSize(width: 854, height: 480),
        requiredBackingScale: 2,
        warmupSeconds: 5,
        measurementSeconds: 30,
        repetitions: 3
    )

    public static let all = [steady80, burst320, capacity640]
}

public enum LabPerformanceSamplePollution: Sendable, Hashable {
    case telemetryEnabled
    case rendererMismatch
    case canvasMismatch
    case backingScaleMismatch
    case lifecycleNotRunning
    case runPolluted
    case manifestMismatch
    case incompleteLogicalWorkload
    case generatedWorkloadMismatch
    case surfaceChangedDuringMeasurement
}

public enum LabPerformanceContractFailure: Sendable, Hashable {
    case generatorOverflow
    case generatedAccountingMismatch
    case presentationAccountingMismatch
    case activeHardCapExceeded
    case performanceBacklogExceeded
}

public enum LabPerformanceSampleDisposition: Sendable, Equatable {
    case polluted
    case revise
    case eligibleForTraceReview
}

public struct LabPerformanceRunEvidence: Sendable, Equatable {
    public let attemptID: UUID
    public let presetIdentity: String
    public let logicalTicksProcessed: Int
    public let expectedLogicalTicks: Int
    public let generatedEvents: Int
    public let expectedGeneratedEvents: Int
    public let surfaceChangedDuringMeasurement: Bool
    public let manifestMatchesPreset: Bool
    public let terminalPollution: LabRunPollution?
    public let measurementDurationSeconds: Double

    public init(
        attemptID: UUID,
        presetIdentity: String,
        logicalTicksProcessed: Int,
        expectedLogicalTicks: Int,
        generatedEvents: Int,
        expectedGeneratedEvents: Int,
        surfaceChangedDuringMeasurement: Bool,
        manifestMatchesPreset: Bool = true,
        terminalPollution: LabRunPollution? = nil,
        measurementDurationSeconds: Double = 0
    ) {
        self.attemptID = attemptID
        self.presetIdentity = presetIdentity
        self.logicalTicksProcessed = logicalTicksProcessed
        self.expectedLogicalTicks = expectedLogicalTicks
        self.generatedEvents = generatedEvents
        self.expectedGeneratedEvents = expectedGeneratedEvents
        self.surfaceChangedDuringMeasurement = surfaceChangedDuringMeasurement
        self.manifestMatchesPreset = manifestMatchesPreset
        self.terminalPollution = terminalPollution
        self.measurementDurationSeconds = max(
            measurementDurationSeconds.isFinite ? measurementDurationSeconds : 0,
            0
        )
    }
}

public struct LabPerformanceSampleAssessment: Sendable, Equatable {
    public let disposition: LabPerformanceSampleDisposition
    public let pollution: [LabPerformanceSamplePollution]
    public let contractFailures: [LabPerformanceContractFailure]

    public init(
        preset: LabPerformancePreset,
        expectedRendererID: LabRendererID,
        rendererID: LabRendererID,
        telemetryEnabled: Bool,
        surfaceSize: CGSize,
        backingScale: Double,
        lifecycle: LabRunLifecycle,
        statistics: LabStatistics,
        runEvidence: LabPerformanceRunEvidence?
    ) {
        var pollution: [LabPerformanceSamplePollution] = []
        if telemetryEnabled {
            pollution.append(.telemetryEnabled)
        }
        if rendererID != expectedRendererID {
            pollution.append(.rendererMismatch)
        }
        if !Self.matches(surfaceSize, preset.canvasSize) {
            pollution.append(.canvasMismatch)
        }
        if !Self.matches(
            backingScale,
            preset.requiredBackingScale,
            tolerance: 0.01
        ) {
            pollution.append(.backingScaleMismatch)
        }
        let terminalContractFailure: Bool
        if let runEvidence {
            switch runEvidence.terminalPollution {
            case .backlogExceeded, .eventBatchExceeded:
                terminalContractFailure = true
            case .wallClockOverflow, .surfaceChangedDuringMeasurement, nil:
                terminalContractFailure = false
            }
        } else {
            terminalContractFailure = false
        }
        switch lifecycle {
        case .completed:
            break
        case .polluted:
            if !terminalContractFailure {
                pollution.append(.runPolluted)
            }
        case .waitingForSurface, .running, .stopped:
            pollution.append(.lifecycleNotRunning)
        }
        guard let runEvidence else {
            pollution.append(.incompleteLogicalWorkload)
            self.pollution = pollution
            contractFailures = []
            disposition = .polluted
            return
        }
        if runEvidence.presetIdentity != preset.catalogIdentity {
            pollution.append(.manifestMismatch)
        }
        if !runEvidence.manifestMatchesPreset {
            pollution.append(.manifestMismatch)
        }
        let logicalWorkloadIncomplete =
            runEvidence.logicalTicksProcessed != preset.expectedMeasurementTicks
            || runEvidence.expectedLogicalTicks != preset.expectedMeasurementTicks
        if !terminalContractFailure, logicalWorkloadIncomplete {
            pollution.append(.incompleteLogicalWorkload)
        }
        let generatedWorkloadIncomplete =
            runEvidence.generatedEvents != preset.expectedGeneratedEvents
            || runEvidence.expectedGeneratedEvents != preset.expectedGeneratedEvents
        if !terminalContractFailure, generatedWorkloadIncomplete {
            pollution.append(.generatedWorkloadMismatch)
        }
        if runEvidence.surfaceChangedDuringMeasurement {
            pollution.append(.surfaceChangedDuringMeasurement)
        }

        var failures: [LabPerformanceContractFailure] = []
        if statistics.generatorOverflow > 0 {
            failures.append(.generatorOverflow)
        }
        if statistics.generated
            != statistics.filtered + statistics.attempted
        {
            failures.append(.generatedAccountingMismatch)
        }
        if statistics.attempted
            != statistics.admitted + statistics.droppedNoLane
            + statistics.droppedCapacity
        {
            failures.append(.presentationAccountingMismatch)
        }
        if statistics.active
            > DanmakuLaneConfiguration.hardMaximumActiveCount
            || statistics.peakActive
                > DanmakuLaneConfiguration.hardMaximumActiveCount
        {
            failures.append(.activeHardCapExceeded)
        }
        if case .backlogExceeded = runEvidence.terminalPollution {
            failures.append(.performanceBacklogExceeded)
        }

        self.pollution = pollution
        contractFailures = failures
        if !pollution.isEmpty {
            disposition = .polluted
        } else if !failures.isEmpty {
            disposition = .revise
        } else {
            disposition = .eligibleForTraceReview
        }
    }

    private static func matches(
        _ lhs: CGSize,
        _ rhs: CGSize
    ) -> Bool {
        matches(lhs.width, rhs.width, tolerance: 0.5)
            && matches(lhs.height, rhs.height, tolerance: 0.5)
    }

    private static func matches(
        _ lhs: Double,
        _ rhs: Double,
        tolerance: Double
    ) -> Bool {
        lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= tolerance
    }
}
