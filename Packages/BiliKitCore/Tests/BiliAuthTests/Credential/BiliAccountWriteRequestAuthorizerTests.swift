import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth

/// 账户写入授权器只放行 schema 表里精确形状的 POST，绑定预期账户，只注入 `SESSDATA` 与表单 csrf；收藏移除一次只收
/// 一个视频条目；关注只收单个 UP 主的关注与取消。
@Suite(.timeLimit(.minutes(1)))
struct BiliAccountWriteRequestAuthorizerTests {
    private static let addPath = "/x/v2/history/toview/add"
    private static let removePath = "/x/v2/history/toview/del"
    private static let favoriteDealPath = "/x/v3/fav/resource/deal"
    private static let favoriteRemovePath = "/x/v3/fav/resource/batch-del"
    private static let favoriteDealBody =
        "rid=170001&type=2&add_media_ids=11,12&del_media_ids=&platform=web"
    private static let favoriteRemoveBody = "resources=170001:2&media_id=11&platform=web"
    private static let likePath = "/x/web-interface/archive/like"
    private static let coinPath = "/x/web-interface/coin/add"
    private static let triplePath = "/x/web-interface/archive/like/triple"
    private static let followPath = "/x/relation/modify"
    private static let accountID = "42"

    @Test(arguments: [
        (addPath, "https://www.bilibili.com/"),
        (removePath, "https://www.bilibili.com/watchlater/")
    ])
    func authorizesExactContractAndInjectsOnlySessionAndCSRF(
        path: String,
        referer: String
    ) async throws {
        let authorizer = try makeAuthorizer()

        let authorized = try await authorizer.authorize(
            try writeRequest(path: path, referer: referer),
            boundTo: Self.accountID
        )

        #expect(authorized.headers["Cookie"] == "SESSDATA=FIXTURE_SESSDATA_VALUE")
        #expect(authorized.headers["Origin"] == "https://www.bilibili.com")
        #expect(authorized.method == .post)
        let body = try #require(authorized.body.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body == "aid=170001&csrf=FIXTURE_bili_jct_VALUE")
    }

    @Test(arguments: [
        (likePath, "aid=170001&like=1"),
        (likePath, "aid=170001&like=2"),
        (coinPath, "aid=170001&multiply=1&select_like=0"),
        (coinPath, "aid=170001&multiply=2&select_like=1"),
        (triplePath, "aid=170001"),
        (followPath, "fid=7&act=1&re_src=11"),
        (followPath, "fid=7&act=2&re_src=11"),
        (favoriteDealPath, favoriteDealBody),
        (favoriteDealPath, "rid=170001&type=2&add_media_ids=&del_media_ids=13&platform=web"),
        (favoriteRemovePath, favoriteRemoveBody)
    ])
    func authorizesFavoriteWritesWithCSRFAppended(path: String, body: String) async throws {
        let authorizer = try makeAuthorizer()

        let authorized = try await authorizer.authorize(
            try writeRequest(path: path, body: body),
            boundTo: Self.accountID
        )

        #expect(authorized.headers["Cookie"] == "SESSDATA=FIXTURE_SESSDATA_VALUE")
        let sent = try #require(authorized.body.flatMap { String(data: $0, encoding: .utf8) })
        #expect(sent == "\(body)&csrf=FIXTURE_bili_jct_VALUE")
    }

