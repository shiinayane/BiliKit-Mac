import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定 UP 主投稿契约：WBI 签名的账户读取带空间 Referer 与排序映射，隐藏的统计不当作 0，单条损坏只丢
/// 这一条，本地无凭据时不匿名请求，非法 MID 或页码不发请求，HTTP 403 不换 key 重试。
struct UploaderVideoAPIClientTests {
    @Test
    func pageMapsFieldsAndDropsInvalidEntries() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(
                responses: [try fixtureResponse("uploader-videos")],
                answersWBINavOnce: true
            ),
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await client.uploaderVideos(ownerID: 10_001, order: .newest, page: 1)

        #expect(page.videos.map(\.bvid) == ["BV1FixtureA1", "BV1FixtureB2"])
        #expect(page.pageNumber == 1)
        #expect(page.pageSize == 30)
        #expect(page.totalCount == 61)

        let first = page.videos[0]
        #expect(first.title == "投稿 & 一")
        #expect(first.coverURL?.absoluteString == "https://images.example.invalid/a.jpg")
        #expect(first.durationSeconds == 754)
        #expect(first.viewCount == 12_345)
        #expect(first.danmakuCount == 678)
        #expect(first.publishedAt == Date(timeIntervalSince1970: 1_720_000_000))
        #expect(!first.isCollaboration)

        // 隐藏的统计（"--"）不当作 0；协议相对封面地址补成 https。
        let second = page.videos[1]
        #expect(second.coverURL?.absoluteString == "https://images.example.invalid/b.jpg")
        #expect(second.durationSeconds == 3_723)
        #expect(second.viewCount == nil)
        #expect(second.danmakuCount == nil)
        #expect(second.isCollaboration)
    }

    @Test(arguments: [
        (UploaderVideoOrder.newest, "pubdate"),
        (.mostPlayed, "click"),
        (.mostFavorited, "stow")
    ])
    func requestIsSignedAccountReadWithSpaceReferer(
        order: UploaderVideoOrder,
        apiValue: String
    ) async throws {
        let transport = StubTransport(
            responses: [try fixtureResponse("uploader-videos")],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        _ = try await client.uploaderVideos(ownerID: 10_001, order: order, page: 2)

        let requests = transport.businessRequests()
        #expect(requests.map(\.url.path) == ["/x/space/wbi/arc/search"])
        let request = try #require(requests.first)
        #expect(request.headers["Referer"] == "https://space.bilibili.com/10001/")
        #expect(request.headers["Cookie"] == StubAuthorizer.cookie)
        let query = queryFields(request)
        #expect(query["mid"] == "10001")
        #expect(query["pn"] == "2")
        #expect(query["ps"] == "30")
        #expect(query["order"] == apiValue)
        #expect(query["wts"] == "1700000000")
        #expect(query["w_rid"]?.count == 32)
    }

    @Test
    func laterPageKeepsTheRequestedPageAndTotal() async throws {
        let body = #"""
            {"code":0,"data":{"list":{"vlist":[{"bvid":"BV1FixtureC3","title":"最后一条","pic":"","length":"00:30","play":1,"video_review":0,"created":1700000000}]},"page":{"count":61}}}
            """#
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(body)], answersWBINavOnce: true),
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await client.uploaderVideos(ownerID: 10_001, order: .newest, page: 3)

        #expect(page.videos.map(\.bvid) == ["BV1FixtureC3"])
        #expect(page.pageNumber == 3)
        #expect(page.totalCount == 61)
    }

    @Test
    func missingCredentialFailsWithoutAnonymousRequest() async throws {
        let transport = StubTransport(
            responses: [try fixtureResponse("uploader-videos")],
            answersWBINavOnce: true
        )
        let repository = BiliContentRepository(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: StubAuthorizer(.fail(.missingCredential)),
                timestampProvider: { 1_700_000_000 }
            )
        )

        // 未登录是“需要登录”，不是“凭据失效”：后者会触发账户复核。
        await #expect(throws: ContentApplicationError.authenticationRequired) {
            try await repository.uploaderVideos(ownerID: 10_001, order: .newest, page: 1)
        }
        #expect(
            !transport.capturedRequests().contains { $0.url.path == "/x/space/wbi/arc/search" }
        )
    }

    @Test(arguments: [(0, 1), (10_001, 0), (10_001, 10_001), (10_001, Int.max)] as [(Int64, Int)])
    func invalidRequestSendsNothing(ownerID: Int64, page: Int) async throws {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.uploaderVideos(ownerID: ownerID, order: .newest, page: page)
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    @Test
    func malformedItemIsDroppedWithoutFailingThePage() async throws {
        // 第二条缺少 length、play 类型错误；只丢弃它，同页其他条目照常返回。
        let body = #"""
            {"code":0,"data":{"list":{"vlist":[
              {"bvid":"BV1FixtureA1","title":"正常","pic":"","length":"01:00","play":1,"video_review":0,"created":1700000000},
              {"bvid":"BV1FixtureB2","title":"异常","pic":"","play":true,"created":1700000000}
            ]},"page":{"count":2}}}
            """#
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(body)], answersWBINavOnce: true),
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await client.uploaderVideos(ownerID: 10_001, order: .newest, page: 1)

        #expect(page.videos.map(\.bvid) == ["BV1FixtureA1"])
        #expect(page.totalCount == 2)
    }

    @Test
    func riskControlForbiddenIsNotRetriedWithRefreshedKey() async throws {
        let transport = StubTransport(
            responses: [try fixtureResponse("nav"), HTTPResponse(statusCode: 403, body: Data())]
        )
        let repository = BiliContentRepository(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: StubAuthorizer(),
                timestampProvider: { 1_700_000_000 }
            )
        )

        await #expect(throws: ContentApplicationError.requestRestricted) {
            try await repository.uploaderVideos(ownerID: 10_001, order: .newest, page: 1)
        }
        #expect(
            transport.capturedRequests().map(\.url.path)
                == [StubTransport.wbiNavPath, "/x/space/wbi/arc/search"]
        )
    }
}
