import BiliModels
import Foundation
import Testing

@testable import BiliAPI

/// 评论外链与短链回退：只有通过公开 HTTPS 复核的地址原样交给浏览器。
@Suite("Comment link resolver")
struct CommentLinkResolverTests {
    private let resolver = BiliCommentLinkResolver()

    /// 用户点开的公开 HTTPS 外链原样交给浏览器；短链解析不出时的回退（原短链）走同一复核。
    @Test(arguments: [
        "https://www.bilibili.com/opus/42?from=comment#reply",
        "https://b23.tv/AbCd123"
    ])
    func preservesAUserInitiatedPublicHTTPSExternalURL(_ value: String) throws {
        let url = try #require(URL(string: value))

        #expect(resolver.externalURL(for: CommentExternalLinkReference(remoteURL: url)) == url)
    }

    @Test(
        arguments: [
            "http://www.bilibili.com/opus/42",
            "https://user@www.bilibili.com/opus/42",
            "https://localhost/opus/42",
            "https://localhost./opus/42",
            "https://host.local/opus/42",
            "https://host.local./opus/42",
            "https://home.arpa./opus/42",
            "https://127.0.0.1/opus/42",
            "https://[::1]/opus/42",
            "https://www.bilibili.com:444/opus/42"
        ]
    )
    func rejectsUnsafeExternalDestinations(_ value: String) throws {
        let url = try #require(URL(string: value))
        let reference = CommentExternalLinkReference(remoteURL: url)

        #expect(resolver.externalURL(for: reference) == nil)
    }
}
