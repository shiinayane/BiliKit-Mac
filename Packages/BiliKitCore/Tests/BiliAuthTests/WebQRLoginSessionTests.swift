import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth

@Suite(.timeLimit(.minutes(1)))
struct WebQRLoginSessionTests {
    @Test
    func requestsQRCodeAndKeepsRawValuesOutOfDescription() async throws {
        let transport = RecordingAuthTransport(responses: [try fixtureResponse("qr-generate")])
        let session = WebQRLoginSession(transport: transport)

        let state = try await session.requestQRCode()

        guard case .awaitingScan(let qrCode) = state else {
            Issue.record("应进入等待扫码状态")
            return
        }
        #expect(URL(string: qrCode.payload)?.host == "account.bilibili.com")
        #expect(qrCode.payload.contains("fixture=1"))
        #expect(state.description == "awaiting-scan")
        #expect(!state.description.contains("FIXTURE_QR_KEY"))
        #expect(!qrCode.description.contains("fixture=1"))
        #expect(!String(reflecting: qrCode).contains("fixture=1"))
        var reflected = ""
        dump(qrCode, to: &reflected)
        #expect(!reflected.contains("fixture=1"))

        let request = try #require(await transport.requests.first)
        #expect(request.url.path == "/x/passport-login/web/qrcode/generate")
        #expect(request.url.query == nil)
        #expect(request.headers["Accept"] == "application/json")
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
        let session = WebQRLoginSession(transport: transport)

        _ = try await session.requestQRCode()
        let state = try await session.pollOnce()

        #expect(state.description == expectedDescription)
        #expect(!state.description.contains("FIXTURE_QR_KEY"))
        let pollRequest = try #require(await transport.requests.last)
        #expect(pollRequest.url.path == "/x/passport-login/web/qrcode/poll")
        #expect(
            URLComponents(url: pollRequest.url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "qrcode_key" })?
                .value == "FIXTURE_QR_KEY_00000000000000000"
        )

        // 过期后不再持有 challenge，下一次轮询不能再发请求。
        _ = try await session.pollOnce()
        #expect(await transport.requests.count == (challengeRemainsActive ? 3 : 2))
    }

    @Test(
        arguments: [
            (true, false, .success(.signedIn(nil))),
            (false, false, .success(.signedOut)),
            (true, true, .failure(.credentialStoreUnavailable))
        ] as [(Bool, Bool, Result<NavigationAuthenticationResult, WebQRLoginFailure>)]
    )
    func storesAllowlistedCredentialOnlyAfterSuccessfulNavigationValidation(
        isLogin: Bool,
        saveFails: Bool,
        expected: Result<NavigationAuthenticationResult, WebQRLoginFailure>
    ) async throws {
        let transport = RecordingAuthTransport(
            responses: [
                try fixtureResponse("qr-generate"),
                try successfulPollResponse(),
                navigationResponse(isLogin: isLogin)
            ]
        )
        let store = MemoryWebCredentialStore(
            saveError: saveFails ? StubAuthError.storeUnavailable : nil
        )
        let session = WebQRLoginSession(transport: transport, credentialStore: store)

        _ = try await session.requestQRCode()
        let polled = try await session.pollOnce()
        #expect(polled == .awaitingCredentialValidation)
        #expect(polled.description == "awaiting-credential-validation")
        #expect(store.saveCount == 0)

        let outcome: Result<NavigationAuthenticationResult, WebQRLoginFailure>
        do {
            outcome = .success(try await session.validateAndStorePendingCredential())
        } catch let failure as WebQRLoginFailure {
            outcome = .failure(failure)
        }

        #expect(outcome == expected)
        let stored = outcome == .success(.signedIn(nil))
        #expect(store.saveCount == (stored ? 1 : 0))
        #expect(try store.load()?.cookies.count == (stored ? 5 : nil))
        let request = try #require(await transport.requests.last)
        #expect(request.url.absoluteString == "https://api.bilibili.com/x/web-interface/nav")
        let cookieHeader = try #require(request.headers["Cookie"])
        #expect(cookieHeader.contains("SESSDATA=FIXTURE_SESSDATA_VALUE"))
        #expect(cookieHeader.contains("bili_jct=FIXTURE_BILI_JCT_VALUE"))
        #expect(!cookieHeader.contains("unknown_cookie"))
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
        let store = MemoryWebCredentialStore()
        let session = WebQRLoginSession(transport: transport, credentialStore: store)

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
            headers: [
                "Content-Type": "application/json",
                "Set-Cookie": "fixture_cookie=\(secret); Path=/; Secure; HttpOnly"
            ],
            body: Data(
                #"{"code":0,"data":{"url":"https://www.bilibili.com/?first_name=\#(secret)","refresh_token":"\#(secret)","timestamp":1700000001,"code":12345,"message":"\#(secret)"}}"#
                    .utf8
            )
        )
        let session = WebQRLoginSession(
            transport: RecordingAuthTransport(
                responses: [try fixtureResponse("qr-generate"), poll]
            )
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
        let session = WebQRLoginSession(transport: failureCase.transport())

        #expect(try await session.requestQRCode() == .failed(failureCase.expected))
    }

    @Test
    func pollingWithoutChallengeDoesNotSendRequest() async throws {
        let transport = RecordingAuthTransport()
        let session = WebQRLoginSession(transport: transport)

        let state = try await session.pollOnce()

        #expect(state == .failed(.noActiveChallenge))
        #expect(await transport.requests.isEmpty)
    }

    @Test
    func cancellationClearsStateAndPropagates() async throws {
        let transport = RecordingAuthTransport(suspendingRequest: 1)
        let session = WebQRLoginSession(transport: transport)
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
        let session = WebQRLoginSession(transport: transport)
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
        let session = WebQRLoginSession(transport: transport)
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

        var expected: WebQRLoginFailure {
            switch self {
            case .offline: .network
            case .htmlBody: .nonJSONResponse
            case .qrCodeHostOutsideAllowlist: .invalidResponse
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
                RecordingAuthTransport(
                    responses: [
                        HTTPResponse(
                            statusCode: 200,
                            headers: ["Content-Type": "application/json"],
                            body: Data(
                                #"{"code":0,"data":{"url":"https://account.bilibili.com.evil.invalid/login","qrcode_key":"FIXTURE_QR_KEY_00000000000000000"}}"#
                                    .utf8
                            )
                        )
                    ]
                )
            }
        }
    }
}

