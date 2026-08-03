import Foundation

/// 字幕正文 URL 的精确 HTTPS host/path allowlist。
///
/// 该策略只判断来源形状；正文 repository 仍须使用无 Cookie、无缓存且拒绝重定向的
/// 独立 transport，不能把通过此检查等同于可复用认证会话。
struct SubtitleURLPolicy: Sendable {
    private let allowedHosts: Set<String> = [
        "aisubtitle.hdslb.com"
    ]

    func allows(_ url: URL) -> Bool {
        guard
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
            components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased(),
            allowedHosts.contains(host),
            components.port == nil || components.port == 443,
            components.user == nil,
            components.password == nil,
            components.fragment == nil,
            components.path.hasPrefix("/bfs/")
        else {
            return false
        }
        return true
    }
}
