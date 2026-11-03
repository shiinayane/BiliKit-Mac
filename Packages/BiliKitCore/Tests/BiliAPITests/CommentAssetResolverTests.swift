import BiliModels
import Foundation
import Testing

@testable import BiliAPI

/// 评论图片只从可信图床的 HTTPS BFS 路径加载：主机、userinfo、端口、路径穿越与多重编码、query 与
/// fragment 不合规都被拒绝；带像素框时请求缩小的 WebP，已有缩略参数或框不合法时用原图，
/// 像素框不能让不可信来源变得可用（见 SECURITY-MODEL §4）。
@Suite("Comment asset resolver")
struct CommentAssetResolverTests {
    private let resolver = BiliCommentAssetResolver()

    @Test(
        arguments: ["i0.hdslb.com", "i1.hdslb.com", "i2.hdslb.com", "album.biliimg.com"],
        [
            "bfs/emote/fixture.png",
            "bfs/face/fixture.jpg",
            "bfs/new_dyn/fixture.webp",
            "bfs/garb/item/fixture.png",
            "bfs/garb/fixture.webp",
            "bfs/activity-plat/static/20231013/bucket/fixture.png",
            "bfs/future-package/nested/fixture.gif@128w.webp"
        ]
    )
    func acceptsTrustedHTTPSHostsAcrossTheBFSNamespace(host: String, path: String) throws {
        let url = try #require(URL(string: "https://\(host)/\(path)"))
        let reference = CommentAssetReference(remoteURL: url)

        #expect(resolver.imageURL(for: reference, fitting: nil) == url)
    }

    @Test(
        arguments: [
            "http://i0.hdslb.com/bfs/emote/fixture.png",
            "https://example.invalid/bfs/emote/fixture.png",
            "https://biliimg.com/bfs/new_dyn/fixture.jpg",
            "https://other.biliimg.com/bfs/new_dyn/fixture.jpg",
            "https://album.biliimg.com.example.invalid/bfs/new_dyn/fixture.jpg",
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
            "https://i0.hdslb.com/bfs/emote/fixture.png#fragment"
        ]
    )
    func rejectsUntrustedOrAmbiguousSources(_ value: String) throws {
        let url = try #require(URL(string: value))
        let reference = CommentAssetReference(remoteURL: url)

        #expect(resolver.imageURL(for: reference, fitting: nil) == nil)
    }

    /// 带像素框时请求图床按框缩小的 WebP；动图也走同一参数（图床返回动态 WebP）。
    @Test(
        arguments: ["i0.hdslb.com", "album.biliimg.com"],
        ["bfs/new_dyn/fixture.jpg", "bfs/new_dyn/fixture.gif"]
    )
    func pixelBoxRequestsTheFittedWebP(host: String, path: String) throws {
        let url = try #require(URL(string: "https://\(host)/\(path)"))

        let thumbnail = resolver.imageURL(
            for: CommentAssetReference(remoteURL: url),
            fitting: CommentAssetPixelBox(width: 728, height: 360)
        )

        #expect(thumbnail?.absoluteString == "https://\(host)/\(path)@728w_360h.webp")
    }

    /// 已带缩略参数或框不合法时退回原图，不叠加参数。
    @Test(arguments: [
        ("bfs/new_dyn/fixture.gif@128w.webp", 728, 360),
        ("bfs/new_dyn/fixture.jpg", 0, 360),
        ("bfs/new_dyn/fixture.jpg", 728, -1)
    ])
    func unusableBoxFallsBackToTheOriginal(path: String, width: Int, height: Int) throws {
        let url = try #require(URL(string: "https://i0.hdslb.com/\(path)"))

        let resolved = resolver.imageURL(
            for: CommentAssetReference(remoteURL: url),
            fitting: CommentAssetPixelBox(width: width, height: height)
        )

        #expect(resolved == url)
    }

    @Test
    func pixelBoxNeverRescuesAnUntrustedSource() throws {
        let url = try #require(URL(string: "https://example.invalid/bfs/new_dyn/fixture.jpg"))

        #expect(
            resolver.imageURL(
                for: CommentAssetReference(remoteURL: url),
                fitting: CommentAssetPixelBox(width: 728, height: 360)
            ) == nil
        )
    }
}
