import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定请求授权与 WBI 签名契约：账户读取 endpoint 只授权自己的请求、取 key 的 nav 保持匿名，
/// 搜索带签名与进程内唯一的 buvid3，本地凭据失败时失败关闭，签名被拒只刷新一次 key、
/// HTTP 403 不刷新，-101 只对实际带凭据的请求算凭据失效。
struct BiliAPIClientTests {
    @Test(arguments: AccountReadCase.all)
    func accountReadEndpointsAuthorizeOnlyTheirOwnRequest(
        _ testCase: AccountReadCase
    ) async throws {
        let transport = StubTransport(responses: try testCase.responses())
        let authorizer = StubAuthorizer()
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer,
            timestampProvider: { 1_700_000_000 }
        )

        try await testCase.call(client)

        let requests = transport.capturedRequests()
        #expect(await authorizer.capturedPaths() == [testCase.path])
        #expect(requests.last?.url.path == testCase.path)
        let cookies = requests.last?.headers["Cookie"]?.components(separatedBy: "; ")
        #expect(cookies?.first == StubAuthorizer.cookie)
        // buvid3 只附加到搜索 endpoint。
        #expect(
            cookies.map { Array($0.dropFirst()) }
                == (testCase.path == "/x/web-interface/wbi/search/type"
                    ? [BiliAPIClient.buvid3Cookie] : [])
        )
        // WBI key 的 nav 请求始终匿名。
        #expect(requests.dropLast().allSatisfy { $0.headers["Cookie"] == nil })
    }

    @Test
    func searchUsesWBIAndNormalizesEndpointQuirks() async throws {
        let transport = StubTransport(
            responses: [
                try fixtureResponse("search")
            ],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(
            transport: transport,
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await search(client, " macOS !'()* 测试 ")

        #expect(page.totalResults == 3)
        #expect(page.videos.count == 2)
        #expect(page.videos[0].title == "学习macOS 'A' <测试>")
        #expect(page.videos[0].durationSeconds == 3_723)
        #expect(page.videos[0].coverURL?.scheme == "https")
        #expect(page.videos[1].durationSeconds == 754)

        let requests = transport.businessRequests()
        #expect(requests.map(\.url.path) == ["/x/web-interface/wbi/search/type"])
        let request = try #require(requests.first)
        let searchQuery = URLComponents(
            url: request.url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(searchQuery?.first(where: { $0.name == "keyword" })?.value == "macOS  测试")
        #expect(searchQuery?.first(where: { $0.name == "wts" })?.value == "1700000000")
        #expect(searchQuery?.first(where: { $0.name == "w_rid" })?.value?.count == 32)
    }

    @Test
    func searchCarriesOneBuvid3OnAnonymousAndAuthorizedPaths() async throws {
        let transport = StubTransport(
            responses: [
                try fixtureResponse("nav"),
                try fixtureResponse("search"),
                try fixtureResponse("search")
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(.fail(.missingCredential), .authorize),
            timestampProvider: { 1_700_000_000 }
        )

        _ = try await search(client, "macOS")
        _ = try await search(client, "Swift")

        let requests = transport.capturedRequests()
        #expect(requests.count == 3)
        #expect(requests[0].headers["Cookie"] == nil)
        // 无凭据时只有 buvid3；登录后与授权器给出的 Cookie 并列，且同一进程内不变。
        let anonymousCookie = try #require(requests[1].headers["Cookie"])
        let buvid3 = /buvid3=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}infoc/
        #expect(anonymousCookie.wholeMatch(of: buvid3) != nil)
        #expect(requests[2].headers["Cookie"] == "\(StubAuthorizer.cookie); \(anonymousCookie)")
    }

    @Test(arguments: [
        (HTTPRequestAuthorizationFailureKind.invalidCredential, BiliAPIError.authenticationInvalid),
        (.unavailable, .authorizationUnavailable),
        (.denied, .invalidRequest)
    ])
    func searchFailsClosedForCredentialFailure(
        kind: HTTPRequestAuthorizationFailureKind,
        expected: BiliAPIError
    ) async throws {
        let transport = StubTransport(responses: [], answersWBINavOnce: true)
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(.fail(kind)),
            timestampProvider: { 1_700_000_000 }
        )

        await #expect(throws: expected) {
            try await search(client)
        }
        #expect(transport.businessRequests().isEmpty)
    }

    @Test
    func searchRejectsNegativeDuration() async throws {
        let response = try fixtureResponse("search")
        let source = try #require(
            String(data: response.body, encoding: .utf8)
        )
        let body = try #require(
            source.replacingOccurrences(
                of: "\"duration\": \"01:02:03\"",
                with: "\"duration\": \"-01:02:03\""
            ).data(using: .utf8)
        )
        let transport = StubTransport(
            responses: [
                HTTPResponse(
                    statusCode: response.statusCode,
                    headers: response.headers,
                    body: body
                )
            ],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(
            transport: transport,
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await search(client, "macOS")

        #expect(page.videos[0].durationSeconds == nil)
    }

    /// HTTP 403 是风控而不是 key 过期：按受限失败关闭，不换 key 再请求。
    @Test
    func httpForbiddenFailsClosedWithoutRefreshingWBIKey() async throws {
        let transport = StubTransport(
            responses: [
                try fixtureResponse("nav"),
                HTTPResponse(statusCode: 403, body: Data())
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            timestampProvider: { 1_700_000_000 }
        )

        await #expect(throws: BiliAPIError.httpStatus(403)) {
            try await search(client)
        }
        #expect(
            transport.capturedRequests().map(\.url.path) == [
                StubTransport.wbiNavPath,
                "/x/web-interface/wbi/search/type"
            ]
        )
    }

    @Test(arguments: [
        jsonResponse(#"{"code":-403,"message":"访问权限不足","data":{"unexpected":true}}"#),
        jsonResponse(#"{"code":0,"message":"0","ttl":1,"data":{"v_voucher":"voucher_fixture"}}"#)
    ])
    func signatureRejectionRefreshesWBIKeyOnce(rejection: HTTPResponse) async throws {
        let transport = StubTransport(
            responses: [
                try fixtureResponse("nav"),
                rejection,
                try fixtureResponse("nav-refreshed"),
                try fixtureResponse("search")
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await search(client)

        #expect(page.videos.count == 2)
        let requests = transport.capturedRequests()
        #expect(
            requests.map(\.url.path) == [
                StubTransport.wbiNavPath,
                "/x/web-interface/wbi/search/type",
                StubTransport.wbiNavPath,
                "/x/web-interface/wbi/search/type"
            ]
        )
        let searches = [requests[1], requests[3]]
        #expect(
            searches.allSatisfy {
                $0.headers["Cookie"]
                    == "\(StubAuthorizer.cookie); \(BiliAPIClient.buvid3Cookie)"
            }
        )
        let signatures = searches.map {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "w_rid" })?.value
        }
        #expect(signatures[0] != nil)
        #expect(signatures[0] != signatures[1])
    }

    /// -101 只在请求实际带凭据发出时才是凭据失效；没有授权器或本地无凭据而匿名回退的请求收到 -101
    /// 只说明接口要求登录，按“需要登录”处理，不触发账户复核。
    @Test(
        arguments: [
            (nil, BiliAPIError.authorizationRequired),
            (.fail(.missingCredential), .authorizationRequired),
            (.authorize, .authenticationInvalid)
        ] as [(StubAuthorizer.Outcome?, BiliAPIError)]
    )
    func notLoggedInMeansInvalidCredentialOnlyForAuthenticatedRequests(
        outcome: StubAuthorizer.Outcome?,
        expected: BiliAPIError
    ) async {
        let client = BiliAPIClient(
            transport: StubTransport(
                responses: [jsonResponse(#"{"code":-101,"message":"fixture"}"#)],
                answersWBINavOnce: true
            ),
            requestAuthorizer: outcome.map { StubAuthorizer($0) }
        )

        await #expect(throws: expected) {
            try await client.videoDetail(for: "BV1FixtureA1")
        }
    }

    /// 本套件各文件共用的搜索调用。
    func search(
        _ client: BiliAPIClient,
        _ query: String = "macOS"
    ) async throws -> SearchPage {
        try await client.searchVideos(
            request: VideoSearchRequest(
                criteria: VideoSearchCriteria(query: query),
                page: 1
            )
        )
    }
}

