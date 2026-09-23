/// BiliKit 发出请求时使用的 User-Agent。
///
/// 写请求授权器按精确值复核 `browserCompatible`，所以 API client 与授权器必须引用同一常量。
public enum HTTPUserAgent {
    /// B 站 Web 接口（含观看进度 heartbeat）使用的浏览器兼容 UA。
    public static let browserCompatible =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 BiliKitMac/0.1"
    /// 登录、会话校验与字幕正文请求使用的简短 UA。
    public static let short = "BiliKitMac/0.1"
}
