import BiliApplication
import BiliModels
import Foundation

/// 准备好的弹幕纹理在 point 下的尺寸（含描边与阴影留白），用于车道准入与运动时长。
public struct DanmakuTextMetrics: Sendable, Equatable {
    public let width: Double
    public let height: Double
}

/// 纹理准备被拒绝的原因。
///
/// `capacity`：未完成请求已满、准备 ID 重复，或被内存压力清掉；`invalidInput`：文本为空或过长、
/// 字号或 backing scale 无效；`oversized`：栅格化失败或纹理超出尺寸与字节上限。
public enum DanmakuPreparationRejectionReason: Sendable, Equatable {
    case capacity
    case invalidInput
    case oversized
}

/// 一次安装的结果：是否上屏，以及为腾出纹理字节而被移除的弹幕。
public struct DanmakuInstallResult: Sendable, Equatable {
    static let notInstalled = DanmakuInstallResult(isInstalled: false, evictedEventIDs: [])

    public let isInstalled: Bool
    public let evictedEventIDs: [String]
}

/// 纹理准备的结果：就绪时带纹理尺寸，否则带拒绝原因。
public enum DanmakuPreparationResult: Sendable, Equatable {
    case ready(DanmakuTextMetrics)
    case rejected(DanmakuPreparationRejectionReason)
}

/// 弹幕运动的唯一策略来源：时长、滚动行程与滚动速度；基准速度、长度加成与上下限都是产品固定值。
///
/// 速度只取决于档位与文字宽度、与画面宽度无关，时长 = 行程 / 速度。取景框模型依赖这一点：
/// 滚动弹幕相对右边缘的轨迹与窗口宽度无关，按规划画布排出的表裁成窄窗口，与直接按窄窗口排的运动一致。
/// 上下限在屏幕级画布上不触发（最慢档、短文字要宽过约 5400pt 才碰到 60 秒上限）；改成随画面宽度变化的
/// 速度会破坏取景框，见 docs/ARCHITECTURE.md「弹幕」。
enum DanmakuMotionPolicy {
    static let basePointSpeed = 130.0
    static let lengthReferenceWidth = 960.0
    static let lengthCoefficient = 0.3
    static let minimumScrollingSeconds = 1.5
    static let maximumScrollingSeconds = 60.0
    static let fixedSeconds = 4.0

    static func duration(
        for mode: DanmakuPresentationMode,
        textWidth: Double,
        surfaceWidth: Double,
        speedLevel: DanmakuSpeedLevel
    ) -> Double {
        switch mode {
        case .top, .bottom:
            return fixedSeconds
        case .scrolling:
            guard textWidth.isFinite,
                textWidth > 0,
                surfaceWidth.isFinite,
                surfaceWidth > 0
            else {
                return .nan
            }
            let lengthBonus = lengthCoefficient * textWidth / lengthReferenceWidth
            let mediaPointSpeed =
                basePointSpeed
                * speedMultiplier(for: speedLevel)
                * (1 + lengthBonus)
            let rawDuration =
                scrollingTravel(textWidth: textWidth, planningWidth: surfaceWidth)
                / mediaPointSpeed
            return min(
                max(rawDuration, minimumScrollingSeconds),
                maximumScrollingSeconds
            )
        }
    }

    /// 滚动弹幕一次运动的行程（point）：左缘贴着窗口右边缘入场，到右缘离开规划画布左缘，即规划宽度 +
    /// 文字宽度。
    ///
    /// 时长、车道追尾、取景框的可见时段与渲染动画的终点都由它推出，四处必须是同一个量：任何一处另算，
    /// 屏上的运动就会与准入和可见判断错开。
    static func scrollingTravel(textWidth: Double, planningWidth: Double) -> Double {
        planningWidth + textWidth
    }

    /// 滚动弹幕的匀速（point／媒体秒）：行程除以运动时长。
    ///
    /// 用的是钳制后的时长，所以碰到时长上下限时与 `duration` 里的基准速度不同；屏上实际的速度是这一个。
    static func scrollingSpeed(
        textWidth: Double,
        planningWidth: Double,
        durationSeconds: Double
    ) -> Double {
        scrollingTravel(textWidth: textWidth, planningWidth: planningWidth)
            / durationSeconds
    }

    private static func speedMultiplier(for level: DanmakuSpeedLevel) -> Double {
        switch level {
        case .one: 90 / 130
        case .two: 110 / 130
        case .three: 1
        case .four: 155 / 130
        case .five: 185 / 130
        }
    }
}

/// Renderer 的最小平台 port，由 `DanmakuMaterializer` 驱动。
///
/// 弹幕 layer 按 placement 的媒体时间运动，port 不涉及时钟：暂停、倍速与 seek 由宿主的时钟层
/// 处理。`clearAll` 取消在途准备并移除全部 layer；`stop` 同样取消准备并清屏。`updateSurfaceSize`
/// 给的是窗口（取景框）尺寸：只移动滚动、顶部、底部弹幕各自的锚定边，不改任何弹幕的运动，哪些弹幕
/// 该在屏由调用方随后对齐；backing scale 由调用方归一化后传入，变化时取消在途准备。
@MainActor
public protocol DanmakuRenderingBackend: AnyObject {
    /// 按 renderer 当前的 backing scale 准备纹理；完成回调必须返回 MainActor。
    ///
    /// 缓存命中与立即拒绝会在调用内同步回调，调用方必须先登记请求再调用。准备 ID 由调用方
    /// 单调分配、不复用，作废的准备按 ID 丢弃；generation 只由调用方校验。
    func prepare(
        _ event: DanmakuEvent,
        preparationID: UInt64,

        completion:
            @escaping @MainActor @Sendable (
                DanmakuPreparationResult
            ) -> Void
    )

    /// 用已准备好的纹理按 placement 安装一条弹幕；动画在 placement 的媒体时间开始，安装时已过了开始
    /// 时间的直接出现在中途应在的位置。同一事件 ID 已在屏时原位换上新纹理与 placement。
    ///
    /// `position` 是此刻的媒体时间，纹理字节超限时据此决定腾出谁：先移除已走完的，已进场的弹幕再挤掉
    /// 还没进场的前瞻弹幕；被移除的 ID 在结果里交回，调用方据此更新记录。没有上屏的原因：纹理字节仍然
    /// 超限、画面尺寸为 0、准备已失效或被淘汰，或 CGImage 创建失败；返回前 renderer 已消费或丢弃这条准备
    /// 记录。
    @discardableResult
    func install(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        at position: Double
    ) -> DanmakuInstallResult
    /// 已在屏的弹幕换成新的 placement（重新布局后车道或时长变了），复用原纹理；不在屏时返回 false。
    ///
    /// 纹理是否仍按当前 backing scale 栅格化由 `DanmakuMaterializer` 记录与判断，旧 scale 的纹理不会经
    /// 这里复用。
    @discardableResult
    func update(_ placement: DanmakuLanePlacement) -> Bool
    /// 丢弃一条没有上屏的准备记录；对未知 ID 是空操作。
    func discardPreparation(preparationID: UInt64)
    /// 取消全部在途与已就绪未上屏的准备，被取消的请求不再回调。
    func cancelPendingPreparations()
    func remove(eventID: String)
    func clearAll()
    func setOpacity(_ opacity: DanmakuOpacity)
    func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    )
    func stop()
}
