import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定 b23.tv 短链解析：只对合规短链发一次无凭据、只含短码的 HEAD，按评论链接规则分类跳转目标；
/// 非跳转、Location 缺失或不安全、目标又是短链以及传输失败都解析不出，由调用方打开原短链。
@Suite("Short link resolver")
struct BiliShortLinkResolverTests {
    private func shortLink(
        _ value: String = "https://b23.tv/AbCd123?share_source=copy"
    )
        throws -> CommentLinkTarget
    {
        CommentLinkTarget.shortLink(
            CommentExternalLinkReference(remoteURL: try #require(URL(string: value)))
        )
    }

    private func redirect(to location: String, statusCode: Int = 302) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, headers: ["Location": location], body: Data())
    }

    /// 只发一次无凭据 HEAD 到只含短码的地址，并按评论链接规则分类跳转目标。
    @Test
    func resolvesTheRedirectTargetWithOneCredentialFreeHEAD() async throws {
        let transport = StubTransport(
            responses: [
                redirect(to: "https://www.bilibili.com/video/BV1xx411c7mD?p=2&share_source=copy")
            ]
        )
        let resolver = BiliShortLinkResolver(transport: transport)

        let resolved = await resolver.resolve(try shortLink())

        #expect(resolved == .video(bvid: "BV1xx411c7mD", page: 2, startSeconds: nil))
        let request = try #require(transport.capturedRequests().first)
        #expect(transport.capturedRequests().count == 1)
        #expect(request.method == .head)
        #expect(request.url.absoluteString == "https://b23.tv/AbCd123")
        #expect(request.headers.isEmpty)
        #expect(request.body == nil)
    }

    @Test(arguments: [301, 303, 307, 308])
    func acceptsEveryRedirectStatus(_ statusCode: Int) async throws {
        let transport = StubTransport(
            responses: [
                HTTPResponse(
                    statusCode: statusCode,
                    headers: ["location": "https://space.bilibili.com/42"],
                    body: Data()
                )
            ]
        )

        let resolved = await BiliShortLinkResolver(transport: transport).resolve(try shortLink())

        #expect(resolved == .space(memberID: 42))
    }

    /// 站外目标原样分类为外链；是否允许打开仍由评论外链规则复核。
    @Test
    func keepsOtherTargetsAsExternalLinks() async throws {
        let transport = StubTransport(
            responses: [redirect(to: "https://www.bilibili.com/read/cv42")]
        )

        let resolved = await BiliShortLinkResolver(transport: transport).resolve(try shortLink())

        guard case .external(let reference) = resolved else {
            Issue.record("站外目标应分类为外链")
            return
        }
        #expect(reference.remoteURL.absoluteString == "https://www.bilibili.com/read/cv42")
    }

    /// 不是跳转、没有或不合规的 Location、目标又是短链时都解析不出，由调用方打开原短链。
    @Test(
        arguments: [
            HTTPResponse(statusCode: 200, headers: [:], body: Data()),
            HTTPResponse(statusCode: 302, headers: [:], body: Data()),
            HTTPResponse(
                statusCode: 302,
                headers: ["Location": "/video/BV1xx411c7mD"],
                body: Data()
            ),
            HTTPResponse(
                statusCode: 302,
                headers: ["Location": "http://www.bilibili.com/video/BV1xx411c7mD"],
                body: Data()
            ),
            HTTPResponse(
                statusCode: 302,
                headers: ["Location": "https://b23.tv/Other12"],
                body: Data()
            ),
            HTTPResponse(
                statusCode: 404,
                headers: ["Location": "https://www.bilibili.com"],
                body: Data()
            )
        ]
    )
    func unusableResponsesResolveToNothing(_ response: HTTPResponse) async throws {
        let transport = StubTransport(responses: [response])

        #expect(await BiliShortLinkResolver(transport: transport).resolve(try shortLink()) == nil)
    }

    /// 带 userinfo、IP literal、本机地址、仍在 b23.tv 上的 Location：解析不出站内目标，也不能作为外链
    /// 打开，最后回退到原短链。
    @Test(
        arguments: [
            "https://b23.tv@evil.example/x",
            "https://1.2.3.4/video/BV1xx411c7mD",
            "https://localhost/x",
            "https://b23.tv/a/b",
            "https://b23.tv:443/AbCd123",
            "https://B23.TV/x-y"
        ]
    )
    func unsafeOrShortLinkLocationsNeverOpen(location: String) async throws {
        let transport = StubTransport(responses: [redirect(to: location)])

        let resolved = await BiliShortLinkResolver(transport: transport).resolve(try shortLink())

        switch resolved {
        case .video, .member, .space, .shortLink, .timestamp:
            Issue.record("不安全或仍在短链主机的 Location 不应得到站内目标")
        case .external(let reference):
            #expect(BiliCommentLinkResolver().externalURL(for: reference) == nil)
        case nil:
            break
        }
    }

    @Test
    func transportFailureResolvesToNothing() async throws {
        let transport = StubTransport([.cancellation])

        #expect(await BiliShortLinkResolver(transport: transport).resolve(try shortLink()) == nil)
    }

    /// 不是合规短链的目标不发请求。
    @Test
    func otherTargetsSendNoRequest() async throws {
        let shortURL = try #require(URL(string: "https://b23.tv/AbCd123"))
        let malformedShortURL = try #require(URL(string: "https://b23.tv/a/b"))
        let targets: [CommentLinkTarget] = [
            .video(bvid: "BV1xx411c7mD", page: nil, startSeconds: nil),
            .space(memberID: 42),
            .external(CommentExternalLinkReference(remoteURL: shortURL)),
            .shortLink(CommentExternalLinkReference(remoteURL: malformedShortURL))
        ]
        let transport = StubTransport(responses: [])
        let resolver = BiliShortLinkResolver(transport: transport)

        for target in targets {
            #expect(await resolver.resolve(target) == nil)
        }
        #expect(transport.capturedRequests().isEmpty)
    }
}