/// 每个账户读取 endpoint 只授权自己的请求；WBI endpoint 前置的 nav 请求保持匿名。
struct AccountReadCase: Sendable, CustomTestStringConvertible {
    static let all: [AccountReadCase] = [
        AccountReadCase(
            path: "/x/web-interface/wbi/search/type",
            responses: { [try fixtureResponse("nav"), try fixtureResponse("search")] },
            call: {
                _ = try await $0.searchVideos(
                    request: VideoSearchRequest(
                        criteria: VideoSearchCriteria(query: "macOS"),
                        page: 1
                    )
                )
            }
        ),
        AccountReadCase(
            path: "/x/v2/dm/wbi/web/seg.so",
            responses: {
                [try fixtureResponse("nav"), try hexFixtureResponse("danmaku-segment-minimal")]
            },
            call: {
                _ = try await $0.danmakuSegmentData(
                    index: 1,
                    for: PlaybackItemIdentity(bvid: "BV1FixtureA1", cid: 900_001)
                )
            }
        ),
        AccountReadCase(
            path: "/x/web-interface/popular",
            responses: { [try fixtureResponse("popular")] },
            call: { _ = try await $0.popular(page: 1, pageSize: 20) }
        ),
        AccountReadCase(
            path: "/x/web-interface/wbi/view",
            responses: { [try fixtureResponse("nav"), try fixtureResponse("view")] },
            call: { _ = try await $0.videoDetail(for: "BV1FixtureA1") }
        ),
        AccountReadCase(
            path: "/x/web-interface/archive/related",
            responses: { [try fixtureResponse("related")] },
            call: { _ = try await $0.relatedVideos(to: "BV1FixtureA1") }
        ),
        AccountReadCase(
            path: "/x/web-interface/card",
            responses: { [try fixtureResponse("uploader-card")] },
            call: { _ = try await $0.uploaderProfile(for: 10_001) }
        ),
        AccountReadCase(
            path: "/x/space/wbi/arc/search",
            responses: { [try fixtureResponse("nav"), try fixtureResponse("uploader-videos")] },
            call: { _ = try await $0.uploaderVideos(ownerID: 10_001, order: .newest, page: 1) }
        ),
        AccountReadCase(
            path: "/x/player/wbi/playurl",
            responses: { [try fixtureResponse("nav"), try fixtureResponse("playurl")] },
            call: { _ = try await $0.playback(for: "BV1FixtureA1", cid: 900_001) }
        ),
        AccountReadCase(
            path: "/x/web-interface/history/cursor",
            responses: { [try fixtureResponse("history")] },
            call: { _ = try await $0.watchHistory(pageSize: 20) }
        ),
        AccountReadCase(
            path: "/x/v2/history/toview/web",
            responses: { [try fixtureResponse("nav"), try fixtureResponse("watchlater")] },
            call: { _ = try await $0.watchLater(request: WatchLaterRequest()) }
        ),
        AccountReadCase(
            path: "/x/v3/fav/folder/created/list-all",
            responses: { [try fixtureResponse("favorite-folders")] },
            call: { _ = try await $0.favoriteFolders(ownerID: 10_001) }
        ),
        AccountReadCase(
            path: "/x/v3/fav/resource/list",
            responses: { [try fixtureResponse("favorite-resources")] },
            call: {
                _ = try await $0.favoriteFolderPage(request: FavoriteFolderRequest(folderID: 3001))
            }
        )
    ]

    let path: String
    let responses: @Sendable () throws -> [HTTPResponse]
    let call: @Sendable (BiliAPIClient) async throws -> Void

    var testDescription: String { path }
}
