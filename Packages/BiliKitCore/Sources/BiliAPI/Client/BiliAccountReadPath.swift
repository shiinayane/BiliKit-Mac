/// 可能按账户读取的 endpoint path；`BiliAPIClient` 的 endpoint 扩展用它构造请求，App Composition 用它声明
/// 授权器的 allowlist（`LiveAPIClients` 的各组 path 集合）。
///
/// 只收录会以 `RequestAccess.accountRead` 发出的读取：endpoint 与 allowlist 引用同一个常量，改 path 时两处一起
/// 变，不会出现请求换了 path 而 allowlist 仍放行旧 path（或漏放新 path 而稳定失败）。哪些 path 进入哪组
/// allowlist 仍由 Composition 决定；永远匿名的读取（WBI nav、热搜、联想、测速发现）不在这里。见 SECURITY-MODEL §3。
public enum BiliAccountReadPath {
    /// 主播放与 AI 配音、测速样本共用的 WBI playurl。
    public static let playURL = "/x/player/wbi/playurl"
    /// 字幕目录（只按账户读取）。
    public static let subtitleCatalog = "/x/player/wbi/v2"
    /// 弹幕分段。
    public static let danmakuSegment = "/x/v2/dm/wbi/web/seg.so"
    /// 互动弹幕（评分、投票、UP 主弹幕等）；不签 WBI。
    public static let danmakuView = "/x/v2/dm/web/view"
    /// 根评论。
    public static let rootComments = "/x/v2/reply/wbi/main"
    /// 楼中楼。
    public static let commentReplies = "/x/v2/reply/reply"
    /// 楼中楼里的一串对话（「查看对话」）。
    public static let commentDialog = "/x/v2/reply/dialog/cursor"
    /// 视频详情（主详情与测速样本共用）。
    public static let videoDetail = "/x/web-interface/wbi/view"
    /// 相关推荐。
    public static let relatedVideos = "/x/web-interface/archive/related"
    /// UP 主名片。
    public static let uploaderCard = "/x/web-interface/card"
    /// 观看历史（只按账户读取）。
    public static let watchHistory = "/x/web-interface/history/cursor"
    /// 稍后再看（只按账户读取）。
    public static let watchLater = "/x/v2/history/toview/web"
    /// 自己创建的收藏夹列表（只按账户读取）。
    public static let favoriteFolders = "/x/v3/fav/folder/created/list-all"
    /// 当前账户对一个视频的点赞、投币与收藏状态。
    public static let videoRelation = "/x/web-interface/archive/relation"
    /// 收藏夹内的一页（只按账户读取）。
    public static let favoriteFolderContent = "/x/v3/fav/resource/list"
    /// 热门。
    public static let popular = "/x/web-interface/popular"
    /// 视频搜索。
    public static let videoSearch = "/x/web-interface/wbi/search/type"
}
