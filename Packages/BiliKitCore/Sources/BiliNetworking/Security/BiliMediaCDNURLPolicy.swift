import Foundation

/// Bili 媒体字节请求的用途专属 host allowlist。
///
/// 调用方在 DTO 映射时和实际
/// 建立媒体连接前都应检查；本策略不携带 Cookie，也不放宽重定向。
public struct BiliMediaCDNURLPolicy: Sendable {
    private static let dedicatedDomainSuffixes = [
        "bilivideo.com",
        "bilivideo.cn",
        "szbdyd.com",
    ]

    private let publicHTTPSPolicy = PublicHTTPSURLPolicy()

    public init() {}

    public func allows(_ url: URL) -> Bool {
        guard publicHTTPSPolicy.allows(url),
            let host = url.host?.lowercased()
        else { return false }

        if Self.dedicatedDomainSuffixes.contains(where: {
            host == $0 || host.hasSuffix(".\($0)")
        }) {
            return true
        }
        if host.hasPrefix("upos-") && host.hasSuffix(".akamaized.net") {
            return true
        }
        return host.hasSuffix(".example.invalid")
    }
}
