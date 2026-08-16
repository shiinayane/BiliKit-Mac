import BiliApplication
import BiliDanmaku
import Foundation

public struct LabScenarioDescriptor: Sendable, Equatable {
    public let id: String
    public let version: Int
    public let durationSeconds: Double
    public let logicalTicksPerSecond: Int
    public let maximumTicksPerWallAdvance: Int

    public init(
        id: String,
        version: Int,
        durationSeconds: Double = 300,
        logicalTicksPerSecond: Int = 60,
        maximumTicksPerWallAdvance: Int = 60
    ) {
        precondition(!id.isEmpty)
        precondition(version > 0)
        precondition(durationSeconds.isFinite && durationSeconds > 0)
        precondition(logicalTicksPerSecond > 0)
        precondition(maximumTicksPerWallAdvance > 0)
        self.id = id
        self.version = version
        self.durationSeconds = durationSeconds
        self.logicalTicksPerSecond = logicalTicksPerSecond
        self.maximumTicksPerWallAdvance = maximumTicksPerWallAdvance
    }
}

public enum LabScenarioCatalog {
    public static func descriptor(for scenario: LabScenario) -> LabScenarioDescriptor {
        LabScenarioDescriptor(
            id: scenario.catalogID,
            version: 1,
            durationSeconds: scenario == .capacity ? 60 : 300
        )
    }
}

public struct LabRunManifest: Sendable, Equatable {
    public static let standard = LabRunManifest(
        scenario: .standard,
        seed: 44,
        eventRate: 24,
        burstSize: 120,
        filter: LabEventFilter(),
        speedLevel: .three,
        opacity: 0.9,
        displayArea: .full,
        density: .normal,
        startsPlaying: true
    )

    public let descriptor: LabScenarioDescriptor
    public let scenario: LabScenario
    public let seed: UInt64
    public let eventRate: Double
    public let burstSize: Int
    public let filter: LabEventFilter
    public let speedLevel: DanmakuSpeedLevel
    public let opacity: Double
    public let displayArea: DanmakuDisplayArea
    public let density: DanmakuDensity
    public let rendererStyle: CoreAnimationDanmakuStyle
    public let rendererID: LabRendererID
    public let startsPlaying: Bool
    public let initialPositionSeconds: Double

    public init(
        scenario: LabScenario,
        seed: UInt64,
        eventRate: Double,
        burstSize: Int,
        filter: LabEventFilter,
        speedLevel: DanmakuSpeedLevel,
        opacity: Double,
        displayArea: DanmakuDisplayArea,
        density: DanmakuDensity,
        rendererStyle: CoreAnimationDanmakuStyle = .production,
        rendererID: LabRendererID = .productionCoreAnimation,
        startsPlaying: Bool,
        initialPositionSeconds: Double = 0,
        descriptor: LabScenarioDescriptor? = nil
    ) {
        let plan = LabScenarioPlan(
            scenario: scenario,
            seed: seed,
            eventRate: eventRate,
            burstSize: burstSize,
            startTime: initialPositionSeconds
        )
        let selectedDescriptor = descriptor ?? LabScenarioCatalog.descriptor(for: scenario)
        self.descriptor = selectedDescriptor
        self.scenario = scenario
        self.seed = seed
        self.eventRate = plan.eventRate
        self.burstSize = plan.burstSize
        self.filter = filter
        self.speedLevel = speedLevel
        self.opacity = DanmakuOpacity(opacity)?.value ?? 0.9
        self.displayArea = displayArea
        self.density = density
        self.rendererStyle = rendererStyle
        self.rendererID = rendererID
        self.startsPlaying = startsPlaying
        self.initialPositionSeconds = min(
            plan.startTime,
            selectedDescriptor.durationSeconds
        )
    }

    public var inputSummary: String {
        [
            "\(descriptor.id)@\(descriptor.version)",
            "seed=\(seed)",
            "rate=\(eventRate)",
            "burst=\(burstSize)",
            "modes=\(filter.modeSummary)",
            "sizes=\(filter.sizeSummary)",
            "fontScale=\(rendererStyle.fontScale)",
            "fontWeight=\(rendererStyle.fontWeight.rawValue)",
            "shadowBlur=\(rendererStyle.shadowBlurRadius)",
            "renderer=\(rendererID.rawValue)",
            "start=\(initialPositionSeconds)",
            "duration=\(descriptor.durationSeconds)",
            "tickHz=\(descriptor.logicalTicksPerSecond)",
            "maxTicks=\(descriptor.maximumTicksPerWallAdvance)",
        ].joined(separator: ";")
    }

    public var plan: LabScenarioPlan {
        LabScenarioPlan(
            scenario: scenario,
            scenarioID: descriptor.id,
            scenarioVersion: descriptor.version,
            seed: seed,
            eventRate: eventRate,
            burstSize: burstSize,
            startTime: initialPositionSeconds
        )
    }
}

extension LabEventFilter {
    fileprivate var modeSummary: String {
        "\(showsScrolling ? 1 : 0)\(showsTop ? 1 : 0)\(showsBottom ? 1 : 0)"
    }

    fileprivate var sizeSummary: String {
        "\(showsSmall ? 1 : 0)\(showsStandard ? 1 : 0)\(showsLarge ? 1 : 0)"
    }
}
