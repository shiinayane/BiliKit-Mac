import BiliModels
import Foundation

public enum LabScenario: String, CaseIterable, Identifiable, Sendable {
    case standard = "Standard scrolling"
    case mixed = "Mixed modes"
    case typography = "18 / 25 / 36 pt"
    case contentEdges = "Text and symbols"
    case palette = "Color palette"
    case steady = "Steady stream"
    case burst = "Burst"
    case capacity = "Capacity pressure"

    public var id: Self { self }

    public var catalogID: String {
        switch self {
        case .standard: "visual-standard"
        case .mixed: "mixed-modes-scripts"
        case .typography: "typography"
        case .contentEdges: "long-text-emoji-glyphs"
        case .palette: "color-palette"
        case .steady: "steady-stream"
        case .burst: "burst"
        case .capacity: "capacity"
        }
    }

    public var usesBursts: Bool {
        self == .burst || self == .capacity
    }
}

public struct LabScenarioPlan: Sendable, Equatable {
    public static let eventRateRange = 1.0...120.0
    public static let burstSizeRange = 1...640
    public static let maximumEventsPerTick = 640

    public let scenario: LabScenario
    public let scenarioID: String
    public let scenarioVersion: Int
    public let seed: UInt64
    public let eventRate: Double
    public let burstSize: Int
    public let startTime: Double

    public init(
        scenario: LabScenario,
        scenarioID: String? = nil,
        scenarioVersion: Int = 1,
        seed: UInt64,
        eventRate: Double,
        burstSize: Int,
        startTime: Double = 0
    ) {
        self.scenario = scenario
        self.scenarioID = scenarioID ?? scenario.catalogID
        self.scenarioVersion = max(scenarioVersion, 1)
        self.seed = seed
        self.eventRate = min(
            max(eventRate, Self.eventRateRange.lowerBound),
            Self.eventRateRange.upperBound
        )
        self.burstSize = min(
            max(burstSize, Self.burstSizeRange.lowerBound),
            Self.burstSizeRange.upperBound
        )
        self.startTime = max(startTime.isFinite ? startTime : 0, 0)
    }

    public func scheduledCount(at position: Double) -> Int {
        guard position.isFinite, position >= startTime else { return 0 }
        let elapsed = position - startTime
        if scenario.usesBursts {
            let period = scenario == .capacity ? 1.0 : 2.0
            let groupCount = Int(floor(elapsed / period)) + 1
            let result = groupCount.multipliedReportingOverflow(by: burstSize)
            return result.overflow ? Int.max : result.partialValue
        }
        let rawCount = floor(elapsed * eventRate) + 1
        return rawCount >= Double(Int.max) ? Int.max : Int(rawCount)
    }

    public func scheduledTime(for index: Int) -> Double {
        guard index >= 0 else { return startTime }
        if scenario.usesBursts {
            let period = scenario == .capacity ? 1.0 : 2.0
            return startTime + Double(index / burstSize) * period
        }
        return startTime + Double(index) / eventRate
    }

    public func event(at index: Int) -> DanmakuEvent {
        var random = SplitMix64(seed: seed &+ UInt64(max(index, 0)))
        let mode = mode(for: index, random: &random)
        let fontSize = fontSize(for: index, random: &random)
        let text = text(for: index, random: &random)
        let color = color(for: index, random: &random)
        return DanmakuEvent(
            id: "lab/\(scenarioID)/v\(scenarioVersion)/\(seed)/\(index)",
            timeSeconds: scheduledTime(for: index),
            mode: mode,
            text: text,
            fontSize: fontSize,
            colorRGB: color,
            weight: 0
        )
    }

    private func mode(for index: Int, random: inout SplitMix64) -> DanmakuPresentationMode {
        switch scenario {
        case .standard, .typography, .contentEdges, .palette, .steady:
            return .scrolling
        case .mixed, .burst, .capacity:
            return Self.modes[
                (index + random.index(upperBound: Self.modes.count)) % Self.modes.count
            ]
        }
    }

    private func fontSize(for index: Int, random: inout SplitMix64) -> Double {
        switch scenario {
        case .typography:
            return Self.fontSizes[index % Self.fontSizes.count]
        case .capacity:
            return Self.fontSizes[random.index(upperBound: Self.fontSizes.count)]
        default:
            return index.isMultiple(of: 11) ? 36 : (index.isMultiple(of: 5) ? 18 : 25)
        }
    }

    private func text(for index: Int, random: inout SplitMix64) -> String {
        let source: [String]
        switch scenario {
        case .contentEdges:
            source = Self.edgeTexts
        case .typography:
            source = ["字号边界 18", "标准字号 25", "合法最大字号 36"]
        case .palette:
            source = ["多颜色", "Color palette", "RGB 0123456789"]
        case .capacity:
            source = ["容量压力", "CAP", "高密度"]
        default:
            source = Self.standardTexts
        }
        return source[(index + random.index(upperBound: source.count)) % source.count]
    }

    private func color(for index: Int, random: inout SplitMix64) -> UInt32 {
        if scenario == .palette || scenario == .capacity {
            return Self.colors[
                (index + random.index(upperBound: Self.colors.count)) % Self.colors.count
            ]
        }
        return Self.colors[
            index.isMultiple(of: 7) ? random.index(upperBound: Self.colors.count) : 0
        ]
    }

    private static let modes: [DanmakuPresentationMode] = [.scrolling, .top, .bottom]
    private static let fontSizes: [Double] = [18, 25, 36]
    private static let colors: [UInt32] = [
        0xFF_FF_FF, 0xFF_5A_5F, 0xFF_D1_66, 0x06_D6_A0,
        0x11_8A_B2, 0x73_66_FF, 0xFF_70_AA, 0x10_10_10,
    ]
    private static let standardTexts = [
        "合成弹幕", "Production Core Animation", "Deterministic replay",
        "Hello, Danmaku Lab", "0123456789", "Resize keeps generating",
    ]
    private static let edgeTexts = [
        "短", "这是一条用于验证超长 CJK 排版与滚动边界的确定性合成弹幕，不包含任何真实评论正文",
        "The quick brown fox jumps over 0123456789", "😀🚀✨🧪🎬",
        "【】「」〈〉—…·！？＠＃％＆＊＋＝", "ASCII <>[]{} /\\ | ~ ^ _",
    ]
}

public struct LabEventFilter: Sendable, Equatable {
    public var showsScrolling = true
    public var showsTop = true
    public var showsBottom = true
    public var showsSmall = true
    public var showsStandard = true
    public var showsLarge = true

    public init() {}

    public func allows(_ event: DanmakuEvent) -> Bool {
        let modeAllowed =
            switch event.mode {
            case .scrolling: showsScrolling
            case .top: showsTop
            case .bottom: showsBottom
            }
        let sizeAllowed =
            switch event.fontSize {
            case 18: showsSmall
            case 36: showsLarge
            default: showsStandard
            }
        return modeAllowed && sizeAllowed
    }
}

private struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func index(upperBound: Int) -> Int {
        guard upperBound > 1 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }
}
