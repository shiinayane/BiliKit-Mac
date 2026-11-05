import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定首页推荐与热门的响应契约：推荐走 App 端接口、经 App 授权器签名并过滤不支持的卡片，游标沿最后一张卡片的
/// `idx` 续传；-101 只在请求带了凭据时是凭据失效；HTML 风控页、API 拒绝与缺少必需字段分别报非 JSON、保留错误码与解码失败。
struct BiliAPIClientFeedTests {
    /// 一批里：可播放的视频（有 BV 号与只有 av 号各一张）、商业推广（`card_goto` 与 `ad_info` 两种）、没有
    /// `player_args` 的视频与直播；最后一张卡片的 `idx` 是下一批游标。
    ///
    /// 第一张卡片的「不感兴趣」原因里混有重复 id、空名字与形状不对的原因，另有不解码的举报类 `feedbacks`。
    static let appFeedBody = #"""
        {"code":0,"message":"0","data":{"items":[
          {"goto":"av","card_goto":"av","param":"170001","bvid":"BV1FixtureA1","title":"推荐 &amp; 视频","cover":"//i0.hdslb.com/a.jpg","args":{"up_id":10001,"up_name":"作者"},"avatar":{"cover":"//i1.hdslb.com/a.jpg"},"player_args":{"aid":170001,"duration":125},"cover_left_text_1":"2:05","cover_left_text_2":"25.4万观看","cover_left_text_3":"13弹幕","desc":"作者 · 6月11日","bottom_rcmd_reason":"已关注","three_point":{"dislike_reasons":[{"id":4,"name":"UP主:作者"},{"id":12,"name":" 此类内容过多 "},{"id":4,"name":"重复"},{"id":13,"name":""},{"id":"x","name":"坏"}],"feedbacks":[{"id":1,"name":"恐怖血腥"}]},"idx":1700000001},
          {"goto":"av","card_goto":"av","param":"170002","title":"只有 av 号","cover":"//i0.hdslb.com/b.jpg","args":{"up_id":10002,"up_name":"另一位"},"player_args":{"aid":170002,"duration":60},"desc":"另一位","idx":1700000002},
          {"goto":"av","card_goto":"ad_av","param":"3","title":"广告","args":{"up_id":3,"up_name":"广告主"},"player_args":{"duration":10},"idx":1700000003},
          {"goto":"av","card_goto":"av","param":"4","title":"推广","args":{"up_id":4,"up_name":"推广主"},"player_args":{"duration":10},"ad_info":{"creative_id":1},"idx":1700000004},
          {"goto":"av","card_goto":"av","param":"5","title":"充电专属","args":{"up_id":5,"up_name":"作者"},"idx":1700000005},
          {"goto":"live","card_goto":"live","param":"6","title":"直播","args":{"up_id":6,"up_name":"主播"},"idx":1700000006}
        ]}}
        """#

    @Test
    func recommendationsUseSignedAppFeedAndFilterUnsupportedCards() async throws {
        let transport = StubTransport(responses: [jsonResponse(Self.appFeedBody)])
        let authorizer = StubAppAuthorizer()
        let client = BiliAPIClient(
            transport: transport,
            appRequestAuthorizer: authorizer,
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await client.recommendations()

        #expect(
            page.videos.map(\.bvid) == [
                "BV1FixtureA1", try #require(BiliVideoAID.bvid(fromAID: 170_002))
            ]
        )
        let first = try #require(page.videos.first)
        #expect(first.title == "推荐 & 视频")
        #expect(
            first.owner
                == VideoOwner(
                    id: 10_001,
                    name: "作者",
                    avatarURL: URL(string: "https://i1.hdslb.com/a.jpg")
                )
        )
        #expect(first.viewCount == 254_000)
        #expect(first.danmakuCount == 13)
        #expect(first.durationSeconds == 125)
        #expect(first.publishedAt != nil)
        #expect(first.recommendationReason == "已关注")
        #expect(
            first.dislikeReasons == [
                try #require(RecommendationDislikeReason(id: 4, name: "UP主:作者")),
                try #require(RecommendationDislikeReason(id: 12, name: "此类内容过多"))
            ]
        )
        #expect(page.videos.last?.dislikeReasons == [])
        #expect(page.videos.last?.viewCount == nil)
        #expect(page.videos.last?.publishedAt == nil)
        #expect(page.continuation == nil)
        #expect(page.nextContinuation == RecommendationContinuation(index: 1_700_000_006))

        let requests = await authorizer.requests
        let request = try #require(requests.first)
        #expect(request.url.host == "app.bilibili.com")
        #expect(request.url.path == "/x/v2/feed/index")
        #expect(request.headers["Referer"] == nil)
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
            .queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        #expect(query == ["mobi_app": "iphone", "device": "pad", "build": "1", "idx": "1700000000"])
        #expect(transport.capturedRequests().first?.url.query?.hasSuffix("signed=FIXTURE") == true)
    }

    @Test
    func nextBatchContinuesFromTheGivenCursor() async throws {
        let authorizer = StubAppAuthorizer()
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(Self.appFeedBody)]),
            appRequestAuthorizer: authorizer,
            timestampProvider: { 1_800_000_000 }
        )
        let cursor = RecommendationContinuation(index: 1_600_000_000)

        let page = try await client.recommendations(after: cursor)

        #expect(page.continuation == cursor)
        let request = try #require(await authorizer.requests.first)
        #expect(request.url.query?.contains("idx=1600000000") == true)
    }

    /// -101 只在 App 授权器实际带了凭据时是凭据失效（触发复核）；匿名签名的请求收到它是“需要登录”。
    @Test(arguments: [(true, BiliAPIError.authenticationInvalid), (false, .authorizationRequired)])
    func notLoggedInDependsOnWhetherTheTokenWasSent(
        carriesCredential: Bool,
        expected: BiliAPIError
    ) async {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [
                jsonResponse(#"{"code":-101,"message":"fixture"}"#)
            ]),
            appRequestAuthorizer: StubAppAuthorizer(carriesCredential: carriesCredential)
        )

        await #expect(throws: expected) {
            try await client.recommendations()
        }
    }

    /// App 端请求不能不签名发出：没有 App 授权器的 client 直接拒绝，授权失败也不退回未签名的原请求。
    @Test
    func neverSendsUnsignedAppRequest() async {
        let withoutAuthorizer = StubTransport(responses: [jsonResponse(Self.appFeedBody)])
        await #expect(throws: BiliAPIError.invalidRequest) {
            try await BiliAPIClient(transport: withoutAuthorizer).recommendations()
        }
        #expect(withoutAuthorizer.capturedRequests().isEmpty)

        let unavailable = StubTransport(responses: [jsonResponse(Self.appFeedBody)])
        await #expect(throws: BiliAPIError.authorizationUnavailable) {
            try await BiliAPIClient(
                transport: unavailable,
                appRequestAuthorizer: StubAppAuthorizer(failure: .unavailable)
            ).recommendations()
        }
        #expect(unavailable.capturedRequests().isEmpty)
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
