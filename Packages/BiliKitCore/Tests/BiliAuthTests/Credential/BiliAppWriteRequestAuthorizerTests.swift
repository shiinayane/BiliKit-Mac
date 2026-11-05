import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth

/// App 端写入只放行 schema 表里精确形状的 GET：绑定预期账户后带上 access_key 再签名，本地无凭据时失败、从不匿名签名。
///
/// 「不感兴趣」只收单个稿件与一个正整数原因 id，举报类 `feedback_id`、其他客户端身份与调用方自带的凭据参数都拒绝。
/// 目标 host、端口与保留参数的校验与 App 读取共用，见 `BiliAppRequestAuthorizerTests`。
@Suite(.timeLimit(.minutes(1)))
struct BiliAppWriteRequestAuthorizerTests {
    private static let dislikePath = "/x/feed/dislike"
    private static let cancelPath = "/x/feed/dislike/cancel"
    private static let query = "goto=av&id=170001&reason_id=12&mobi_app=iphone&device=pad&build=1"
    private static let accountID = "42"

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
