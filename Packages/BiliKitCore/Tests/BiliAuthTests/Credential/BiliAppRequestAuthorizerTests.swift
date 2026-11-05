import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth

/// App 端只读请求只放行 `app.bilibili.com` 上 allowlist 内的 GET：有凭据时带上 access_key 再签名，本地明确无凭据时只签名；
/// 凭据损坏或过期删除后报告失效，Keychain 不可用只在已确认未登录时按匿名签名，调用方不能自带凭据、签名或保留参数。
struct BiliAppRequestAuthorizerTests {
    private static let feedPath = "/x/v2/feed/index"

    @Test(arguments: [true, false])
    func signsAllowedRequestAndAttachesTokenOnlyWhenStored(hasCredential: Bool) async throws {
        let store = MemoryAccountCredentialStore(
            credential: hasCredential ? try makeFixtureCredential() : nil
        )
        let authorizer = makeAuthorizer(store: store)

        let signed = try await authorizer.authorize(
            Self.request("https://app.bilibili.com/x/v2/feed/index?mobi_app=iphone&idx=1700000000")
        )

        #expect(signed.carriesCredential == hasCredential)
        let components = try #require(
            URLComponents(url: signed.request.url, resolvingAgainstBaseURL: false)
        )
        #expect(components.host == "app.bilibili.com")
        #expect(components.path == Self.feedPath)
        let query = try #require(components.percentEncodedQuery)
        let fields = try #require(WriteRequestAuthorizationSupport.decodedUniqueFields(query))
        #expect(fields["mobi_app"] == "iphone")
        #expect(fields["idx"] == "1700000000")
        #expect(fields["appkey"] == BiliAppSigning.appKey)
        #expect(fields["access_key"] == (hasCredential ? fixtureAppAccessTokenValue : nil))
        // 签名覆盖除 sign 外的全部参数，含注入的 access_key。
        let unsigned = fields.filter { !["sign", "appkey", "ts"].contains($0.key) }
        let timestamp = try #require(fields["ts"].flatMap(Int64.init))
        #expect(BiliAppSigning.signed(unsigned, timestamp: timestamp) == query)
        #expect(signed.request.headers["Cookie"] == nil)
        #expect(store.deleteCount == 0)
    }

    @Test(
        arguments: [
            "https://api.bilibili.com/x/v2/feed/index",
            "https://app.bilibili.com.evil.invalid/x/v2/feed/index",
            "http://app.bilibili.com/x/v2/feed/index",
            "https://app.bilibili.com:8443/x/v2/feed/index",
            "https://user@app.bilibili.com/x/v2/feed/index",
            "https://app.bilibili.com/x/v2/feed/index#fixture",
            "https://app.bilibili.com/x/feed/dislike",
            "https://app.bilibili.com/x/v2/feed/index?access_key=FIXTURE",
            "https://app.bilibili.com/x/v2/feed/index?sign=FIXTURE",
            "https://app.bilibili.com/x/v2/feed/index?appkey=FIXTURE",
            "https://app.bilibili.com/x/v2/feed/index?ts=1",
            "https://app.bilibili.com/x/v2/feed/index?access%5Fkey=FIXTURE",
            "https://app.bilibili.com/x/v2/feed/index?idx=1&idx=2"
        ]
    )
    func rejectsRequestsOutsideTheExactContract(_ url: String) async throws {
        let store = MemoryAccountCredentialStore(credential: try makeFixtureCredential())

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            _ = try await makeAuthorizer(store: store).authorize(Self.request(url))
        }
    }

    @Test
    func rejectsNonGETAndCallerSuppliedCredentialHeader() async throws {
        let store = MemoryAccountCredentialStore(credential: try makeFixtureCredential())
        let authorizer = makeAuthorizer(store: store)
        let url = try #require(URL(string: "https://app.bilibili.com/x/v2/feed/index"))

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            _ = try await authorizer.authorize(HTTPRequest(url: url, method: .post))
        }
        await #expect(throws: BiliRequestAuthorizationError.credentialHeaderAlreadyPresent) {
            _ = try await authorizer.authorize(
                HTTPRequest(url: url, headers: ["Cookie": "SESSDATA=FIXTURE"])
            )
        }
    }

    @Test
    func expiredOrCorruptCredentialIsDeletedAndNeverDowngradesToAnonymous() async throws {
        let expired = MemoryAccountCredentialStore(
            credential: try makeFixtureCredential(expiresAt: Date(timeIntervalSince1970: 1))
        )
        await #expect(throws: BiliRequestAuthorizationError.expiredCredential) {
            _ = try await makeAuthorizer(store: expired).authorize(Self.feedRequest)
        }
        #expect(expired.deleteCount == 1)

        let corrupt = MemoryAccountCredentialStore(
            loadError: AccountCredentialStoreError.corruptCredential
        )
        await #expect(throws: BiliRequestAuthorizationError.invalidCredential) {
            _ = try await makeAuthorizer(store: corrupt).authorize(Self.feedRequest)
        }
        #expect(corrupt.deleteCount == 1)
    }

    @Test(arguments: [false, true])
    func unavailableKeychainSignsAnonymouslyOnlyWhenConfirmedSignedOut(
        isConfirmedSignedOut: Bool
    ) async throws {
        let store = MemoryAccountCredentialStore(loadError: AccountCredentialStoreError.unavailable)
        let authorizer = makeAuthorizer(store: store, isConfirmedSignedOut: isConfirmedSignedOut)

        if isConfirmedSignedOut {
            let signed = try await authorizer.authorize(Self.feedRequest)
            #expect(!signed.carriesCredential)
        } else {
            await #expect(throws: BiliRequestAuthorizationError.credentialStoreUnavailable) {
                _ = try await authorizer.authorize(Self.feedRequest)
            }
        }
    }

    private static var feedRequest: HTTPRequest {
        request("https://app.bilibili.com/x/v2/feed/index")
    }

    private static func request(_ url: String) -> HTTPRequest {
        HTTPRequest(url: URL(string: url)!)
    }

    private func makeAuthorizer(
        store: MemoryAccountCredentialStore,
        isConfirmedSignedOut: Bool = false
    ) -> BiliAppRequestAuthorizer {
        BiliAppRequestAuthorizer(
            store: store,
            allowedPaths: [Self.feedPath],
            isConfirmedSignedOut: { isConfirmedSignedOut }
        )
    }
}
