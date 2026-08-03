import BiliNetworking
import Foundation

/// 媒体 Range 候选的用途专属 URL 形状 allowlist。
///
/// 它在公共 HTTPS 基线上收窄到已审计 CDN host；不负责 Cookie 或重定向，生产
/// `HTTPRangeClient` 另以无 Cookie、拒绝重定向的 transport 执行请求。
struct BiliMediaURLPolicy: Sendable {
    private static let dedicatedDomainSuffixes = [
        "bilivideo.com",
        "bilivideo.cn",
        "szbdyd.com",
    ]

    private let publicHTTPSPolicy = PublicHTTPSURLPolicy()

    func allows(_ url: URL) -> Bool {
        guard publicHTTPSPolicy.allows(url),
            let host = url.host?.lowercased()
        else {
            return false
        }

        if Self.dedicatedDomainSuffixes.contains(where: {
            host == $0 || host.hasSuffix(".\($0)")
        }) {
            return true
        }

        if host.hasPrefix("upos-") && host.hasSuffix(".akamaized.net") {
            return true
        }

        // RFC 2606 的 .invalid 只用于仓库内手写 contract fixture，无法解析到网络目标。
        return host.hasSuffix(".example.invalid")
    }
}
