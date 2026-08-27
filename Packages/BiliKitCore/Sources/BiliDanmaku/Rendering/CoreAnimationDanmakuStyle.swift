import Foundation

public enum CoreAnimationDanmakuFontWeight:
    String,
    CaseIterable,
    Sendable,
    Equatable,
    Hashable
{
    case regular
    case medium
    case semibold
    case bold
}

/// Core Animation renderer 的有界视觉输入。
///
/// 该类型只描述产品需要稳定复用的文本视觉语义，不暴露 `CATextLayer`、Core Text attribute
/// 或动画实现细节。App 始终使用 `production`；开发工具可以为单轮 renderer 提供不同值。
public struct CoreAnimationDanmakuStyle: Sendable, Equatable {
    public static let fontScaleRange = 0.5...1.5
    public static let shadowBlurRadiusRange = 0.0...4.0
    public static let production = CoreAnimationDanmakuStyle()

    public let fontScale: Double
    public let fontWeight: CoreAnimationDanmakuFontWeight
    public let shadowBlurRadius: Double

    public init(
        fontScale: Double = 1,
        fontWeight: CoreAnimationDanmakuFontWeight = .semibold,
        shadowBlurRadius: Double = 2.5
    ) {
        self.fontScale = Self.normalized(
            fontScale,
            fallback: 1,
            range: Self.fontScaleRange
        )
        self.fontWeight = fontWeight
        self.shadowBlurRadius = Self.normalized(
            shadowBlurRadius,
            fallback: 2.5,
            range: Self.shadowBlurRadiusRange
        )
    }

    private static func normalized(
        _ value: Double,
        fallback: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
