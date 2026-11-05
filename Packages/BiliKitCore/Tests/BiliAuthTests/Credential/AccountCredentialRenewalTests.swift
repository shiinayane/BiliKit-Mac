import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth

/// 续期用 Keychain 里凭据的 access_token 与 refresh_token 发一次签名 POST，把同一账户的新凭据写回 Keychain：启动时只在
/// 离到期不足 30 天时续期，复核时强制续期但有最短间隔；任何失败都保留原凭据、从不删除，续期期间凭据被换掉就不写回。
@Suite(.timeLimit(.minutes(1)))
struct AccountCredentialRenewalTests {
    private static let day: TimeInterval = 86_400

    @Test(arguments: [(10.0, true), (100.0, false)])
    func nearExpiryRenewsOnlyInsideTheWindow(daysLeft: Double, renews: Bool) async throws {
        let store = MemoryAccountCredentialStore(
            credential: try Self.credential(expiringIn: daysLeft * Self.day)
        )
        let transport = RecordingAuthTransport(
            responses: [try fixtureResponse("credential-renewal-success")]
        )

        await AccountCredentialRenewal(transport: transport, store: store).renewIfNeeded(
            .nearExpiry
        )

        let requests = await transport.requests
        #expect(requests.count == (renews ? 1 : 0))
        let stored = try #require(try store.load())
        guard renews else { return }
        let request = try #require(requests.first)
        #expect(
            request.url.absoluteString
                == "https://passport.bilibili.com/x/passport-login/oauth2/refresh_token"
        )
        #expect(request.method == .post)
        let form = try signedForm(of: request)
        #expect(form["access_key"] == fixtureAppAccessTokenValue)
        #expect(form["refresh_token"] == fixtureAppRefreshTokenValue)
        // 续期签发的 access_token 是约 220 个 URL 安全字符，不是扫码时的 32 位十六进制；凭据必须接受这种形状。
        #expect(stored.appAccessToken.value.hasPrefix("FIXTURE-RENEWED_ACCESS-TOKEN_"))
        #expect(stored.appAccessToken.value.utf8.count == 220)
        #expect(stored.appAccessToken.refreshToken == String(repeating: "f", count: 32))
        #expect(stored.value(for: .session) == "FIXTURE_RENEWED_SESSDATA_VALUE")
    }

    /// 业务拒绝、网络失败、正文不是凭据或签给了另一个账户：都只是没有续期，原凭据原样保留。
    @Test(arguments: FailureCase.allCases)
    func failedRenewalKeepsTheOriginalCredential(_ failure: FailureCase) async throws {
        let original = try Self.credential(expiringIn: Self.day)
        let store = MemoryAccountCredentialStore(credential: original)
        let transport = try failure.transport()

        await AccountCredentialRenewal(transport: transport, store: store).renewIfNeeded(
            .nearExpiry
        )

        #expect(await transport.requests.count == 1)
        #expect(try store.load() == original)
        #expect(store.deleteCount == 0)
        #expect(store.saveCount == 0)
    }

    /// 强制续期不看离到期多久，但间隔内只发一次：同一次凭据失败让几个页面各自触发复核。
    @Test
    func forcedRenewalIgnoresTheWindowButIsThrottled() async throws {
        let store = MemoryAccountCredentialStore(
            credential: try makeFixtureCredential(userID: "42")
        )
        let transport = RecordingAuthTransport(
            responses: [try fixtureResponse("credential-renewal-success")]
        )
        let renewal = AccountCredentialRenewal(transport: transport, store: store)

        await renewal.renewIfNeeded(.forced)
        await renewal.renewIfNeeded(.forced)

        #expect(await transport.requests.count == 1)
        #expect(try store.load()?.value(for: .session) == "FIXTURE_RENEWED_SESSDATA_VALUE")
    }

    /// 续期发出后凭据被登出删掉（或换成另一份）：结果丢弃，不把旧会话的新凭据写回去。
    @Test
    func credentialReplacedDuringRenewalIsNotOverwritten() async throws {
        let store = MemoryAccountCredentialStore(
            credential: try Self.credential(expiringIn: Self.day)
        )
        let transport = RecordingAuthTransport(
            responses: [try fixtureResponse("credential-renewal-success")],
            suspendingRequest: 1
        )
        let renewal = AccountCredentialRenewal(transport: transport, store: store)

        async let renewed: Void = renewal.renewIfNeeded(.nearExpiry)
        await transport.waitForSuspendedRequest()
        try store.delete()
        await transport.resumeSuspendedRequest()
        await renewed

        #expect(try store.load() == nil)
        #expect(store.saveCount == 0)
    }

    enum FailureCase: CaseIterable, Sendable {
        case rejected
        case network
        case notACredential
        case anotherAccount

        func transport() throws -> RecordingAuthTransport {
            switch self {
            case .rejected:
                RecordingAuthTransport(responses: [
                    json(#"{"code":-101,"message":"x","data":null}"#)
                ])
            case .network:
                RecordingAuthTransport(errors: [URLError(.notConnectedToInternet)])
            case .notACredential:
                RecordingAuthTransport(responses: [json(#"{"code":0,"message":"0","data":{}}"#)])
            case .anotherAccount:
                RecordingAuthTransport(
                    responses: [
                        json(
                            String(
                                decoding: try fixtureResponse("credential-renewal-success").body,
                                as: UTF8.self
                            )
                            .replacingOccurrences(of: #""mid": 42"#, with: #""mid": 7"#)
                            .replacingOccurrences(of: #""value": "42""#, with: #""value": "7""#)
                        )
                    ]
                )
            }
        }

        private func json(_ body: String) -> HTTPResponse {
            HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(body.utf8)
            )
        }
    }

    private static func credential(expiringIn interval: TimeInterval) throws -> AccountCredential {
        try makeFixtureCredential(expiresAt: Date.now.addingTimeInterval(interval), userID: "42")
    }
}
