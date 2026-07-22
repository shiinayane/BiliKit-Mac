import Foundation

struct SubtitleURLPolicy: Sendable {
    private let allowedHosts: Set<String> = [
        "aisubtitle.hdslb.com",
    ]

    func allows(_ url: URL) -> Bool {
        guard let components = URLComponents(
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
