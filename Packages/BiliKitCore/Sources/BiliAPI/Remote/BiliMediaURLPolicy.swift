import BiliNetworking
import Foundation

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
