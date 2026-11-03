/// 用户发起的账户写入的 endpoint path；`BiliAPIClient` 的写 endpoint 用它构造请求，App Composition 用它声明窗口主 API 的
/// 写 allowlist（`LiveAPIClients.mainAccountWriteAllowedPaths`）。
///
/// 与 `BiliAccountReadPath` 同理：endpoint 与 allowlist 引用同一个常量。BiliAuth 的 `BiliAccountWriteRequestAuthorizer`
/// 另有一张按 path 的封闭 schema 表（BiliAuth 不能依赖 BiliAPI，字面量各写一份），Composition 的测试核对 allowlist 里的
/// 每个 path 都能被它授权。观看进度 heartbeat 不在这里，它有自己的授权器。见 SECURITY-MODEL §3。
public enum BiliAccountWritePath {
    /// 加入稍后再看（`aid`、`csrf`，urlencoded）。
    public static let watchLaterAdd = "/x/v2/history/toview/add"
    /// 从稍后再看移除单条（`aid`、`csrf`，urlencoded，不签 WBI）。
    ///
    /// 网页稍后再看页没有用它，本项目也还没有实测；它有接口文档、多个第三方客户端在用，表单最简单，所以先用它。后备有两级：
    /// 1. `/x/v2/history/toview/v2/dels`，urlencoded、不签 WBI，字段 `resources=<aid>`（多个 Cookie 客户端这样用）：只需在这里
    ///    加一个 path 常量、在授权器 schema 表加一行（`resources` 只接受单个正整数）、写 allowlist 换成它；
    /// 2. 网页实际的 `v2/dels`（WBI 签名 + multipart）：需要改写管线与授权器，见授权器 schema 表的注释。
    public static let watchLaterRemove = "/x/v2/history/toview/del"
    /// 改变一个视频在若干收藏夹里的归属。
    ///
    /// 字段 `rid`、`type=2`、`add_media_ids`、`del_media_ids`、`platform=web`、`csrf`，urlencoded，不签 WBI；网页播放页的收藏
    /// 面板用的就是它，空的一侧以空串发送。
    public static let favoriteMembershipUpdate = "/x/v3/fav/resource/deal"
    /// 从一个收藏夹移除一个视频条目。
    ///
    /// 字段 `resources=<aid>:2`、`media_id`、`platform=web`、`csrf`，urlencoded，不签 WBI，与网页收藏夹页的单条「取消收藏」
    /// 相同；网页从 space 子域发出，这里与其他写入一样用 www 的 Origin 与 Referer，实机可用。接口接受逗号分隔的多个条目，
    /// 这里只发一个。
    public static let favoriteFolderEntryRemove = "/x/v3/fav/resource/batch-del"
    /// 点赞或取消（`aid`、`like=1|2`、`csrf`，urlencoded，不签 WBI）。
    public static let videoLike = "/x/web-interface/archive/like"
    /// 投币（`aid`、`multiply=1|2`、`select_like=0|1`、`csrf`，urlencoded，不签 WBI）。
    public static let videoCoin = "/x/web-interface/coin/add"
    /// 三连（`aid`、`csrf`，urlencoded，不签 WBI）；收藏进默认收藏夹。
    public static let videoTriple = "/x/web-interface/archive/like/triple"
    /// 关注或取消关注一个 UP 主（`fid`、`act=1|2`、`re_src=11`、`csrf`，urlencoded，不签 WBI）。
    ///
    /// 网页从空间页发出时还带 `gaia_source`、`spmid`、`extend_content` 等统计字段，这里不发；`re_src=11`（空间）是网页与
    /// 多个第三方客户端共同的取值。Origin 与 Referer 与其他写入一样用 www。
    public static let relationModify = "/x/relation/modify"
    /// 首页推荐的「不感兴趣」（推荐流固定字段加 `id`、`mid`、`track_id`、`reason_id`、`csrf`，urlencoded）。
    ///
    /// 网页签 WBI，这里不签，见授权器 schema 表的说明。
    public static let recommendationDislike = "/x/web-interface/feedback/dislike"
    /// 撤销「不感兴趣」，字段与 `recommendationDislike` 完全相同。
    public static let recommendationDislikeCancel = "/x/web-interface/feedback/dislike/cancel"
}