    /// 收藏改动只收单个视频、固定类型与平台；夹 id 列表各自不重复、两侧不相交、至少一侧非空且有上限，数字不带前导零；
    /// 网页的统计字段不收。
    @Test(arguments: [
        "rid=170001&type=2&add_media_ids=11&platform=web",
        "rid=170001&type=12&add_media_ids=11&del_media_ids=&platform=web",
        "rid=170001&type=2&add_media_ids=11&del_media_ids=&platform=ios",
        "rid=170001,170002&type=2&add_media_ids=11&del_media_ids=&platform=web",
        "rid=170001&type=2&add_media_ids=11,11&del_media_ids=&platform=web",
        "rid=170001&type=2&add_media_ids=11,,12&del_media_ids=&platform=web",
        "rid=170001&type=2&add_media_ids=11,&del_media_ids=&platform=web",
        "rid=170001&type=2&add_media_ids=0&del_media_ids=&platform=web",
        "rid=170001&type=2&add_media_ids=11&del_media_ids=&platform=web&spmid=333.788.0.0",
        "rid=170001&type=2&add_media_ids=11&del_media_ids=11&platform=web",
        "rid=170001&type=2&add_media_ids=11,12&del_media_ids=13,12&platform=web",
        "rid=170001&type=2&add_media_ids=&del_media_ids=&platform=web",
        "rid=0170001&type=2&add_media_ids=11&del_media_ids=&platform=web",
        "rid=170001&type=2&add_media_ids=11,011&del_media_ids=&platform=web",
        "rid=170001&type=2&add_media_ids="
            + (1...101).map(String.init).joined(separator: ",")
            + "&del_media_ids=&platform=web"
    ])
    func rejectsFavoriteDealBodiesOutsideTheSchema(body: String) async throws {
        let authorizer = try makeAuthorizer()

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(
                try writeRequest(path: Self.favoriteDealPath, body: body),
                boundTo: Self.accountID
            )
        }
    }

    /// 点赞、投币、三连与关注只收单个稿件或 UP 主与固定取值：投币不超过 2 枚，关注只能关注或取消，网页的统计字段与
    /// `cross_domain` 都不收。
    @Test(arguments: [
        (likePath, "aid=170001&like=0"),
        (likePath, "aid=170001&like=3"),
        (likePath, "aid=170001"),
        (likePath, "aid=170001,170002&like=1"),
        (likePath, "aid=170001&like=1&spmid=333.788.0.0"),
        (coinPath, "aid=170001&multiply=3&select_like=0"),
        (coinPath, "aid=170001&multiply=0&select_like=0"),
        (coinPath, "aid=170001&multiply=1"),
        (coinPath, "aid=170001&multiply=1&select_like=2"),
        (coinPath, "aid=170001&multiply=1&select_like=0&cross_domain=true"),
        (triplePath, "aid=170001&ga=1"),
        (triplePath, "bvid=BV17x411w7KC"),
        // 同一接口的拉黑（5）、移出黑名单（6）、移除粉丝（7）与悄悄关注（3、4）改动的是另一种关系。
        (followPath, "fid=7&act=5&re_src=11"),
        (followPath, "fid=7&act=3&re_src=11"),
        (followPath, "fid=7&act=7&re_src=11"),
        (followPath, "fid=7,8&act=1&re_src=11"),
        (followPath, "fid=0&act=1&re_src=11"),
        (followPath, "fid=7&act=1"),
        (followPath, "fid=7&act=1&re_src=14"),
        (followPath, "fid=7&act=1&re_src=11&gaia_source=web_main")
    ])
    func rejectsEngagementBodiesOutsideTheSchema(path: String, body: String) async throws {
        let authorizer = try makeAuthorizer()

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(
                try writeRequest(path: path, body: body),
                boundTo: Self.accountID
            )
        }
    }

    /// 夹内移除一次只收一个视频条目：多个条目、其他类型与多个收藏夹都拒绝。
    @Test(arguments: [
        "resources=170001:2,170002:2&media_id=11&platform=web",
        "resources=170001:12&media_id=11&platform=web",
        "resources=170001&media_id=11&platform=web",
        "resources=:2&media_id=11&platform=web",
        "resources=170001:2:2&media_id=11&platform=web",
        "resources=170001:2&media_id=11,12&platform=web",
        "resources=170001:2&media_id=11",
        "resources=170001:2&platform=web"
    ])
    func rejectsFavoriteRemovalBodiesOutsideTheSchema(body: String) async throws {
        let authorizer = try makeAuthorizer()

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(
                try writeRequest(path: Self.favoriteRemovePath, body: body),
                boundTo: Self.accountID
            )
        }
    }

    @Test
    func rejectsTargetMethodAndPathExpansion() async throws {
        let authorizer = try makeAuthorizer()
        let path = Self.addPath
        let cases: [(String, HTTPMethod)] = [
            ("http://api.bilibili.com\(path)", .post),
            ("https://api.bilibili.com.evil.invalid\(path)", .post),
            ("https://api.bilibili.com:444\(path)", .post),
            ("https://user@api.bilibili.com\(path)", .post),
            ("https://api.bilibili.com\(path)?aid=170001", .post),
            ("https://api.bilibili.com\(path)#fragment", .post),
            ("https://api.bilibili.com/x/v2/history/toview/clear", .post),
            ("https://api.bilibili.com/x/click-interface/web/heartbeat", .post),
            ("https://api.bilibili.com\(path)", .get)
        ]
        for (urlString, method) in cases {
            let request = HTTPRequest(
                url: try #require(URL(string: urlString)),
                method: method,
                headers: validHeaders(referer: "https://www.bilibili.com/"),
                body: Data("aid=170001".utf8)
            )
            await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
                try await authorizer.authorize(request, boundTo: Self.accountID)
            }
        }
    }

    /// Composition 没有放行的 path 即使在 schema 表里也不授权。
    @Test
    func rejectsSchemaPathOutsideTheAllowlist() async throws {
        let authorizer = try makeAuthorizer(allowedPaths: [Self.addPath])

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(
                try writeRequest(
                    path: Self.removePath,
                    referer: "https://www.bilibili.com/watchlater/"
                ),
                boundTo: Self.accountID
            )
        }
    }

    @Test(arguments: ["X-Unapproved", "Cookie", "Authorization", "X-CSRF-Token"])
    func rejectsHeaderExpansionAndCallerCredentials(header: String) async throws {
        let authorizer = try makeAuthorizer()
        var headers = validHeaders(referer: "https://www.bilibili.com/")
        headers[header] = "FIXTURE_PREEXISTING_VALUE"

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(
                try writeRequest(path: Self.addPath, headers: headers),
                boundTo: Self.accountID
            )
        }
    }

    @Test(arguments: ["Origin", "Referer", "User-Agent", "Content-Type", "Accept"])
    func rejectsMissingOrAlteredFixedHeaders(header: String) async throws {
        let authorizer = try makeAuthorizer()
        var missing = validHeaders(referer: "https://www.bilibili.com/")
        missing[header] = nil
        var altered = validHeaders(referer: "https://www.bilibili.com/")
        altered[header] = "https://www.bilibili.com/video/BV17x411w7KC/"

        for headers in [missing, altered] {
            await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
                try await authorizer.authorize(
                    try writeRequest(path: Self.addPath, headers: headers),
                    boundTo: Self.accountID
                )
            }
        }
    }

    /// 每个 path 只认自己的固定 Referer。
    @Test
    func rejectsTheOtherPathsReferer() async throws {
        let authorizer = try makeAuthorizer()

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(
                try writeRequest(
                    path: Self.removePath,
                    referer: "https://www.bilibili.com/"
                ),
                boundTo: Self.accountID
            )
        }
    }

    @Test(arguments: [
        "aid=170001&csrf=PRESET",
        "aid=170001&csrf_token=PRESET",
        "aid=170001&viewed=true",
        "aid=170001&aid=170001",
        "aid=0",
        "aid=-3",
        "aid=17x",
        "aid=",
        "bvid=BV17x411w7KC",
        "",
        "aid=" + String(repeating: "1", count: 1_100),
        "AID=170001",
        "a%69d=1&aid=2",
        "aid=1;csrf=x",
        "aid=1%26csrf%3Dx",
        "aid=1+2",
        "aid=99999999999999999999",
        "aid=١٢",
        "aid=1\r\ncsrf=x"
    ])
    func rejectsBodiesOutsideTheSchema(body: String) async throws {
        let authorizer = try makeAuthorizer()

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(
                try writeRequest(path: Self.addPath, body: body),
                boundTo: Self.accountID
            )
        }
    }

    /// path 只认精确且编码规范的形状：尾斜杠、编码字母、大小写、空 query、路径参数、多余斜杠与点段、host 末尾的点都拒绝。
    @Test(arguments: [
        "https://api.bilibili.com/x/v2/history/toview/add/",
        "https://api.bilibili.com/x/v2/history/toview/%61dd",
        "https://api.bilibili.com/X/v2/history/toview/add",
        "https://api.bilibili.com/x/v2/history/toview/add?",
        "https://api.bilibili.com/x/v2/history/toview/add;x",
        "https://api.bilibili.com//x/v2/history/toview/add",
        "https://api.bilibili.com/x/v2/history/./toview/add",
        "https://api.bilibili.com./x/v2/history/toview/add"
    ])
    func rejectsNonCanonicalTargets(url: String) async throws {
        let authorizer = try makeAuthorizer()
        let request = HTTPRequest(
            url: try #require(URL(string: url)),
            method: .post,
            headers: validHeaders(referer: "https://www.bilibili.com/"),
            body: Data("aid=170001".utf8)
        )

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(request, boundTo: Self.accountID)
        }
    }

    /// 只差大小写的同名 header 算重复，不按其中一个放行。
    @Test
    func rejectsCaseVariantDuplicateHeaders() async throws {
        let authorizer = try makeAuthorizer()
        var headers = validHeaders(referer: "https://www.bilibili.com/")
        headers["referer"] = "https://www.bilibili.com/"

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(
                try writeRequest(path: Self.addPath, headers: headers),
                boundTo: Self.accountID
            )
        }
    }

    @Test(arguments: ["", "0", "-42", "42a", "FIXTURE"])
    func rejectsMalformedExpectedAccount(subject: String) async throws {
        let authorizer = try makeAuthorizer()

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(
                try writeRequest(path: Self.addPath),
                boundTo: subject
            )
        }
    }

    /// 凭据属于另一个账户时按凭据失效拒绝，但不删除：那可能是另一窗口刚登录的账户。
    @Test
    func rejectsCredentialOfAnotherAccountWithoutDeletingIt() async throws {
        let store = MemoryAccountCredentialStore(credential: try makeFixtureCredential(userID: "7"))
        let authorizer = BiliAccountWriteRequestAuthorizer(
            store: store,
            allowedPaths: Set(BiliAccountWriteRequestAuthorizer.schemas.keys)
        )

        await #expect(throws: BiliRequestAuthorizationError.accountMismatch) {
            try await authorizer.authorize(
                try writeRequest(path: Self.addPath),
                boundTo: Self.accountID
            )
        }
        #expect(
            BiliRequestAuthorizationError.accountMismatch.authorizationFailureKind
                == .invalidCredential
        )
        #expect(store.deleteCount == 0)
    }

    @Test
    func missingCorruptOrExpiredCredentialCannotAuthorize() async throws {
        let missing = BiliAccountWriteRequestAuthorizer(
            store: MemoryAccountCredentialStore(),
            allowedPaths: [Self.addPath]
        )
        await #expect(throws: BiliRequestAuthorizationError.missingCredential) {
            try await missing.authorize(try writeRequest(path: Self.addPath), boundTo: "42")
        }

        let corruptStore = MemoryAccountCredentialStore(
            loadError: AccountCredentialStoreError.corruptCredential
        )
        let corrupt = BiliAccountWriteRequestAuthorizer(
            store: corruptStore,
            allowedPaths: [Self.addPath]
        )
        await #expect(throws: BiliRequestAuthorizationError.invalidCredential) {
            try await corrupt.authorize(try writeRequest(path: Self.addPath), boundTo: "42")
        }
        #expect(corruptStore.deleteCount == 1)

        let expiredStore = MemoryAccountCredentialStore(
            credential: try makeFixtureCredential(expiresAt: .distantPast, userID: "42")
        )
        let expired = BiliAccountWriteRequestAuthorizer(
            store: expiredStore,
            allowedPaths: [Self.addPath]
        )
        await #expect(throws: BiliRequestAuthorizationError.expiredCredential) {
            try await expired.authorize(try writeRequest(path: Self.addPath), boundTo: "42")
        }
        #expect(expiredStore.deleteCount == 1)
    }

    /// 写请求不读「已确认未登录」：Keychain 不可用一律失败关闭。
    @Test
    func unavailableKeychainFailsClosed() async throws {
        let authorizer = BiliAccountWriteRequestAuthorizer(
            store: MemoryAccountCredentialStore(loadError: StubAuthError.storeUnavailable),
            allowedPaths: [Self.addPath]
        )

        await #expect(throws: BiliRequestAuthorizationError.credentialStoreUnavailable) {
            try await authorizer.authorize(try writeRequest(path: Self.addPath), boundTo: "42")
        }
    }

    private func makeAuthorizer(
        allowedPaths: Set<String> = Set(BiliAccountWriteRequestAuthorizer.schemas.keys)
    ) throws -> BiliAccountWriteRequestAuthorizer {
        BiliAccountWriteRequestAuthorizer(
            store: MemoryAccountCredentialStore(
                credential: try makeFixtureCredential(userID: Self.accountID)
            ),
            allowedPaths: allowedPaths
        )
    }

    private func validHeaders(referer: String) -> [String: String] {
        [
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
            "Origin": "https://www.bilibili.com",
            "Referer": referer,
            "User-Agent": HTTPUserAgent.browserCompatible
        ]
    }

    private func writeRequest(
        path: String,
        referer: String = "https://www.bilibili.com/",
        headers: [String: String]? = nil,
        body: String = "aid=170001"
    ) throws -> HTTPRequest {
        HTTPRequest(
            url: try #require(URL(string: "https://api.bilibili.com\(path)")),
            method: .post,
            headers: headers ?? validHeaders(referer: referer),
            body: Data(body.utf8)
        )
    }
}
