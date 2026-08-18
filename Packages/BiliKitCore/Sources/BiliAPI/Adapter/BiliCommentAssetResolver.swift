import BiliModels
import Foundation

public struct BiliCommentAssetResolver: Sendable {
    private static let bfsPathPrefix = "/bfs/"
    private static let allowedHosts: Set<String> = [
        "i0.hdslb.com",
        "i1.hdslb.com",
        "i2.hdslb.com",
    ]

    public init() {}

    public func imageURL(for reference: CommentAssetReference) -> URL? {
        guard let url = reference.remoteURL else { return nil }
        guard url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased(),
            Self.allowedHosts.contains(host),
            url.port == nil || url.port == 443,
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil,
            Self.isSafeBFSPath(url)
        else { return nil }
        return url
    }

    private static func isSafeBFSPath(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        let encodedPath = components.percentEncodedPath
        let lowercaseEncodedPath = encodedPath.lowercased()
        guard encodedPath.hasPrefix(bfsPathPrefix),
            encodedPath.count > bfsPathPrefix.count,
            !lowercaseEncodedPath.contains("%25"),
            !lowercaseEncodedPath.contains("%2f"),
            !lowercaseEncodedPath.contains("%5c")
        else { return false }

        let decodedPath = url.path
        guard !decodedPath.contains("\\"),
            !decodedPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return false }
        let resourceComponents =
            decodedPath
            .dropFirst(bfsPathPrefix.count)
            .split(separator: "/", omittingEmptySubsequences: false)
        return !resourceComponents.isEmpty
            && resourceComponents.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