let fixtureSetCookieHeader = [
    "DedeUserID=FIXTURE_USER_ID_VALUE; Domain=.bilibili.com; Path=/; Secure; Expires=Wed, 21 Oct 2099 07:28:00 GMT",
    "DedeUserID__ckMd5=FIXTURE_USER_HASH_VALUE; Domain=.bilibili.com; Path=/; Secure; Expires=Wed, 21 Oct 2099 07:28:00 GMT",
    "SESSDATA=FIXTURE_SESSDATA_VALUE; Domain=.bilibili.com; Path=/; Secure; HttpOnly; Expires=Wed, 21 Oct 2099 07:28:00 GMT",
    "bili_jct=FIXTURE_BILI_JCT_VALUE; Domain=.bilibili.com; Path=/; Secure; Expires=Wed, 21 Oct 2099 07:28:00 GMT",
    "sid=FIXTURE_SID_VALUE; Domain=.bilibili.com; Path=/; Secure; Expires=Wed, 21 Oct 2099 07:28:00 GMT",
    "unknown_cookie=FIXTURE_UNKNOWN_VALUE; Domain=.bilibili.com; Path=/; Secure; Expires=Wed, 21 Oct 2099 07:28:00 GMT"
].joined(separator: ", ")

func successfulPollResponse() throws -> HTTPResponse {
    try fixtureResponse(
        "qr-poll-success",
        headers: [
            "Content-Type": "application/json",
            "Set-Cookie": fixtureSetCookieHeader
        ]
    )
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
