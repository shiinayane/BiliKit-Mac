import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定热搜契约：匿名、不签 WBI、只带 `limit`，只做字段映射，图标只保留图床上不带 query 的 HTTPS 地址，
/// 单条损坏只丢这一条，`limit` 越界不发请求。
struct TrendingSearchAPIClientTests {
    /// 字段形状依据匿名 `search/square` 响应手写；词与图片路径均为虚构值。
    private static let body = """
        {"code":0,"message":"0","data":{"trending":{"title":"虚构热搜","trackid":"1","top_list":[],
        "list":[
          {"keyword":"虚构词一","show_name":"虚构词一 · \
        展示","icon":"https://i0.hdslb.com/bfs/fixture/hot.png","goto":"","uri":""},
          {"keyword":"虚构词二","icon":"http://i1.hdslb.com/bfs/fixture/new.png"},
          {"keyword":"虚构词三","show_name":"虚构词三","icon":"https://images.example.invalid/bfs/x.png"},
          {"keyword":"  ","show_name":"空词"},
          {"keyword":42},
          {"keyword":"虚构词四","show_name":"虚构词四","icon":"https://i2.hdslb.com/bfs/fixture/x.png?q=1"}
        ]}}}
        """

    @Test
    func requestIsAnonymousUnsignedAndCarriesLimit() async throws {
        let transport = StubTransport(responses: [jsonResponse(Self.body)])
        let authorizer = StubAuthorizer()
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer,
            timestampProvider: { 1_700_000_000 }
        )

        _ = try await client.trendingSearchKeywords(limit: 10)

        // 不经过账户授权、不先取 WBI key，也不附加搜索专用的 buvid3。
        #expect(await authorizer.capturedPaths().isEmpty)
        let requests = transport.capturedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.url.host == "api.bilibili.com")
        #expect(requests.first?.url.path == "/x/web-interface/search/square")
        #expect(requests.first?.url.query == "limit=10")
        #expect(requests.first?.headers["Cookie"] == nil)
    }

    /// 只做字段映射：能否搜索、展示名回退与条数上限交给 use case；单条字段类型错误只丢这一条。
    @Test
    func keywordsMapFieldsAndKeepOnlyBFSIcons() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(Self.body)]),
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let keywords = try await client.trendingSearchKeywords(limit: 10)

        #expect(
            keywords == [
                TrendingSearchKeyword(
                    keyword: "虚构词一",
                    displayName: "虚构词一 · 展示",
                    iconURL: URL(string: "https://i0.hdslb.com/bfs/fixture/hot.png")
                ),
                // http 图标升级为 HTTPS 后仍须通过图床规则。
                TrendingSearchKeyword(
                    keyword: "虚构词二",
                    displayName: "",
                    iconURL: URL(string: "https://i1.hdslb.com/bfs/fixture/new.png")
                ),
                // 图床以外的主机与带 query 的地址只丢图标，保留文字。
                TrendingSearchKeyword(keyword: "虚构词三", displayName: "虚构词三", iconURL: nil),
                TrendingSearchKeyword(keyword: "  ", displayName: "空词", iconURL: nil),
                TrendingSearchKeyword(keyword: "虚构词四", displayName: "虚构词四", iconURL: nil)
            ]
        )
    }

    @Test(arguments: [0, 51])
    func outOfRangeLimitFailsBeforeAnyRequest(limit: Int) async throws {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.trendingSearchKeywords(limit: limit)
        }
        #expect(transport.capturedRequests().isEmpty)
    }
}
