import BiliModels
import Foundation
import Testing

@testable import BiliAPI

@Suite("Comment asset resolver")
struct CommentAssetResolverTests {
    private let resolver = BiliCommentAssetResolver()

    @Test
    func acceptsTrustedHTTPSHostsAcrossTheBFSNamespace() throws {
        for host in ["i0.hdslb.com", "i1.hdslb.com", "i2.hdslb.com"] {
            for path in [
                "bfs/emote/fixture.png",
                "bfs/face/fixture.jpg",
                "bfs/new_dyn/fixture.webp",
                "bfs/garb/item/fixture.png",
                "bfs/garb/fixture.webp",
                "bfs/activity-plat/static/20231013/bucket/fixture.png",
                "bfs/future-package/nested/fixture.gif@128w.webp",
            ] {
                let url = try #require(URL(string: "https://\(host)/\(path)"))
                let reference = CommentAssetReference(remoteURL: url)

                #expect(resolver.imageURL(for: reference) == url)
            }
        }
    }

    @Test(
        arguments: [
            "http://i0.hdslb.com/bfs/emote/fixture.png",
            "https://example.invalid/bfs/emote/fixture.png",
            "https://localhost/bfs/emote/fixture.png",
            "https://user@i0.hdslb.com/bfs/emote/fixture.png",
            "https://i0.hdslb.com:444/bfs/emote/fixture.png",
            "https://i0.hdslb.com/not-bfs/emote/fixture.png",
            "https://i0.hdslb.com/bfs",
            "https://i0.hdslb.com/bfs/",
            "https://i0.hdslb.com/bfs//fixture.png",
            "https://i0.hdslb.com/bfs/../fixture.png",
            "https://i0.hdslb.com/bfs/%2E%2E/fixture.png",
            "https://i0.hdslb.com/bfs/emote%2F..%2Ffixture.png",
            "https://i0.hdslb.com/bfs/emote%5Cfixture.png",
            "https://i0.hdslb.com/bfs/emote%252F..%252Ffixture.png",
            "https://i0.hdslb.com/bfs/emote%255Cfixture.png",
            "https://i0.hdslb.com/bfs/%252E%252E/fixture.png",
            "https://i0.hdslb.com/bfs/emote/fixture.png?token=value",
            "https://i0.hdslb.com/bfs/emote/fixture.png#fragment",
        ]
    )
    func rejectsUntrustedOrAmbiguousSources(_ value: String) throws {
        let url = try #require(URL(string: value))
        let reference = CommentAssetReference(remoteURL: url)

        #expect(resolver.imageURL(for: reference) == nil)
    }

    @Test
    func rejectsOpaqueReferencesWithoutInventingASource() {
        #expect(resolver.imageURL(for: CommentAssetReference()) == nil)
    }
}
