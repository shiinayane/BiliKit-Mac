import BiliModels

/// 弹幕滚动速度的五档；rawValue 持久化在播放偏好里，BiliDanmaku 渲染时换算为倍率（第三档为 1）。
public enum DanmakuSpeedLevel: Int, CaseIterable, Sendable, Equatable {
    case one = 1
    case two
    case three
    case four
    case five

    /// 未保存偏好时的唯一默认值；设置、控件与 presentation 初值都从这里读取。
    public static let `default` = Self.three
}

/// 弹幕可占用的画面高度比例；rawValue 是百分比，并持久化在播放偏好里。
public enum DanmakuDisplayArea: Int, CaseIterable, Sendable, Equatable {
    case ten = 10
    case quarter = 25
    case half = 50
    case threeQuarters = 75
    case full = 100

    public static let `default` = Self.full

    public var fraction: Double {
        Double(rawValue) / 100
    }
}

/// 弹幕密度；BiliDanmaku 据此决定弹幕的最小水平间距与允许重叠的层数，rawValue 持久化在播放偏好里。
public enum DanmakuDensity: Int, CaseIterable, Sendable, Equatable {
    case normal
    case increased
    case overlapping

    public static let `default` = Self.normal
}

/// 合并重复弹幕的偏好；布尔值持久化在播放偏好里。
public enum DanmakuDuplicateMerging {
    /// 未保存偏好时的唯一默认值：开启。
    ///
    /// 刷屏时把同文弹幕并成一条带条数，多数视频画面更干净；设置、控件与 presentation 初值都从这里读取。
    public static let defaultIsEnabled = true
}

/// 经过校验的弹幕不透明度，只能由 `allowedRange` 内的有限值构造；持久化值越界时播放偏好回退默认。
public struct DanmakuOpacity: Sendable, Equatable {
    /// 设置滑块的取值范围与持久化值的校验共用它；调低下限会允许几乎看不见的弹幕。
    public static let allowedRange = 0.2...1.0
    public static let fullyOpaque = DanmakuOpacity(validatedValue: 1)

    public let value: Double

    public init?(_ value: Double) {
        guard value.isFinite, Self.allowedRange.contains(value) else {
            return nil
        }
        self.init(validatedValue: value)
    }

    private init(validatedValue: Double) {
        value = validatedValue
    }
}

/// 让 Feature 驱动弹幕会话开始、可见性与完整停止，而不暴露分段缓存、布局或 renderer。
///
/// 实现是 BiliDanmaku 的 `DanmakuSession`，调用方是播放页的 `DanmakuControlsViewModel`。
@MainActor
public protocol DanmakuSessionControlling: AnyObject {
    /// 弹幕分段读取发现凭据失效时回调；由弹幕控制 ViewModel 创建时登记一次，用于请求窗口复核账户。
    func setAuthenticationInvalidationHandler(
        _ handler: @escaping @MainActor () -> Void
    )
    func start(for identity: PlaybackItemIdentity)
    func setEnabled(_ enabled: Bool)
    func setModeVisibility(
        scrolling: Bool,
        top: Bool,
        bottom: Bool
    )
    func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel)
    func setOpacity(_ opacity: DanmakuOpacity)
    func setDisplayArea(_ displayArea: DanmakuDisplayArea)
    func setDensity(_ density: DanmakuDensity)
    /// 是否合并重复弹幕；变化时整张重排。
    func setMergesDuplicates(_ merges: Bool)
    /// 本窗口刚发出成功的弹幕在本地立即上屏；`identity` 不是当前会话的视频时丢弃。
    ///
    /// `event.isOwn` 为 true，ID 是服务端给的弹幕 ID：之后重新读到的分段里有同 ID 的弹幕时换成这一条，保留“自己发的”
    /// 外观；会话停止（换视频）时清空。
    func presentOwnDanmaku(_ event: DanmakuEvent, for identity: PlaybackItemIdentity)
    func stop()
}
