/// 用户发起的 App 端（`https://app.bilibili.com`）写入的 endpoint path；`BiliAPIClient` 的 endpoint 扩展用它构造请求，App
/// Composition 用它声明 App 写授权器的 allowlist（`LiveAPIClients.mainAppWriteAllowedPaths`）。
///
/// 只收录以 `RequestAccess.appWrite` 发出的写入；endpoint 与 allowlist 引用同一个常量的理由同 `BiliAccountWritePath`。
/// BiliAuth 的 `BiliAppWriteRequestAuthorizer` 另有一张按 path 的封闭 schema 表，Composition 的测试核对 allowlist 里的
/// 每个 path 都能被它授权。见 SECURITY-MODEL §3。
public enum BiliAppWritePath {
    /// 首页推荐的「不感兴趣」（`goto=av`、`id`、`reason_id` 加首页推荐请求的客户端身份，GET）。
    public static let recommendationDislike = "/x/feed/dislike"
    /// 撤销「不感兴趣」，字段与 `recommendationDislike` 完全相同。
    public static let recommendationDislikeCancel = "/x/feed/dislike/cancel"
}
