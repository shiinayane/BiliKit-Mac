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

public enum DanmakuPreparationRejectionReason: Sendable, Equatable {
    case capacity
    case invalidInput
    case oversized
    case cancelled
}

public enum DanmakuPreparationResult: Sendable, Equatable {
    case ready(DanmakuTextMetrics)
    case rejected(DanmakuPreparationRejectionReason)
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
        lengthCoefficient: Double = 0.3,
        maximumLengthBonus: Double = .infinity,
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
        lengthCoefficient = 0.3
        maximumLengthBonus = .infinity
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
                !maximumLengthBonus.isNaN,
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

    /// 准备完成回调必须返回 MainActor；controller 只会在 `.ready` 后执行 lane 准入。
    func prepare(
        _ event: DanmakuEvent,
        preparationID: UInt64,
        generation: UInt64,
        backingScale: Double,
        completion:
            @escaping @MainActor @Sendable (
                DanmakuPreparationResult
            ) -> Void
    )

    @discardableResult
    func renderPrepared(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        generation: UInt64
    ) -> Bool
    func discardPreparation(preparationID: UInt64)
    func cancelPendingPreparations()
    func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    )
}

extension DanmakuRenderingBackend {
    /// 旧 Lab/test backend 的同步兼容桥。
    ///
    /// 生产 renderer 覆盖此方法并在后台准备纹理。
    public func prepare(
        _ event: DanmakuEvent,
        preparationID: UInt64,
        generation: UInt64,
        backingScale: Double,
        completion:
            @escaping @MainActor @Sendable (
                DanmakuPreparationResult
            ) -> Void
    ) {
        let metrics = measure(event)
        completion(
            metrics.width > 0 && metrics.height > 0
                ? .ready(metrics) : .rejected(.invalidInput)
        )
    }

    @discardableResult
    public func renderPrepared(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        generation: UInt64
    ) -> Bool {
        render(placement)
        return true
    }

    public func discardPreparation(preparationID: UInt64) {}

    public func cancelPendingPreparations() {}

    public func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    ) {
        updateSurfaceSize(width: width, height: height)
    }
}
