import BiliModels
import Foundation

public struct DanmakuLaneConfiguration: Sendable, Equatable {
    public static let hardMaximumActiveCount = 640

    public let surfaceWidth: Double
    public let surfaceHeight: Double
    public let laneHeight: Double
    public let minimumHorizontalGap: Double
    public let maximumActiveCount: Int
    public let displayAreaFraction: Double

    public init(
        surfaceWidth: Double,
        surfaceHeight: Double,
        laneHeight: Double,
        minimumHorizontalGap: Double,
        maximumActiveCount: Int,
        displayAreaFraction: Double
    ) {
        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = surfaceHeight
        self.laneHeight = laneHeight
        self.minimumHorizontalGap = minimumHorizontalGap
        self.maximumActiveCount = maximumActiveCount
        self.displayAreaFraction = displayAreaFraction
    }

    var isValid: Bool {
        let values = [
            surfaceWidth,
            surfaceHeight,
            laneHeight,
            minimumHorizontalGap,
            displayAreaFraction,
        ]
        guard values.allSatisfy(\.isFinite),
              surfaceWidth > 0,
              surfaceHeight > 0,
              laneHeight > 0,
              minimumHorizontalGap >= 0,
              maximumActiveCount > 0,
              maximumActiveCount <= Self.hardMaximumActiveCount
        else {
            return false
        }
        return displayAreaFraction >= 0 && displayAreaFraction <= 1
    }
}

public struct DanmakuLaneRequest: Sendable, Equatable {
    public let event: DanmakuEvent
    public let width: Double
    public let height: Double
    public let durationSeconds: Double

    public init(
        event: DanmakuEvent,
        width: Double,
        height: Double,
        durationSeconds: Double
    ) {
        self.event = event
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
    }

    var isValid: Bool {
        width.isFinite
            && width > 0
            && height.isFinite
            && height > 0
            && durationSeconds.isFinite
            && durationSeconds > 0
            && event.timeSeconds.isFinite
    }
}

public struct DanmakuLanePlacement: Sendable, Equatable {
    public let request: DanmakuLaneRequest
    public let laneIndex: Int
    public let originY: Double
    public let admittedAtSeconds: Double
    public let expiresAtSeconds: Double
}

public enum DanmakuLaneDropReason: Error, Sendable, Equatable {
    case capacity
    case noLane
    case invalidRequest
}

public struct DanmakuLaneDropCounts: Sendable, Equatable {
    public private(set) var capacity = 0
    public private(set) var noLane = 0
    public private(set) var invalidRequest = 0

    public init() {}

    public var total: Int { capacity + noLane + invalidRequest }

    mutating func record(_ reason: DanmakuLaneDropReason) {
        switch reason {
        case .capacity: capacity += 1
        case .noLane: noLane += 1
        case .invalidRequest: invalidRequest += 1
        }
    }
}

public struct DanmakuLaneAdmission: Sendable, Equatable {
    public let expired: [DanmakuLanePlacement]
    public let admitted: [DanmakuLanePlacement]
    public let dropCounts: DanmakuLaneDropCounts
}
