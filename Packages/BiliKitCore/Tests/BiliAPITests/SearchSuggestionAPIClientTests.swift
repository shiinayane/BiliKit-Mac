import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定搜索联想契约：匿名、不签 WBI、只带按 unreserved 编码的 `term`，只读纯文本 `value` 且单条损坏只丢
/// 这一条，状态码 3 是空列表，其他拒绝照常失败，空词与过长的词不发请求。
struct SearchSuggestionAPIClientTests {
    /// 字段形状依据匿名 `suggest` 响应手写；联想词均为虚构值。
    private static let body = """
        {"code":0,"message":"OK","ttl":1,"data":{"exp_str":"","code":0,"result":{"tag":[
          {"value":"虚构词一","term":"虚构词一","ref":0,"name":"<em \
        class=\\"suggest_high_light\\">虚构</em>词一","spid":5},
          {"value":42},
          {"value":"虚构词二","term":"虚构词二","ref":0,"name":"虚构词二","spid":5}
        ]}}}
        """

    @Test
    func requestIsAnonymousUnsignedAndCarriesTheTerm() async throws {
        let transport = StubTransport(responses: [jsonResponse(Self.body)])
        let authorizer = StubAuthorizer()
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer,
            timestampProvider: { 1_700_000_000 }
        )

        _ = try await client.searchSuggestions(for: "虚构 词")

        // 不经过账户授权、不先取 WBI key，也不附加搜索专用的 buvid3。
        #expect(await authorizer.capturedPaths().isEmpty)
        let requests = transport.capturedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.url.host == "api.bilibili.com")
        #expect(requests.first?.url.path == "/x/web-interface/suggest")
        let components = requests.first.flatMap {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)
        }
        #expect(components?.queryItems == [URLQueryItem(name: "term", value: "虚构 词")])
        #expect(requests.first?.headers["Cookie"] == nil)
    }

    /// 用户输入按 unreserved 规则编码，`+` 不会被服务端当成空格，与正式搜索的编码一致。
    @Test
    func termIsEncodedLikeTheSignedSearch() async throws {
        let transport = StubTransport(responses: [jsonResponse(Self.body)])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        _ = try await client.searchSuggestions(for: "C++ & a=b")

        let query = transport.capturedRequests().first.flatMap {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        }
        #expect(query == "term=C%2B%2B%20%26%20a%3Db")
    }

    /// 只读取纯文本 `value`；单条字段类型错误只丢这一条。
    @Test
    func suggestionsMapPlainValues() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(Self.body)]),
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        #expect(try await client.searchSuggestions(for: "虚构") == ["虚构词一", "虚构词二"])
    }

    /// 接口在没有联想时回复状态码 3，这不是失败。
    @Test
    func noSuggestionsStatusIsAnEmptyList() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [
                jsonResponse(#"{"code":3,"message":"3","ttl":1}"#)
            ]),
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        #expect(try await client.searchSuggestions(for: "虚构").isEmpty)
    }

    @Test
    func otherRejectionsStillFail() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [
                jsonResponse(#"{"code":-400,"message":"bad","ttl":1}"#)
            ]),
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        await #expect(throws: BiliAPIError.apiRejected(code: -400, message: "bad")) {
            try await client.searchSuggestions(for: "虚构")
        }
    }

    @Test(arguments: ["", String(repeating: "长", count: 101)])
    func invalidTermFailsBeforeAnyRequest(term: String) async throws {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.searchSuggestions(for: term)
        }
        #expect(transport.capturedRequests().isEmpty)
    }
}
