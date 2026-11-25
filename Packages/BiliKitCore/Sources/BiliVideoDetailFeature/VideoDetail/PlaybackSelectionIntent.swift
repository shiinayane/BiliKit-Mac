/// 打开或切换一个视频的意图：来源页、相关推荐、选集与评论链接都以它进入播放。
///
/// App 的导航协调只比较与转交它（同一意图不重复打开）；怎样把它落到当前视频上（就地换分 P、原地跳转、重新加载）
/// 由 `VideoViewModel.select(_:)` 决定。
public struct PlaybackSelectionIntent: Hashable, Sendable {
    public let bvid: String
    /// 应用内显式选中的分 P。
    public let preferredCID: Int64?
    /// 外部链接（评论正文）给出的分 P 序号，从 1 开始；超出范围时按默认分 P 打开。
    public let preferredPageNumber: Int?
    /// 外部链接给出的起播秒数（`t=`）；超出分 P 时长时忽略。
    public let preferredStartSeconds: Int?
    /// 来源列表给出的第一个分 P 的 CID，只用来与详情并行请求播放清单。
    ///
    /// 不选择分 P、不影响续播；详情到达后核对不一致就丢弃。不参与相等与哈希：同一个视频从不同列表打开仍是同一意图，
    /// 导航的去重与历史比较不受它影响。
    public let firstPageCIDHint: Int64?

    public init(
        bvid: String,
        preferredCID: Int64? = nil,
        preferredPageNumber: Int? = nil,
        preferredStartSeconds: Int? = nil,
        firstPageCIDHint: Int64? = nil
    ) {
        self.bvid = bvid
        self.preferredCID = preferredCID
        self.preferredPageNumber = preferredPageNumber
        self.preferredStartSeconds = preferredStartSeconds
        self.firstPageCIDHint = firstPageCIDHint
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bvid == rhs.bvid
            && lhs.preferredCID == rhs.preferredCID
            && lhs.preferredPageNumber == rhs.preferredPageNumber
            && lhs.preferredStartSeconds == rhs.preferredStartSeconds
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bvid)
        hasher.combine(preferredCID)
        hasher.combine(preferredPageNumber)
        hasher.combine(preferredStartSeconds)
    }
}
