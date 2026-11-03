import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定首页推荐与热门的响应契约：推荐走 WBI 并过滤不支持的卡片，
/// HTML 风控页、API 拒绝与缺少必需字段分别报非 JSON、保留错误码与解码失败。
struct BiliAPIClientFeedTests {
    @Test
    func recommendationsUseWBIAndFilterUnsupportedCards() async throws {
        let response = jsonResponse(AccountReadCase.recommendationBody)
        let transport = StubTransport(
            responses: [response],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await client.recommendations()

        #expect(page.videos.map(\.bvid) == ["BV1FixtureA1"])
        #expect(page.videos.first?.title == "推荐 & 视频")
        #expect(page.videos.first?.recommendationReason == "正在流行")
        #expect(page.videos.first?.trackID == "web_rcmd.abc-1")
        #expect(page.continuation == RecommendationContinuation(freshIndex: 1))
        #expect(page.nextContinuation == RecommendationContinuation(freshIndex: 2))

        let requests = transport.businessRequests()
        #expect(requests.map(\.url.path) == ["/x/web-interface/wbi/index/top/feed/rcmd"])
        let request = try #require(requests.first)
        #expect(request.headers["Referer"] == "https://www.bilibili.com/")
        let query = URLComponents(
            url: request.url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(query?.first(where: { $0.name == "fresh_idx" })?.value == "1")
        #expect(query?.first(where: { $0.name == "fresh_idx_1h" })?.value == "1")
        #expect(query?.first(where: { $0.name == "wts" })?.value == "1700000000")
        #expect(query?.first(where: { $0.name == "w_rid" })?.value?.count == 32)
    }

    @Test
    func rejectsHTMLRiskControlPageBeforeDecoding() async {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [htmlRiskControlResponse()])
        )

        await #expect(throws: BiliAPIError.nonJSONResponse) {
            try await client.popular(page: 1, pageSize: 20)
        }
    }

    @Test
    func preservesAPIErrorCodeWithoutLeakingBody() async {
        let response = jsonResponse(
            #"{"code":-412,"message":"请求被拦截","data":{"unexpected":true}}"#
        )
        let client = BiliAPIClient(transport: StubTransport(responses: [response]))

        await #expect(
            throws: BiliAPIError.apiRejected(code: -412, message: "请求被拦截")
        ) {
            try await client.popular(page: 1, pageSize: 20)
        }
    }

    @Test
    func missingRequiredContractFieldFailsDecoding() async {
        let response = jsonResponse(
            #"{"code":0,"message":"OK","data":{"list":[{"bvid":"BV1FixtureA1"}]}}"#
        )
        let client = BiliAPIClient(transport: StubTransport(responses: [response]))

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.popular(page: 1, pageSize: 20)
        }
    }
}
