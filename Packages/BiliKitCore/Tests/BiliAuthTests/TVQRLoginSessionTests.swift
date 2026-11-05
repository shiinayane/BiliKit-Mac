import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth

/// TV 端扫码登录只在 nav 校验成功后保存凭据，且只保存成功正文 `cookie_info` 里完整、与 `mid` 一致的白名单 Cookie。
///
/// 取码与轮询是带 APP 签名的 POST；二维码 URL 须是 passport 的 TV 授权页且指向本次的码；状态描述与诊断不含
/// auth_code、链接参数或响应里的秘密；没有挑战时不轮询，过期后挑战作废；旧的二维码、轮询与校验结果不能覆盖新的
/// 代次；取消清空状态。
@Suite(.timeLimit(.minutes(1)))
struct TVQRLoginSessionTests {
    @Test
    func requestsQRCodeAndKeepsRawValuesOutOfDescription() async throws {
        let transport = RecordingAuthTransport(responses: [try fixtureResponse("qr-generate")])
        let session = TVQRLoginSession(
            transport: transport,
            credentialStore: MemoryAccountCredentialStore()
        )

        let state = try await session.requestQRCode()

        guard case .awaitingScan(let qrCode) = state else {
            Issue.record("应进入等待扫码状态")
            return
        }
        #expect(URL(string: qrCode.payload)?.host == "passport.bilibili.com")
        #expect(qrCode.payload.contains(fixtureAuthCode))
        #expect(state.description == "awaiting-scan")
        #expect(!state.description.contains(fixtureAuthCode))
        #expect(!qrCode.description.contains(fixtureAuthCode))
        #expect(!String(reflecting: qrCode).contains(fixtureAuthCode))
        var reflected = ""
        dump(qrCode, to: &reflected)
        #expect(!reflected.contains(fixtureAuthCode))

        let request = try #require(await transport.requests.first)
        #expect(request.method == .post)
        #expect(
            request.url.absoluteString
                == "https://passport.bilibili.com/x/passport-tv-login/qrcode/auth_code"
        )
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        let form = try signedForm(of: request)
        #expect(form["appkey"] == BiliAppSigning.appKey)
        #expect(form["local_id"] == "0")
        #expect(form.keys.sorted() == ["appkey", "local_id", "sign", "ts"])
    }

    @Test(
        arguments: [
            ("qr-poll-not-scanned", "awaiting-scan", true),
            ("qr-poll-awaiting-confirmation", "awaiting-confirmation", true),
            ("qr-poll-expired", "expired", false)
        ]
    )
    func mapsObservedPollStatus(
        fixture: String,
        expectedDescription: String,
        challengeRemainsActive: Bool
    ) async throws {
        let transport = RecordingAuthTransport(
            responses: [
                try fixtureResponse("qr-generate"),
                try fixtureResponse(fixture)
            ]
        )
        let session = TVQRLoginSession(
            transport: transport,
            credentialStore: MemoryAccountCredentialStore()
        )

        _ = try await session.requestQRCode()
        let state = try await session.pollOnce()

        #expect(state.description == expectedDescription)
        #expect(!state.description.contains(fixtureAuthCode))
        let pollRequest = try #require(await transport.requests.last)
        #expect(pollRequest.method == .post)
        #expect(pollRequest.url.path == "/x/passport-tv-login/qrcode/poll")
        #expect(pollRequest.url.query == nil)
        let form = try signedForm(of: pollRequest)
        #expect(form["auth_code"] == fixtureAuthCode)
        #expect(form.keys.sorted() == ["appkey", "auth_code", "local_id", "sign", "ts"])

        // 过期后不再持有 challenge，下一次轮询不能再发请求。
        _ = try await session.pollOnce()
        #expect(await transport.requests.count == (challengeRemainsActive ? 3 : 2))
    }

    @Test(
        arguments: [
            (true, false, .success(.signedIn(nil))),
            (false, false, .success(.signedOut)),
            (true, true, .failure(.credentialStoreUnavailable))
        ] as [(Bool, Bool, Result<NavigationAuthenticationResult, TVQRLoginFailure>)]
    )
    func storesAllowlistedCredentialOnlyAfterSuccessfulNavigationValidation(
        isLogin: Bool,
        saveFails: Bool,
        expected: Result<NavigationAuthenticationResult, TVQRLoginFailure>
    ) async throws {
        let transport = RecordingAuthTransport(
            responses: [
                try fixtureResponse("qr-generate"),
                try successfulPollResponse(),
                navigationResponse(isLogin: isLogin)
            ]
        )
        let store = MemoryAccountCredentialStore(
            saveError: saveFails ? StubAuthError.storeUnavailable : nil
        )
        let session = TVQRLoginSession(transport: transport, credentialStore: store)

        _ = try await session.requestQRCode()
        let polled = try await session.pollOnce()
        #expect(polled == .awaitingCredentialValidation)
        #expect(polled.description == "awaiting-credential-validation")
        #expect(store.saveCount == 0)

        let outcome: Result<NavigationAuthenticationResult, TVQRLoginFailure>
        do {
            outcome = .success(try await session.validateAndStorePendingCredential())
        } catch let failure as TVQRLoginFailure {
            outcome = .failure(failure)
        }

        #expect(outcome == expected)
        let stored = outcome == .success(.signedIn(nil))
        #expect(store.saveCount == (stored ? 1 : 0))
        #expect(try store.load()?.cookies.count == (stored ? 5 : nil))
        if stored {
            let cookies = try #require(try store.load()).cookies
            #expect(
                cookies.allSatisfy { $0.domain == ".bilibili.com" && $0.path == "/" && $0.isSecure }
            )
            #expect(cookies.first { $0.name == .session }?.isHTTPOnly == true)
            #expect(
                cookies.first?.expiresAt == Date(timeIntervalSince1970: 4_102_444_800)
            )
            // token 来自 `token_info`（fixture 顶层副本的值故意不同，读错位置会失败），到期时刻是收到响应时加
            // `expires_in`（180 天）。
            let token = try #require(try store.load()).appAccessToken
            #expect(token.value == fixtureAppAccessTokenValue)
            #expect(token.refreshToken == fixtureAppRefreshTokenValue)
            let lifetime = token.expiresAt.timeIntervalSinceNow
            #expect(lifetime > 15_552_000 - 60 && lifetime < 15_552_000 + 1)
        }
        let request = try #require(await transport.requests.last)
        #expect(request.url.absoluteString == "https://api.bilibili.com/x/web-interface/nav")
        let cookieHeader = try #require(request.headers["Cookie"])
        #expect(cookieHeader.contains("SESSDATA=FIXTURE_SESSDATA_VALUE"))
        #expect(cookieHeader.contains("bili_jct=FIXTURE_BILI_JCT_VALUE"))
        #expect(!cookieHeader.contains("unknown_cookie"))
        #expect(!cookieHeader.contains("ffffffffffffffffffffffffffffffff"))
    }

    /// 成功正文不合规时不产生候选凭据，也不发 nav、不写 Keychain。
    ///
    /// 不合规指 Cookie 集合不完整、重名、与 `mid` 对不上、不在 B 站作用域，或 token 形状、有效期不对。
    @Test(arguments: IncompleteCredentialCase.allCases)
    func incompleteCredentialFailsClosedWithoutStoring(
        _ failureCase: IncompleteCredentialCase
    ) async throws {
        let transport = RecordingAuthTransport(
            responses: [
                try fixtureResponse("qr-generate"),
                pollSuccessResponse(body: failureCase.body)
            ]
        )
        let store = MemoryAccountCredentialStore()
        let session = TVQRLoginSession(transport: transport, credentialStore: store)

        _ = try await session.requestQRCode()
        #expect(try await session.pollOnce() == .awaitingCredentialValidation)
        await #expect(throws: TVQRLoginFailure.incompleteCredential) {
            try await session.validateAndStorePendingCredential()
        }

        #expect(store.saveCount == 0)
        #expect(await transport.requests.count == 2)
    }

    /// 反例的对照：`IncompleteCredentialCase` 只改一项，未改的正文必须被接受，反例才是在测各自那一项检查。
    @Test
    func completeSuccessBodyIsAccepted() async throws {
        let transport = RecordingAuthTransport(
            responses: [
                try fixtureResponse("qr-generate"),
                pollSuccessResponse(body: IncompleteCredentialCase.completeBody),
                navigationResponse(isLogin: true)
            ]
        )
        let store = MemoryAccountCredentialStore()
        let session = TVQRLoginSession(transport: transport, credentialStore: store)

        _ = try await session.requestQRCode()
        #expect(try await session.pollOnce() == .awaitingCredentialValidation)
        #expect(try await session.validateAndStorePendingCredential() == .signedIn(nil))
        #expect(store.saveCount == 1)
    }

    @Test
    func oldCredentialValidationCannotCompleteAfterNewQRCode() async throws {
        let transport = RecordingAuthTransport(
            responses: [
                try fixtureResponse("qr-generate"),
                try successfulPollResponse(),
                navigationResponse(isLogin: true),
                try fixtureResponse("qr-generate")
            ],
            suspendingRequest: 3
        )
        let store = MemoryAccountCredentialStore()
        let session = TVQRLoginSession(transport: transport, credentialStore: store)

        _ = try await session.requestQRCode()
        _ = try await session.pollOnce()
        let validation = Task {
            try await session.validateAndStorePendingCredential()
        }

        await transport.waitForSuspendedRequest()
        let newState = try await session.requestQRCode()
        #expect(newState.description == "awaiting-scan")

        await transport.resumeSuspendedRequest()
        await #expect(throws: CancellationError.self) {
            try await validation.value
        }
        #expect(await session.state.description == "awaiting-scan")
        #expect(store.saveCount == 0)
    }

    @Test
    func unknownStatusFailsClosedWithoutLeakingPayload() async throws {
        let secret = "TOP_SECRET_SHOULD_NOT_REACH_DIAGNOSTICS"
        let poll = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(
                #"{"code":12345,"message":"\#(secret)","data":{"access_token":"\#(secret)","refresh_token":"\#(secret)"}}"#
                    .utf8
            )
        )
        let session = TVQRLoginSession(
            transport: RecordingAuthTransport(
                responses: [try fixtureResponse("qr-generate"), poll]
            ),
            credentialStore: MemoryAccountCredentialStore()
        )

        _ = try await session.requestQRCode()
        let state = try await session.pollOnce()

        #expect(state == .failed(.unsupportedStatus(12_345)))
        #expect(state.description == "failed-unsupported-status-12345")
        var dumped = ""
        dump(state, to: &dumped)
        #expect(!(String(reflecting: state) + dumped).contains(secret))
        #expect(try await session.pollOnce() == .failed(.noActiveChallenge))
    }

    @Test(arguments: GenerateFailureCase.allCases)
    func generateFailureMapsToSafeState(_ failureCase: GenerateFailureCase) async throws {
        let session = TVQRLoginSession(
            transport: failureCase.transport(),
            credentialStore: MemoryAccountCredentialStore()
        )

        #expect(try await session.requestQRCode() == .failed(failureCase.expected))
    }

    @Test
    func pollingWithoutChallengeDoesNotSendRequest() async throws {
        let transport = RecordingAuthTransport()
        let session = TVQRLoginSession(
            transport: transport,
            credentialStore: MemoryAccountCredentialStore()
        )

        let state = try await session.pollOnce()

        #expect(state == .failed(.noActiveChallenge))
        #expect(await transport.requests.isEmpty)
    }

    @Test
    func cancellationClearsStateAndPropagates() async throws {
        let transport = RecordingAuthTransport(suspendingRequest: 1)
        let session = TVQRLoginSession(
            transport: transport,
            credentialStore: MemoryAccountCredentialStore()
        )
        let task = Task { try await session.requestQRCode() }

        await transport.waitForSuspendedRequest()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await session.state == .signedOut)
        #expect(await transport.suspendedRequestWasCancelled)
    }

    @Test
    func olderQRCodeResultCannotOverwriteNewGeneration() async throws {
        let transport = RecordingAuthTransport(
            responses: [
                try fixtureResponse("qr-generate"),
                try fixtureResponse("qr-generate")
            ],
            suspendingRequest: 1
        )
        let session = TVQRLoginSession(
            transport: transport,
            credentialStore: MemoryAccountCredentialStore()
        )
        let first = Task { try await session.requestQRCode() }

        await transport.waitForSuspendedRequest()
        let secondState = try await session.requestQRCode()
        #expect(secondState.description == "awaiting-scan")

        await transport.resumeSuspendedRequest()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        #expect(await session.state.description == "awaiting-scan")
    }

    @Test
    func olderPollCannotResetNewerPollState() async throws {
        let transport = RecordingAuthTransport(
            responses: [
                try fixtureResponse("qr-generate"),
                try fixtureResponse("qr-poll-not-scanned"),
                try fixtureResponse("qr-poll-not-scanned")
            ],
            suspendingRequest: 2
        )
        let session = TVQRLoginSession(
            transport: transport,
            credentialStore: MemoryAccountCredentialStore()
        )
        _ = try await session.requestQRCode()
        let firstPoll = Task { try await session.pollOnce() }

        await transport.waitForSuspendedRequest()
        let secondState = try await session.pollOnce()
        #expect(secondState.description == "awaiting-scan")

        await transport.resumeSuspendedRequest()
        await #expect(throws: CancellationError.self) {
            try await firstPoll.value
        }
        #expect(await session.state.description == "awaiting-scan")
    }

    enum GenerateFailureCase: CaseIterable, Sendable {
        case offline
        case htmlBody
        case qrCodeHostOutsideAllowlist
        case qrCodeURLWithNonstandardPort
        case qrCodeURLWithFragment
        case qrCodeURLWithOtherPath
        case qrCodeURLForOtherAuthCode
        case qrCodeURLWithExtraQuery
        case malformedAuthCode

        var expected: TVQRLoginFailure {
            switch self {
            case .offline: .network
            case .htmlBody: .nonJSONResponse
            default: .invalidResponse
            }
        }

        func transport() -> RecordingAuthTransport {
            switch self {
            case .offline:
                RecordingAuthTransport(errors: [StubAuthError.offline])
            case .htmlBody:
                RecordingAuthTransport(
                    responses: [
                        HTTPResponse(
                            statusCode: 200,
                            headers: ["Content-Type": "text/html"],
                            body: Data("<html>risk control</html>".utf8)
                        )
                    ]
                )
            case .qrCodeHostOutsideAllowlist:
                Self.generateResponse(
                    url: "https://passport.bilibili.com.evil.invalid" + Self.authURLPath
                )
            case .qrCodeURLWithNonstandardPort:
                Self.generateResponse(url: "https://passport.bilibili.com:8443" + Self.authURLPath)
            case .qrCodeURLWithFragment:
                Self.generateResponse(url: Self.origin + Self.authURLPath + "#fixture")
            case .qrCodeURLWithOtherPath:
                Self.generateResponse(
                    url: Self.origin + "/x/passport-login/web/confirm?auth_code=" + fixtureAuthCode
                )
            case .qrCodeURLForOtherAuthCode:
                Self.generateResponse(
                    url: Self.origin + Self.authPagePath + "?auth_code="
                        + String(repeating: "1", count: 32)
                )
            case .qrCodeURLWithExtraQuery:
                Self.generateResponse(
                    url: Self.origin + Self.authURLPath + "&gourl=https%3A%2F%2Fexample.invalid"
                )
            case .malformedAuthCode:
                Self.generateResponse(
                    url: Self.origin + Self.authPagePath + "?auth_code=FIXTURE",
                    authCode: "FIXTURE"
                )
            }
        }

        private static let origin = "https://passport.bilibili.com"
        private static let authPagePath = "/x/passport-tv-login/h5/qrcode/auth"
        private static let authURLPath = authPagePath + "?auth_code=" + fixtureAuthCode

        private static func generateResponse(
            url: String,
            authCode: String = fixtureAuthCode
        ) -> RecordingAuthTransport {
            RecordingAuthTransport(
                responses: [
                    HTTPResponse(
                        statusCode: 200,
                        headers: ["Content-Type": "application/json"],
                        body: Data(
                            #"{"code":0,"data":{"url":"\#(url)","auth_code":"\#(authCode)"}}"#
                                .utf8
                        )
                    )
                ]
            )
        }
    }

    enum IncompleteCredentialCase: CaseIterable, Sendable {
        case missingWhitelistedCookie
        case duplicatedCookie
        case userIDDoesNotMatchMid
        case domainsWithoutBilibili
        case missingCookieInfo
        case malformedAccessToken
        case malformedRefreshToken
        case nonPositiveTokenLifetime

        var body: String {
            let complete = WebCredentialCookieName.allCases.map(\.rawValue)
            switch self {
            case .missingWhitelistedCookie:
                return Self.successBody(cookies: complete.filter { $0 != "sid" })
            case .duplicatedCookie:
                return Self.successBody(cookies: complete.filter { $0 != "sid" } + ["SESSDATA"])
            case .userIDDoesNotMatchMid:
                return Self.successBody(cookies: complete, mid: 43)
            case .domainsWithoutBilibili:
                return Self.successBody(cookies: complete, domains: [".biligame.com"])
            case .missingCookieInfo:
                return #"{"code":0,"data":{"token_info":\#(Self.tokenInfo())}}"#
            case .malformedAccessToken:
                return Self.successBody(cookies: complete, accessToken: "FIXTURE")
            case .malformedRefreshToken:
                return Self.successBody(cookies: complete, refreshToken: "FIXTURE")
            case .nonPositiveTokenLifetime:
                return Self.successBody(cookies: complete, expiresIn: 0)
            }
        }

        /// 字段齐全、应当被接受的正文；反例都只改其中一项。
        static var completeBody: String {
            successBody(cookies: WebCredentialCookieName.allCases.map(\.rawValue))
        }

        /// 与现场同形的成功正文：token 只在 `token_info` 里，顶层副本不放，读错位置的实现会让对照用例失败。
        private static func successBody(
            cookies names: [String],
            mid: Int = 42,
            domains: [String] = [".bilibili.com"],
            accessToken: String = fixtureAppAccessTokenValue,
            refreshToken: String = fixtureAppRefreshTokenValue,
            expiresIn: Int = 15_552_000
        ) -> String {
            let cookies = names.map { name in
                let value = name == "DedeUserID" ? "42" : "FIXTURE_\(name)_VALUE"
                return #"{"name":"\#(name)","value":"\#(value)","http_only":0,"#
                    + #""expires":4102444800,"secure":0}"#
            }
            let domainList = domains.map { "\"\($0)\"" }.joined(separator: ",")
            let cookieList = cookies.joined(separator: ",")
            let token = tokenInfo(
                mid: mid,
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresIn: expiresIn
            )
            return #"{"code":0,"data":{"token_info":\#(token),"cookie_info":{"#
                + #""cookies":[\#(cookieList)],"domains":[\#(domainList)]}}}"#
        }

        // FIXTURE 假值：access_token 是 32 个 f，refresh_token 是 32 个 0。
        private static func tokenInfo(
            mid: Int = 42,
            accessToken: String = fixtureAppAccessTokenValue,
            refreshToken: String = fixtureAppRefreshTokenValue,
            expiresIn: Int = 15_552_000
        ) -> String {
            #"{"mid":\#(mid),"access_token":"\#(accessToken)","#
                + #""refresh_token":"\#(refreshToken)","expires_in":\#(expiresIn)}"#
        }
    }
}

