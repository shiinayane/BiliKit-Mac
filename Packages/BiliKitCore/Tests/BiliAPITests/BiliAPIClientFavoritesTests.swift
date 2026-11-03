import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定收藏夹契约：列表与夹内都是不签 WBI 的账户读取；列表按 `attr` 映射私密与默认、丢弃无法判断的行、`data` 为
/// null 时为空；夹内带 `platform=web`、`ps=40`、`type=0` 与排序、关键词，普通视频（含仅自己可见）可播放，失效优先于
/// 番剧／影视、合集、音频与未知类型，不可用行放宽缺失字段，越界页不给总数，`has_more` 决定是否还有下一页；收藏夹不存在
/// 映射为内容不存在，-403 映射为凭据失效。
struct BiliAPIClientFavoritesTests {
    @Test
    func folderListIsUnsignedAccountReadForTheGivenOwner() async throws {
        let transport = StubTransport(responses: [try fixtureResponse("favorite-folders")])
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        _ = try await client.favoriteFolders(ownerID: 10_001)

        let requests = transport.capturedRequests()
        #expect(requests.map(\.url.path) == ["/x/v3/fav/folder/created/list-all"])
        let request = try #require(requests.first)
        #expect(query(of: request) == ["up_mid": "10001"])
    }

    @Test
    func folderListMapsPrivacyAndDefaultAndDropsUnusableRows() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [try fixtureResponse("favorite-folders")]),
            requestAuthorizer: StubAuthorizer()
        )

        let folders = try await client.favoriteFolders(ownerID: 10_001)

        #expect(
            folders == [
                FavoriteFolder(
                    id: 3001,
                    title: "默认收藏夹",
                    mediaCount: 12,
                    isPrivate: false,
                    isDefault: true
                ),
                FavoriteFolder(
                    id: 3002,
                    title: "私密收藏",
                    mediaCount: 3,
                    isPrivate: true,
                    isDefault: false
                ),
                FavoriteFolder(
                    id: 3003,
                    title: "公开收藏",
                    mediaCount: 0,
                    isPrivate: false,
                    isDefault: false
                )
            ]
        )
    }

    /// Cookie 失效时接口退化为访客视角，可能给出 null；这里只如实返回空列表，可疑与否由 Use Case 判断。
    @Test(arguments: [
        #"{"code":0,"message":"0","data":null}"#,
        #"{"code":0,"message":"0","data":{"count":0,"list":null}}"#
    ])
    func folderListWithoutRowsIsEmpty(body: String) async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(body)]),
            requestAuthorizer: StubAuthorizer()
        )

        #expect(try await client.favoriteFolders(ownerID: 10_001).isEmpty)
    }

    @Test
    func missingCredentialFailsBeforeAnyRequest() async {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(.fail(.missingCredential))
        )

        await #expect(throws: BiliAPIError.authorizationRequired) {
            try await client.favoriteFolders(ownerID: 10_001)
        }
        await #expect(throws: BiliAPIError.authorizationRequired) {
            try await client.favoriteFolderPage(request: FavoriteFolderRequest(folderID: 3001))
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    @Test
    func folderPageSendsTheFixedParametersWithoutWBI() async throws {
        let transport = StubTransport(responses: [try fixtureResponse("favorite-resources")])
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        _ = try await client.favoriteFolderPage(request: FavoriteFolderRequest(folderID: 3001))

        let requests = transport.capturedRequests()
        #expect(requests.map(\.url.path) == ["/x/v3/fav/resource/list"])
        let request = try #require(requests.first)
        #expect(
            query(of: request) == [
                "media_id": "3001",
                "pn": "1",
                "ps": "40",
                "keyword": "",
                "order": "mtime",
                "type": "0",
                "tid": "0",
                "platform": "web"
            ]
        )
    }

    @Test(arguments: [
        (FavoriteFolderOrder.recentlyFavorited, "mtime"),
        (.mostPlayed, "view"),
        (.recentlyPublished, "pubtime")
    ])
    func orderMapsToItsParameter(order: FavoriteFolderOrder, expected: String) async throws {
        let transport = StubTransport(responses: [try fixtureResponse("favorite-resources")])
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        _ = try await client.favoriteFolderPage(
            request: FavoriteFolderRequest(folderID: 3001, order: order, page: 2)
        )

        let sent = try #require(transport.capturedRequests().first)
        #expect(query(of: sent)["order"] == expected)
        #expect(query(of: sent)["pn"] == "2")
    }

    /// 关键词按 unreserved 编码：`+` 不会被服务端当成空格。
    @Test
    func keywordIsNormalizedAndStrictlyEncoded() async throws {
        let transport = StubTransport(responses: [try fixtureResponse("favorite-resources")])
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        _ = try await client.favoriteFolderPage(
            request: FavoriteFolderRequest(folderID: 3001, keyword: "  C++ 猫 ")
        )

        let sent = try #require(transport.capturedRequests().first)
        #expect(sent.url.query?.contains("keyword=C%2B%2B%20%E7%8C%AB") == true)
        #expect(query(of: sent)["keyword"] == "C++ 猫")
    }

    @Test(arguments: [
        FavoriteFolderRequest(folderID: 0),
        FavoriteFolderRequest(folderID: 3001, page: 0),
        FavoriteFolderRequest(folderID: 3001, keyword: String(repeating: "长", count: 101))
    ])
    func invalidRequestsSendNothing(request: FavoriteFolderRequest) async {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.favoriteFolderPage(request: request)
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    @Test
    func folderPageMapsEachTypeWithInvalidFirst() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [try fixtureResponse("favorite-resources")]),
            requestAuthorizer: StubAuthorizer()
        )

        let page = try await client.favoriteFolderPage(
            request: FavoriteFolderRequest(folderID: 3001)
        )

        #expect(page.pageNumber == 1)
        #expect(page.pageSize == 40)
        #expect(page.totalCount == 45)
        #expect(page.hasMore)
        #expect(
            page.items.map(\.id) == [
                "BV1FavA1", "BV1FavB2", "BV1FavC3", "BV1FavD4", "fav-21-40001", "fav-21-40002",
                "fav-12-50001", "BV1FavF6", "BV1FavG7", "fav-99-60001"
            ]
        )
        #expect(
            page.items.map(\.unavailability) == [
                nil, nil, .invalid, .invalid, .collection, .invalid, .audio,
                .pgc(label: "电影"), .pgc(label: nil), .unsupported
            ]
        )
        let first = page.items[0]
        #expect(first.title == "收藏 & 视频")
        #expect(first.coverURL?.scheme == "https")
        #expect(first.owner?.avatarURL?.scheme == "https")
        #expect(first.durationSeconds == 300)
        #expect(first.favoritedAt == Date(timeIntervalSince1970: 1_700_000_000))
        // 仅自己可见（attr bit7）与 `bv_id` 写法按普通视频处理，时长 0 原样保留。
        #expect(page.items[1].owner?.name == "作者乙")
        #expect(page.items[1].durationSeconds == 0)
        // 字段不全的不可用行留空。
        let missing = page.items[5]
        #expect(missing.owner == nil)
        #expect(missing.favoritedAt == nil)
        #expect(missing.durationSeconds == nil)
        #expect(page.items[2].owner == nil)
    }

    /// 普通视频缺作者或收藏时间时整页失败，不像不可用行那样放宽。
    @Test(arguments: [
        #"{"id":1,"type":2,"title":"缺作者","cover":"","duration":10,"upper":null,"attr":0,"fav_time":1700000000,"bvid":"BV1FavX1"}"#,
        #"{"id":1,"type":2,"title":"缺收藏时间","cover":"","duration":10,"upper":{"mid":1,"name":"作者"},"attr":0,"fav_time":0,"bvid":"BV1FavX1"}"#,
        #"{"id":1,"type":2,"title":"坏 BV","cover":"","duration":10,"upper":{"mid":1,"name":"作者"},"attr":0,"fav_time":1700000000,"bvid":"av1"}"#
    ])
    func playableRowsAreStrict(row: String) async {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [
                jsonResponse(
                    #"{"code":0,"data":{"info":{"media_count":1},"medias":["# + row
                        + #"],"has_more":false}}"#
                )
            ]),
            requestAuthorizer: StubAuthorizer()
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.favoriteFolderPage(request: FavoriteFolderRequest(folderID: 3001))
        }
    }

    /// 越界页给 `media_count: 0` 与 null：总数记为未知，不覆盖已知总数；第 1 页的 0 是真实的空收藏夹。
    @Test(arguments: [(2, nil), (1, 0)] as [(Int, Int?)])
    func emptyPageBeyondTheFirstHasNoTotal(page: Int, expectedTotal: Int?) async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [
                jsonResponse(
                    #"{"code":0,"data":{"info":{"id":3001,"media_count":0},"medias":null,"has_more":false}}"#
                )
            ]),
            requestAuthorizer: StubAuthorizer()
        )

        let result = try await client.favoriteFolderPage(
            request: FavoriteFolderRequest(folderID: 3001, page: page)
        )

        #expect(result.items.isEmpty)
        #expect(result.totalCount == expectedTotal)
        #expect(!result.hasMore)
    }

    /// 页内条数不足不代表结束：没有条目但 `has_more` 为真时仍有下一页，总数照常给出。
    @Test
    func emptyPageWithMoreKeepsTheTotal() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [
                jsonResponse(
                    #"{"code":0,"data":{"info":{"media_count":90},"medias":[],"has_more":true}}"#
                )
            ]),
            requestAuthorizer: StubAuthorizer()
        )

        let result = try await client.favoriteFolderPage(
            request: FavoriteFolderRequest(folderID: 3001, page: 2)
        )

        #expect(result.totalCount == 90)
        #expect(result.hasMore)
    }

    @Test(arguments: [
        (#"{"code":0,"data":null}"#, ContentApplicationError.contentUnavailable),
        (#"{"code":0,"data":{"info":null,"medias":null,"has_more":false}}"#, .contentUnavailable),
        (#"{"code":11010,"message":"fixture"}"#, .contentUnavailable),
        (#"{"code":-403,"message":"fixture"}"#, .authenticationInvalid)
    ])
    func repositoryMapsFolderPageFailures(body: String, expected: ContentApplicationError) async {
        let repository = BiliFavoritesRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [jsonResponse(body)]),
                requestAuthorizer: StubAuthorizer()
            )
        )

        await #expect(throws: expected) {
            try await repository.favoriteFolderPage(request: FavoriteFolderRequest(folderID: 3001))
        }
    }

    @Test
    func repositoryMapsFolderListFailuresThroughTheContentDomain() async {
        let repository = BiliFavoritesRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [jsonResponse(#"{"code":-352,"message":"x"}"#)]
                ),
                requestAuthorizer: StubAuthorizer()
            )
        )

        await #expect(throws: ContentApplicationError.requestRestricted) {
            try await repository.favoriteFolders(ownerID: 10_001)
        }
    }

    private func query(of request: HTTPRequest) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
    }
}
