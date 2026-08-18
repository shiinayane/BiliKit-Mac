import BiliModels
import Foundation
import Testing

@testable import BiliAPI

@Suite("Comment link resolver")
struct CommentLinkResolverTests {
    private let resolver = BiliCommentLinkResolver()

    @Test
    func resolvesPositiveMemberIDsToThePublicSpacePage() throws {
        let url = try #require(
            resolver.externalURL(
                for: .member(CommentAuthorID(rawValue: "123456"))
            )
        )

        #expect(url.absoluteString == "https://space.bilibili.com/123456")
    }

    @Test(arguments: ["", "0", "-1", "abc", "１２３", "999999999999999999999999"])
    func rejectsInvalidMemberIDs(_ value: String) {
        #expect(
            resolver.externalURL(
                for: .member(CommentAuthorID(rawValue: value))
            ) == nil
        )
    }

    @Test
    func preservesAUserInitiatedPublicHTTPSExternalURL() throws {
        let url = try #require(
            URL(string: "https://www.bilibili.com/opus/42?from=comment#reply")
        )
        let reference = CommentExternalLinkReference(remoteURL: url)

        #expect(resolver.externalURL(for: .external(reference)) == url)
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
            "https://www.bilibili.com:444/opus/42",
        ]
    )
    func rejectsUnsafeExternalDestinations(_ value: String) throws {
        let url = try #require(URL(string: value))
        let reference = CommentExternalLinkReference(remoteURL: url)

        #expect(resolver.externalURL(for: .external(reference)) == nil)
    }

    @Test
    func leavesVideoLinksForInAppNavigation() {
        #expect(
            resolver.externalURL(for: .video(bvid: "BV1FixtureA1")) == nil
        )
    }
}