/// 取码 fixture 里的假 auth_code：全零，满足 32 位十六进制的形状。
let fixtureAuthCode = String(repeating: "0", count: 32)

func successfulPollResponse() throws -> HTTPResponse {
    try fixtureResponse("qr-poll-success")
}

func pollSuccessResponse(body: String) -> HTTPResponse {
    HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(body.utf8)
    )
}

/// 把 urlencoded 正文解析成字典，并核对 `sign` 是按 APP 签名规则对其余字段算出的。
func signedForm(of request: HTTPRequest) throws -> [String: String] {
    let body = try #require(request.body.flatMap { String(data: $0, encoding: .utf8) })
    var components = URLComponents()
    components.percentEncodedQuery = body
    let items = try #require(components.queryItems)
    let form = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    let unsigned = form.filter { $0.key != "sign" && $0.key != "appkey" && $0.key != "ts" }
    let timestamp = try #require(form["ts"].flatMap(Int64.init))
    #expect(BiliAppSigning.signed(unsigned, timestamp: timestamp) == body)
    return form
}

func fixtureResponse(
    _ name: String,
    headers: [String: String] = ["Content-Type": "application/json"]
) throws -> HTTPResponse {
    let url = try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        )
    )
    return HTTPResponse(
        statusCode: 200,
        headers: headers,
        body: try Data(contentsOf: url)
    )
}
