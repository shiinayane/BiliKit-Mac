import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth

/// App 端写入只放行 schema 表里精确形状的请求：绑定预期账户后带上 access_key 再签名，本地无凭据时失败、从不匿名签名。
///
/// 「不感兴趣」是 GET，只收单个稿件与一个正整数原因 id，举报类 `feedback_id`、其他客户端身份与调用方自带的凭据参数都
/// 拒绝。点赞、投币、三连是 POST 表单，签名写进正文；方法、query、Content-Type 与字段任一不符都拒绝。
/// 目标 host、端口与保留参数的校验与 App 读取共用，见 `BiliAppRequestAuthorizerTests`。
@Suite(.timeLimit(.minutes(1)))
struct BiliAppWriteRequestAuthorizerTests {
    private static let dislikePath = "/x/feed/dislike"
    private static let cancelPath = "/x/feed/dislike/cancel"
    private static let query = "goto=av&id=170001&reason_id=12&mobi_app=iphone&device=pad&build=1"
    private static let accountID = "42"
    private static let likePath = "/x/v2/view/like"
    private static let coinPath = "/x/v2/view/coin/add"
    private static let triplePath = "/x/v2/view/like/triple"
    private static let engagementPaths: Set<String> = [likePath, coinPath, triplePath]

    @Test(arguments: [dislikePath, cancelPath])
    func signsExactFeedbackWithTheBoundAccountsToken(path: String) async throws {
        let store = MemoryAccountCredentialStore(
            credential: try makeFixtureCredential(userID: Self.accountID)
        )

        let authorized = try await makeAuthorizer(store: store).authorize(
            try Self.request(path: path, query: Self.query),
            boundTo: Self.accountID
        )

        let components = try #require(
            URLComponents(url: authorized.url, resolvingAgainstBaseURL: false)
        )
        #expect(components.host == "app.bilibili.com")
        #expect(components.path == path)
        #expect(authorized.method == .get)
        let signedQuery = try #require(components.percentEncodedQuery)
        let fields = try #require(WriteRequestAuthorizationSupport.decodedUniqueFields(signedQuery))
        #expect(fields["access_key"] == fixtureAppAccessTokenValue)
        #expect(fields["reason_id"] == "12")
        let unsigned = fields.filter { !["sign", "appkey", "ts"].contains($0.key) }
        let timestamp = try #require(fields["ts"].flatMap(Int64.init))
        #expect(BiliAppSigning.signed(unsigned, timestamp: timestamp) == signedQuery)
        #expect(authorized.headers["Cookie"] == nil)
    }

    /// 写入从不匿名：没有凭据时失败；凭据属于另一个账户时按失效拒绝，但不删除（多半是本窗口的账户范围过期）。
    @Test
    func missingOrForeignCredentialNeverSends() async throws {
        let empty = MemoryAccountCredentialStore(credential: nil)
        await #expect(throws: BiliRequestAuthorizationError.missingCredential) {
            _ = try await makeAuthorizer(store: empty).authorize(
                try Self.request(path: Self.dislikePath, query: Self.query),
                boundTo: Self.accountID
            )
        }

        let foreign = MemoryAccountCredentialStore(
            credential: try makeFixtureCredential(userID: "7")
        )
        await #expect(throws: BiliRequestAuthorizationError.accountMismatch) {
            _ = try await makeAuthorizer(store: foreign).authorize(
                try Self.request(path: Self.dislikePath, query: Self.query),
                boundTo: Self.accountID
            )
        }
        #expect(foreign.deleteCount == 0)
    }

    @Test(arguments: [
        query.replacingOccurrences(of: "&reason_id=12", with: ""),
        query.replacingOccurrences(of: "reason_id=12", with: "reason_id=0"),
        query.replacingOccurrences(of: "reason_id=12", with: "reason_id=-1"),
        query.replacingOccurrences(of: "reason_id=12", with: "reason_id=012"),
        query.replacingOccurrences(of: "reason_id=12", with: "feedback_id=1"),
        query + "&feedback_id=1",
        query.replacingOccurrences(of: "id=170001", with: "id=0"),
        query.replacingOccurrences(of: "goto=av", with: "goto=bangumi"),
        query.replacingOccurrences(of: "mobi_app=iphone", with: "mobi_app=android"),
        query + "&access_key=FIXTURE",
        query + "&idx=1"
    ])
    func rejectsQueriesOutsideTheSchema(query: String) async throws {
        let store = MemoryAccountCredentialStore(
            credential: try makeFixtureCredential(userID: Self.accountID)
        )

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            _ = try await makeAuthorizer(store: store).authorize(
                try Self.request(path: Self.dislikePath, query: query),
                boundTo: Self.accountID
            )
        }
    }

    /// allowlist 里但不在 schema 表里的 path（例如首页推荐的读取）、非 GET 与非正数主体都拒绝。
    @Test
    func rejectsUnregisteredPathsMethodsAndSubjects() async throws {
        let store = MemoryAccountCredentialStore(
            credential: try makeFixtureCredential(userID: Self.accountID)
        )
        let authorizer = BiliAppWriteRequestAuthorizer(
            store: store,
            allowedPaths: [Self.dislikePath, "/x/v2/feed/index"]
        )
        let dislike = try Self.request(path: Self.dislikePath, query: Self.query)

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            _ = try await authorizer.authorize(
                try Self.request(path: "/x/v2/feed/index", query: "idx=1"),
                boundTo: Self.accountID
            )
        }
        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            _ = try await authorizer.authorize(
                HTTPRequest(url: dislike.url, method: .post),
                boundTo: Self.accountID
            )
        }
        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            _ = try await authorizer.authorize(dislike, boundTo: "0")
        }
    }

    @Test(arguments: [
        (likePath, "aid=170001&like=0"),
        (likePath, "aid=170001&like=1"),
        (coinPath, "aid=170001&multiply=1&select_like=0"),
        (coinPath, "aid=170001&multiply=2&select_like=1"),
        (triplePath, "aid=170001")
    ])
    func signsEngagementFormsIntoTheBody(path: String, body: String) async throws {
        let store = MemoryAccountCredentialStore(
            credential: try makeFixtureCredential(userID: Self.accountID)
        )

        let authorized = try await BiliAppWriteRequestAuthorizer(
            store: store,
            allowedPaths: Self.engagementPaths
        ).authorize(try Self.formRequest(path: path, body: body), boundTo: Self.accountID)

        #expect(authorized.url.absoluteString == "https://app.bilibili.com\(path)")
        #expect(authorized.method == .post)
        let signedBody = try #require(authorized.body.flatMap { String(data: $0, encoding: .utf8) })
        let fields = try #require(WriteRequestAuthorizationSupport.decodedUniqueFields(signedBody))
        #expect(fields["access_key"] == fixtureAppAccessTokenValue)
        let unsigned = fields.filter { !["sign", "appkey", "ts"].contains($0.key) }
        let timestamp = try #require(fields["ts"].flatMap(Int64.init))
        #expect(BiliAppSigning.signed(unsigned, timestamp: timestamp) == signedBody)
        #expect(authorized.headers["Cookie"] == nil)
    }

    /// 点赞只收 0 或 1（App 端的取值，网页的 1／2 不收）；投币至多 2 枚；三连只收 aid；凭据与签名参数、网页统计字段、
    /// 多个稿件都拒绝。
    @Test(arguments: [
        (likePath, "aid=170001&like=2"),
        (likePath, "aid=170001"),
        (likePath, "aid=170001,170002&like=0"),
        (likePath, "aid=170001&like=0&access_key=FIXTURE"),
        (likePath, "aid=170001&like=0&like=1"),
        (coinPath, "aid=170001&multiply=3&select_like=0"),
        (coinPath, "aid=170001&multiply=1"),
        (coinPath, "aid=170001&multiply=1&select_like=0&csrf=FIXTURE"),
        (triplePath, "aid=170001&ts=1"),
        (triplePath, "bvid=BV17x411w7KC")
    ])
    func rejectsEngagementFormsOutsideTheSchema(path: String, body: String) async throws {
        let store = MemoryAccountCredentialStore(
            credential: try makeFixtureCredential(userID: Self.accountID)
        )
        let authorizer = BiliAppWriteRequestAuthorizer(
            store: store,
            allowedPaths: Self.engagementPaths
        )

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            _ = try await authorizer.authorize(
                try Self.formRequest(path: path, body: body),
                boundTo: Self.accountID
            )
        }
    }

    /// 发评论只在 api 主机上授权（App 主机上的同一 path 拒绝）；回复要同时带 `root` 与 `parent`；@ 提及表必须是昵称到
    /// 正整数 mid 的 JSON 对象，且每个昵称都以「@昵称」出现在正文里。
    @Test(arguments: [
        ("api.bilibili.com", "type=1&oid=170001&message=a&plat=2", true),
        (
            "api.bilibili.com",
            "type=1&oid=170001&root=11&parent=12&message=%E5%9B%9E%E5%A4%8D%20%40%E6%9F%90%E4%BA%BA%20%3A%20a"
                + "&plat=2&at_name_to_mid=%7B%22%E6%9F%90%E4%BA%BA%22%3A7%7D",
            true
        ),
        ("app.bilibili.com", "type=1&oid=170001&message=a&plat=2", false),
        ("api.bilibili.com", "type=1&oid=170001&root=11&message=a&plat=2", false),
        (
            "api.bilibili.com",
            "type=1&oid=170001&message=a&plat=2&at_name_to_mid=%7B%22%E6%9F%90%E4%BA%BA%22%3A7%7D",
            false
        ),
        (
            "api.bilibili.com",
            "type=1&oid=170001&message=%40x&plat=2&at_name_to_mid=%7B%22x%22%3A%220%22%7D",
            false
        ),
        ("api.bilibili.com", "type=1&oid=170001&message=a&plat=2&csrf=FIXTURE", false)
    ])
    func authorizesCommentPostsOnlyWithinTheSchema(
        host: String,
        body: String,
        isAllowed: Bool
    ) async throws {
        let authorizer = BiliAppWriteRequestAuthorizer(
            store: MemoryAccountCredentialStore(
                credential: try makeFixtureCredential(userID: Self.accountID)
            ),
            allowedPaths: ["/x/v2/reply/add"]
        )
        let request = HTTPRequest(
            url: try #require(URL(string: "https://\(host)/x/v2/reply/add")),
            method: .post,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8)
        )

        if isAllowed {
            let authorized = try await authorizer.authorize(request, boundTo: Self.accountID)
            #expect(authorized.url.host == "api.bilibili.com")
            #expect(authorized.headers["Cookie"] == nil)
        } else {
            await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
                _ = try await authorizer.authorize(request, boundTo: Self.accountID)
            }
        }
    }

    /// 方法与正文格式按 path 固定：表单 path 不收 GET、query 或别的 Content-Type，GET path 不收 POST。
    @Test
    func rejectsTheWrongMethodOrBodyFormatForAPath() async throws {
        let store = MemoryAccountCredentialStore(
            credential: try makeFixtureCredential(userID: Self.accountID)
        )
        let authorizer = BiliAppWriteRequestAuthorizer(
            store: store,
            allowedPaths: Self.engagementPaths.union([Self.dislikePath])
        )
        let like = try Self.formRequest(path: Self.likePath, body: "aid=170001&like=0")
        let rejected = [
            try Self.request(path: Self.likePath, query: "aid=170001&like=0"),
            HTTPRequest(
                url: try #require(URL(string: "https://app.bilibili.com\(Self.likePath)?aid=1")),
                method: .post,
                headers: like.headers,
                body: like.body
            ),
            HTTPRequest(
                url: like.url,
                method: .post,
                headers: ["Content-Type": "application/json"],
                body: like.body
            ),
            try Self.formRequest(path: Self.dislikePath, body: Self.query)
        ]
        for request in rejected {
            await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
                _ = try await authorizer.authorize(request, boundTo: Self.accountID)
            }
        }
    }

    private static func formRequest(path: String, body: String) throws -> HTTPRequest {
        HTTPRequest(
            url: try #require(URL(string: "https://app.bilibili.com\(path)")),
            method: .post,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8)
        )
    }

    private static func request(path: String, query: String) throws -> HTTPRequest {
        HTTPRequest(url: try #require(URL(string: "https://app.bilibili.com\(path)?\(query)")))
    }

    private func makeAuthorizer(
        store: MemoryAccountCredentialStore
    ) -> BiliAppWriteRequestAuthorizer {
        BiliAppWriteRequestAuthorizer(
            store: store,
            allowedPaths: [Self.dislikePath, Self.cancelPath]
        )
    }
}
