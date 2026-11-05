/// App 端（`https://app.bilibili.com`）读取的 endpoint path；`BiliAPIClient` 的 endpoint 扩展用它构造请求，App
/// Composition 用它声明 App 授权器的 allowlist。
///
/// 只收录以 `RequestAccess.appRead` 发出的读取；endpoint 与 allowlist 引用同一个常量的理由同 `BiliAccountReadPath`。
/// 见 SECURITY-MODEL §3。
public enum BiliAppReadPath {
    /// 首页推荐。
    public static let recommendations = "/x/v2/feed/index"
}
