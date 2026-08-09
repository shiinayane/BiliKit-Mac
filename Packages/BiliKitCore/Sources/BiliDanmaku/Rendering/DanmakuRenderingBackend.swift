import BiliApplication
import BiliModels
import Foundation

public struct DanmakuTextMetrics: Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct DanmakuRendererDurations: Sendable, Equatable {
    public let scrollingSeconds: Double
    public let fixedSeconds: Double

    public init(
        scrollingSeconds: Double = 8,
        fixedSeconds: Double = 4
    ) {
        self.scrollingSeconds = scrollingSeconds
        self.fixedSeconds = fixedSeconds
    }

    func duration(for mode: DanmakuPresentationMode) -> Double {
        switch mode {
        case .scrolling: scrollingSeconds
        case .top, .bottom: fixedSeconds
        }
    }
}

public struct DanmakuMotionPolicy: Sendable, Equatable {
    public let basePointSpeed: Double
    public let lengthReferenceWidth: Double
    public let lengthCoefficient: Double
    public let maximumLengthBonus: Double
    public let minimumScrollingSeconds: Double
    public let maximumScrollingSeconds: Double
    public let fixedSeconds: Double

    private let fixedScrollingSeconds: Double?

    public init(
        basePointSpeed: Double = 130,
        lengthReferenceWidth: Double = 960,
        lengthCoefficient: Double = 0.25,
        maximumLengthBonus: Double = 0.45,
        minimumScrollingSeconds: Double = 1.5,
        maximumScrollingSeconds: Double = 60,
        fixedSeconds: Double = 4
    ) {
        self.basePointSpeed = basePointSpeed
        self.lengthReferenceWidth = lengthReferenceWidth
        self.lengthCoefficient = lengthCoefficient
        self.maximumLengthBonus = maximumLengthBonus
        self.minimumScrollingSeconds = minimumScrollingSeconds
        self.maximumScrollingSeconds = maximumScrollingSeconds
        self.fixedSeconds = fixedSeconds
        self.fixedScrollingSeconds = nil
    }

    init(fixedDurations: DanmakuRendererDurations) {
        basePointSpeed = 130
        lengthReferenceWidth = 960
        lengthCoefficient = 0.25
        maximumLengthBonus = 0.45
        minimumScrollingSeconds = 4
        maximumScrollingSeconds = 30
        fixedSeconds = fixedDurations.fixedSeconds
        fixedScrollingSeconds = fixedDurations.scrollingSeconds
    }

    func duration(
        for mode: DanmakuPresentationMode,
        textWidth: Double,
        surfaceWidth: Double,
        speedLevel: DanmakuSpeedLevel
    ) -> Double {
        switch mode {
        case .top, .bottom:
            return fixedSeconds
        case .scrolling:
            if let fixedScrollingSeconds {
                return fixedScrollingSeconds
            }
            guard basePointSpeed.isFinite,
                basePointSpeed > 0,
                lengthReferenceWidth.isFinite,
                lengthReferenceWidth > 0,
                lengthCoefficient.isFinite,
                lengthCoefficient >= 0,
                maximumLengthBonus.isFinite,
                maximumLengthBonus >= 0,
                minimumScrollingSeconds.isFinite,
                minimumScrollingSeconds > 0,
                maximumScrollingSeconds.isFinite,
                maximumScrollingSeconds >= minimumScrollingSeconds,
                textWidth.isFinite,
                textWidth > 0,
                surfaceWidth.isFinite,
                surfaceWidth > 0
            else {
                return .nan
            }
            let lengthBonus = min(
                lengthCoefficient * textWidth / lengthReferenceWidth,
                maximumLengthBonus
            )
            let mediaPointSpeed =
                basePointSpeed
                * speedMultiplier(for: speedLevel)
                * (1 + lengthBonus)
            let rawDuration = (surfaceWidth + textWidth) / mediaPointSpeed
            return min(
                max(rawDuration, minimumScrollingSeconds),
                maximumScrollingSeconds
            )
        }
    }

    private func speedMultiplier(for level: DanmakuSpeedLevel) -> Double {
        switch level {
        case .one: 90 / 130
        case .two: 110 / 130
        case .three: 1
        case .four: 155 / 130
        case .five: 185 / 130
        }
    }
}

@MainActor
public protocol DanmakuRenderingBackendDelegate: AnyObject {
    func rendererDidFinish(eventID: String)
}

@MainActor
/// Renderer 的最小平台 port。
///
/// `clearAll` 只移除活动对象；`stop` 还把播放速率归零。尺寸变化只更新 surface geometry；
/// 已有对象保持自己的运动快照，新对象使用新尺寸。
public protocol DanmakuRenderingBackend: AnyObject {
    var delegate: (any DanmakuRenderingBackendDelegate)? { get set }

    func measure(_ event: DanmakuEvent) -> DanmakuTextMetrics
    func render(_ placement: DanmakuLanePlacement)
    func remove(eventID: String)
    func clearAll()
    func setPlaybackRate(_ rate: Double)
    func setOpacity(_ opacity: DanmakuOpacity)
    func updateSurfaceSize(width: Double, height: Double)
    func stop()
}
