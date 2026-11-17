import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定分段章节契约：播放器信息里的 `view_points` 解码为按起点排序的章节，坏元素、无效段与重复起点跳过，封面过公开
/// HTTPS 规则；本地无凭据时章节匿名读取同一 endpoint，字幕目录仍失败关闭、不发请求（见 SECURITY-MODEL §3）。
struct BiliAPIClientVideoChapterTests {
    private static let identity = PlaybackItemIdentity(bvid: "BV1FixtureA1", cid: 900_001)

    @Test
    func chaptersDecodeSortedValidSegments() async throws {
        let transport = StubTransport(
            responses: [Self.chapterResponse],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(transport: transport)

        let chapters = try await client.videoChapters(for: Self.identity)

        #expect(
            chapters == [
                VideoChapter(
                    startSeconds: 0,
                    endSeconds: 120,
                    title: "开场",
                    coverURL: URL(string: "https://i0.hdslb.com/bfs/b.jpg")
                ),
                VideoChapter(
                    startSeconds: 120,
                    endSeconds: 300,
                    title: "第二段",
                    coverURL: URL(string: "https://i0.hdslb.com/bfs/a.jpg")
                ),
                VideoChapter(startSeconds: 400, endSeconds: 500, title: "结尾", coverURL: nil)
            ]
        )
        let request = try #require(transport.businessRequests().first)
        #expect(request.url.path == "/x/player/wbi/v2")
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.contains(URLQueryItem(name: "bvid", value: Self.identity.bvid)) == true)
        #expect(query?.contains(URLQueryItem(name: "cid", value: "900001")) == true)
    }

    /// 同一个 endpoint，两种凭据规则：章节是登录增强读取，字幕目录只按账户读取。
    @Test
    func missingCredentialReadsChaptersAnonymouslyButNotSubtitles() async throws {
        let chapterTransport = StubTransport(
            responses: [Self.chapterResponse],
            answersWBINavOnce: true
        )
        let chapterClient = BiliAPIClient(
            transport: chapterTransport,
            requestAuthorizer: StubAuthorizer(.fail(.missingCredential))
        )

        let chapters = try await chapterClient.videoChapters(for: Self.identity)

        #expect(chapters.map(\.title) == ["开场", "第二段", "结尾"])
        let request = try #require(chapterTransport.businessRequests().first)
        #expect(request.headers["Cookie"] == nil)

        let subtitleTransport = StubTransport(
            responses: [Self.chapterResponse],
            answersWBINavOnce: true
        )
        let subtitleClient = BiliAPIClient(
            transport: subtitleTransport,
            requestAuthorizer: StubAuthorizer(.fail(.missingCredential))
        )

        await #expect(throws: (any Error).self) {
            try await subtitleClient.subtitleResources(for: Self.identity)
        }
        #expect(subtitleTransport.businessRequests().isEmpty)
    }

    /// 乱序、坏元素（`from` 不是数字）、空段、空标题、重复起点（留响应里的第一段）与不合规封面各一。
    private static var chapterResponse: HTTPResponse {
        jsonResponse(
            #"""
            {"code":0,"data":{"view_points":[
              {"type":2,"from":120,"to":300,"content":" 第二段 ","imgUrl":"http://i0.hdslb.com/bfs/a.jpg"},
              {"type":2,"from":0,"to":120,"content":"开场","imgUrl":"//i0.hdslb.com/bfs/b.jpg"},
              {"type":2,"from":120,"to":200,"content":"重复起点"},
              {"type":2,"from":300,"to":300,"content":"空段"},
              {"type":2,"from":300,"to":400,"content":"  "},
              {"type":2,"from":"bad","to":500,"content":"坏元素"},
              {"type":2,"from":400,"to":500,"content":"结尾","imgUrl":"https://127.0.0.1/x.jpg"}
            ]}}
            """#
        )
    }
}
