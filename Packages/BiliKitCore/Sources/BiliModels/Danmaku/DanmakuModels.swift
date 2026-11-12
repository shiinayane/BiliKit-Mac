/// 弹幕的显示位置：接口 mode 1–3 都按滚动，4 为底部，5 为顶部；其他模式解码时丢弃。
public enum DanmakuPresentationMode: Sendable, Hashable {
    case scrolling
    case top
    case bottom
}

/// 弹幕的着色样式。
public enum DanmakuColorStyle: Sendable, Hashable {
    /// 按 `colorRGB` 填充，描边按字色自动取深或浅。
    case solid
    /// 大会员彩色弹幕：白色填充、横向渐变描边，不使用 `colorRGB`。
    case vipGradient
}

/// 一条弹幕，由 BiliAPI 的 `DanmakuPayloadDecoder` 从分段 protobuf 解码产生，`BiliDanmaku`
/// 车道布局与渲染消费。
///
/// 解码时限定 ID、时间与正文长度，正文去掉首尾空白且非空；字号只保留 18、25、36，其他按 25；
/// `weight` 为负的弹幕在车道布局前被过滤，不显示。`isHighLike` 的弹幕开头画赞图标，纹理尺寸随之变宽。
public struct DanmakuEvent: Sendable, Hashable, Identifiable {
    /// B 站的三档字号（小、标准、大）。
    public static let supportedFontSizes: Set<Double> = [18, 25, 36]
    /// 标准字号，也是不认识的字号的回退。
    public static let standardFontSize = 25.0

    /// 字号只保留三档，其余按标准字号；BiliAPI 解码与纹理缓存 key 都经它，任意字号不会把缓存打散。
    public static func normalizedFontSize(_ value: Double) -> Double {
        supportedFontSizes.contains(value) ? value : standardFontSize
    }

    public let id: String
    public let timeSeconds: Double
    public let mode: DanmakuPresentationMode
    public let text: String
    public let fontSize: Double
    public let colorRGB: UInt32
    public let colorStyle: DanmakuColorStyle
    public let weight: Int
    /// B 站标记的高赞弹幕（分段 `attributes` 的 bit2）；只影响外观，不参与过滤与车道优先级。
    public let isHighLike: Bool
    /// UP 主在自己视频里从播放器发的弹幕（互动弹幕 `#UP#`）；带“UP主”标签与底色，不参与重复合并。
    public let isUploader: Bool
    /// 本窗口刚发出、在本地立即上屏的弹幕；不参与重复合并，免得并进别人的组里看不出发出去了。
    public let isOwn: Bool

    public init(
        id: String,
        timeSeconds: Double,
        mode: DanmakuPresentationMode,
        text: String,
        fontSize: Double,
        colorRGB: UInt32,
        colorStyle: DanmakuColorStyle,
        weight: Int,
        isHighLike: Bool,
        isUploader: Bool,
        isOwn: Bool = false
    ) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.mode = mode
        self.text = text
        self.fontSize = fontSize
        self.colorRGB = colorRGB
        self.colorStyle = colorStyle
        self.weight = weight
        self.isHighLike = isHighLike
        self.isUploader = isUploader
        self.isOwn = isOwn
    }
}

/// 描述不展示弹幕正文与时间，避免日志或断言输出带出用户内容（见 SECURITY-MODEL §8）。
extension DanmakuEvent: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "DanmakuEvent(redacted)" }
    public var debugDescription: String { description }
}

/// 弹幕的一个分段；`index` 从 1 开始，每段覆盖 360 秒播放时间，由弹幕仓库按请求的序号回填。
public struct DanmakuSegment: Sendable, Equatable {
    public let index: Int
    public let events: [DanmakuEvent]

    public init(index: Int, events: [DanmakuEvent]) {
        self.index = index
        self.events = events
    }
}
