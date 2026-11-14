/// 用户发起的 App 端写入的 endpoint path（主机是 `https://app.bilibili.com`，发评论例外，见 `commentAdd`）；`BiliAPIClient` 的 endpoint 扩展用它构造请求，App
/// Composition 用它声明 App 写授权器的 allowlist（`LiveAPIClients.mainAppWriteAllowedPaths`）。
///
/// 只收录以 `RequestAccess.appWrite` 发出的写入（「不感兴趣」是 GET，点赞、投币、三连与发评论是 POST 表单）；endpoint 与 allowlist 引用同一个常量的理由同 `BiliAccountWritePath`。
/// BiliAuth 的 `BiliAppWriteRequestAuthorizer` 另有一张按 path 的封闭 schema 表，Composition 的测试核对 allowlist 里的
/// 每个 path 都能被它授权。见 SECURITY-MODEL §3。
public enum BiliAppWritePath {
    /// 首页推荐的「不感兴趣」（`goto=av`、`id`、`reason_id` 加首页推荐请求的客户端身份，GET）。
    public static let recommendationDislike = "/x/feed/dislike"
    /// 撤销「不感兴趣」，字段与 `recommendationDislike` 完全相同。
    public static let recommendationDislikeCancel = "/x/feed/dislike/cancel"
    /// 点赞或取消（`aid`、`like=0|1`，0 是点赞、1 是取消，与网页相反；POST 表单）。
    ///
    /// 对已赞的视频再点赞同样返回成功，不报“已赞过”：调用方要按读到的状态决定点赞还是取消，不能用返回码判断原状态。
    public static let videoLike = "/x/v2/view/like"
    /// 投币（`aid`、`multiply=1|2`、`select_like=0|1`，POST 表单）；网页投币接口返回 -401 时它实测仍能成功。
    public static let videoCoin = "/x/v2/view/coin/add"
    /// 三连（`aid`，POST 表单）；收藏进默认收藏夹。
    public static let videoTriple = "/x/v2/view/like/triple"
    /// 发评论或回复（`type=1`、`oid`（aid）、`message`、`plat=2`，回复时另带 `root`（根评论）与 `parent`（被回复的那条）、
    /// 回复楼中楼时带 `at_name_to_mid`；POST 表单）。
    ///
    /// 主机是 `api.bilibili.com` 而不是 App 主机，以 App 鉴权调用。
    ///
    /// 不用网页 Cookie 写入：实测网页写入发出的评论服务端照样返回成功，却对所有人（包括作者）隐藏，同样内容在官方网页上
    /// 发出则正常显示；以 App 鉴权发出的评论与楼中楼回复正常显示。网页会多带 `gaia_source`、WBI 签名与整套浏览器 Cookie，
    /// 没有逐项去试，与点赞投币三连改走 App 端同理，也不做网页失败后再试 App 端的回退。`root`／`parent` 与「回复 @昵称 : 」
    /// 前缀照官方网页评论组件（前缀由客户端加，服务端不加）；`at_name_to_mid` 照官方客户端，服务端据此把 @ 关联到用户。
    public static let commentAdd = "/x/v2/reply/add"
}
