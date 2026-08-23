import BiliNetworking
import Foundation

/// 媒体 Range 候选的用途专属 URL 形状 allowlist。
///
/// 它在公共 HTTPS 基线上收窄到已审计 CDN host；不负责 Cookie 或重定向，生产
/// `HTTPRangeClient` 另以无 Cookie、拒绝重定向的 transport 执行请求。
struct BiliMediaURLPolicy: Sendable {
    private let policy = BiliMediaCDNURLPolicy()

    func allows(_ url: URL) -> Bool {
        policy.allows(url)
    }
}
