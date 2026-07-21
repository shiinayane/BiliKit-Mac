import BiliNetworking
import Foundation
import Testing
@testable import BiliAuth

struct WebQRLoginSessionTests {
    @Test
    func requestsQRCodeAndKeepsRawValuesOutOfDescription() async throws {
        let transport = RecordingAuthTransport(responses: [try fixtureResponse("qr-generate")])
        let session = WebQRLoginSession(transport: transport)

        let state = try await session.requestQRCode()

        guard case let .awaitingScan(qrCode) = state else {
            Issue.record("应进入等待扫码状态")
            return
        }
        #expect(qrCode.host == "account.bilibili.com")
        #expect(qrCode.payload.contains("fixture=1"))
        #expect(state.description == "awaiting-scan")
        #expect(!state.description.contains("FIXTURE_QR_KEY"))
        #expect(!qrCode.description.contains("fixture=1"))
        #expect(!String(reflecting: qrCode).contains("fixture=1"))
        var reflected = ""
        dump(qrCode, to: &reflected)
        #expect(!reflected.contains("fixture=1"))
        let image = try qrCode.makeCGImage(scale: 2)
        #expect(image.width > 0)
        #expect(image.height > 0)

        let request = try #require(await transport.requests.first)
        #expect(request.url.path == "/x/passport-login/web/qrcode/generate")
        #expect(request.url.query == nil)
        #expect(request.headers["Accept"] == "application/json")
    }

    @Test
    func keepsWaitingForObservedNotScannedStatus() async throws {
        let transport = RecordingAuthTransport(
            responses: [
                try fixtureResponse("qr-generate"),
                try fixtureResponse("qr-poll-not-scanned"),
            ]
        )
        let session = WebQRLoginSession(transport: transport)

        _ = try await session.requestQRCode()
        let state = try await session.pollOnce()

        #expect(state.description == "awaiting-scan")
        let requests = await transport.requests
        let pollRequest = try #require(requests.last)
        #expect(pollRequest.url.path == "/x/passport-login/web/qrcode/poll")
        #expect(
            URLComponents(url: pollRequest.url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "qrcode_key" })?
                .value == "FIXTURE_QR_KEY_00000000000000000"
        )

        let redacted = HTTPLogRedactor().redact(url: pollRequest.url)
        #expect(redacted.contains("qrcode_key=%3Credacted%3E"))
        #expect(!redacted.contains("FIXTURE_QR_KEY"))
    }

    @Test
    func entersAwaitingConfirmationForObservedScannedStatus() async throws {
        let transport = RecordingAuthTransport(
            responses: [
                try fixtureResponse("qr-generate"),
                try fixtureResponse("qr-poll-awaiting-confirmation"),
            ]
        )
        let session = WebQRLoginSession(transport: transport)

        _ = try await session.requestQRCode()
        let state = try await session.pollOnce()

        guard case let .awaitingConfirmation(qrCode) = state else {
            Issue.record("86090 应进入等待手机确认状态")
            return
        }
        #expect(qrCode.host == "account.bilibili.com")
        #expect(state.description == "awaiting-confirmation")
        #expect(!state.description.contains("FIXTURE_QR_KEY"))
    }

    @Test
    func entersExpiredForObservedExpiredStatus() async throws {
        let transport = RecordingAuthTransport(
            responses: [
                try fixtureResponse("qr-generate"),
                try fixtureResponse("qr-poll-expired"),
            ]
        )
        let session = WebQRLoginSession(transport: transport)

        _ = try await session.requestQRCode()
        let state = try await session.pollOnce()

        #expect(state == .expired)
        #expect(state.description == "expired")
        #expect(try await session.pollOnce() == .failed(.noActiveChallenge))
    }

    @Test
    func successWaitsForCredentialValidationAndReportsOnlyNames() async throws {
        let success = try fixtureResponse(
            "qr-poll-success",
            headers: [
                "Content-Type": "application/json",
                "Set-Cookie": fixtureSetCookieHeader,
            ]
        )
        let transport = RecordingAuthTransport(
            responses: [try fixtureResponse("qr-generate"), success]
        )
        let session = WebQRLoginSession(transport: transport)

        _ = try await session.requestQRCode()
        let state = try await session.pollOnce()

        guard case let .awaitingCredentialValidation(observation) = state else {
            Issue.record("code=0 应等待登录态校验，不能直接视为已登录")
            return
        }
        #expect(observation.code == 0)
        #expect(observation.urlHost == "passport.biligame.com")
        #expect(observation.urlQueryNames == [
            "DedeUserID", "Expires", "SESSDATA", "bili_jct", "first_domain", "gourl",
        ])
        #expect(observation.refreshTokenPresent)
        #expect(observation.cookieNames == [
            "DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct", "sid",
            "unknown_cookie",
        ])
        #expect(state.description == "awaiting-credential-validation")
        #expect(!String(describing: observation).contains("FIXTURE_VALUE"))
    }

    @Test
    func validatesAllowlistedSetCookieAgainstNavigationEndpoint() async throws {
        let success = try fixtureResponse(
            "qr-poll-success",
            headers: [
                "Content-Type": "application/json",
                "Set-Cookie": fixtureSetCookieHeader,
            ]
        )
        let navigation = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"code":0,"data":{"isLogin":true}}"#.utf8)
        )
        let transport = RecordingAuthTransport(
            responses: [
                try fixtureResponse("qr-generate"),
                success,
                navigation,
            ]
        )
        let session = WebQRLoginSession(transport: transport)

        _ = try await session.requestQRCode()
        _ = try await session.pollOnce()
        let isLoggedIn = try await session.validatePendingCredential()

        #expect(isLoggedIn)
        let request = try #require(await transport.requests.last)
        #expect(request.url.absoluteString == "https://api.bilibili.com/x/web-interface/nav")
        let cookieHeader = try #require(request.headers["Cookie"])
        #expect(cookieHeader.contains("SESSDATA=FIXTURE_SESSDATA_VALUE"))
        #expect(cookieHeader.contains("bili_jct=FIXTURE_BILI_JCT_VALUE"))
        #expect(!cookieHeader.contains("unknown_cookie"))
        #expect(HTTPLogRedactor().redact(headers: request.headers)["Cookie"] == "<redacted>")
    }

    @Test
    func storesCompleteCredentialOnlyAfterSuccessfulNavigationValidation() async throws {
        let success = try fixtureResponse(
            "qr-poll-success",
            headers: [
                "Content-Type": "application/json",
                "Set-Cookie": fixtureSetCookieHeader,
            ]
        )
        let navigation = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"code":0,"data":{"isLogin":true}}"#.utf8)
        )
        let store = MemoryWebCredentialStore()
        let session = WebQRLoginSession(
            transport: RecordingAuthTransport(
                responses: [
                    try fixtureResponse("qr-generate"),
                    success,
                    navigation,
                ]
            ),
            credentialStore: store
        )

        _ = try await session.requestQRCode()
        _ = try await session.pollOnce()
        let stored = try await session.validateAndStorePendingCredential()

        #expect(stored)
        #expect(store.saveCount == 1)
        #expect(try store.load()?.cookies.count == 5)
    }

    @Test
    func rejectedNavigationValidationDoesNotStoreCredential() async throws {
        let success = try fixtureResponse(
            "qr-poll-success",
            headers: [
                "Content-Type": "application/json",
                "Set-Cookie": fixtureSetCookieHeader,
            ]
        )
        let navigation = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"code":0,"data":{"isLogin":false}}"#.utf8)
        )
        let store = MemoryWebCredentialStore()
        let session = WebQRLoginSession(
            transport: RecordingAuthTransport(
                responses: [
                    try fixtureResponse("qr-generate"),
                    success,
                    navigation,
                ]
            ),
            credentialStore: store
        )

        _ = try await session.requestQRCode()
        _ = try await session.pollOnce()
        let stored = try await session.validateAndStorePendingCredential()

        #expect(!stored)
        #expect(store.saveCount == 0)
        #expect(try store.load() == nil)
    }

    @Test
    func keychainFailureCannotReportPersistentLoginSuccess() async throws {
        let success = try fixtureResponse(
            "qr-poll-success",
            headers: [
                "Content-Type": "application/json",
                "Set-Cookie": fixtureSetCookieHeader,
            ]
        )
        let navigation = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"code":0,"data":{"isLogin":true}}"#.utf8)
        )
        let store = MemoryWebCredentialStore(
            saveError: FixtureCredentialStoreError.unavailable
        )
        let session = WebQRLoginSession(
            transport: RecordingAuthTransport(
                responses: [
                    try fixtureResponse("qr-generate"),
                    success,
                    navigation,
                ]
            ),
            credentialStore: store
        )

        _ = try await session.requestQRCode()
        _ = try await session.pollOnce()
        await #expect(throws: WebQRLoginFailure.credentialStoreUnavailable) {
            try await session.validateAndStorePendingCredential()
        }
        #expect(store.saveCount == 0)
    }

    @Test
    func oldCredentialValidationCannotCompleteAfterNewQRCode() async throws {
        let success = try fixtureResponse(
            "qr-poll-success",
            headers: [
                "Content-Type": "application/json",
                "Set-Cookie": fixtureSetCookieHeader,
            ]
        )
        let navigation = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"code":0,"data":{"isLogin":true}}"#.utf8)
        )
        let transport = SupersedingValidationTransport(
            generateResponse: try fixtureResponse("qr-generate"),
            successResponse: success,
            navigationResponse: navigation
        )
        let store = MemoryWebCredentialStore()
        let session = WebQRLoginSession(
            transport: transport,
            credentialStore: store
        )

        _ = try await session.requestQRCode()
        _ = try await session.pollOnce()
        let validation = Task {
            try await session.validateAndStorePendingCredential()
        }

        while !(await transport.validationStarted) {
            await Task.yield()
        }
        let newState = try await session.requestQRCode()
        #expect(newState.description == "awaiting-scan")

        await transport.completeValidation()
        await #expect(throws: CancellationError.self) {
            try await validation.value
        }
        #expect(await session.state.description == "awaiting-scan")
        #expect(store.saveCount == 0)
    }

    @Test
    func rejectsUnknownStatusWithoutLeakingPayload() async throws {
        let transport = RecordingAuthTransport(
            responses: [
                try fixtureResponse("qr-generate"),
                try fixtureResponse("qr-poll-unknown"),
            ]
        )
        let session = WebQRLoginSession(transport: transport)

        _ = try await session.requestQRCode()
        let state = try await session.pollOnce()

        guard case let .failed(.unsupportedStatus(observation)) = state else {
            Issue.record("未知状态应生成安全观察结果")
            return
        }
        #expect(observation.code == 12_345)
        #expect(observation.dataFieldNames == [
            "code", "message", "refresh_token", "timestamp", "url",
        ])
        #expect(observation.urlHost == nil)
        #expect(observation.urlQueryNames.isEmpty)
        #expect(observation.refreshTokenPresent)
        #expect(observation.responseHeaderNames == ["content-type"])
        #expect(observation.cookieNames.isEmpty)
        #expect(state.description == "failed-unsupported-status-12345")
        #expect(!state.description.contains("TOP_SECRET"))
        #expect(!observation.description.contains("TOP_SECRET"))
    }

    @Test
    func observationExposesCookieNamesAndAttributesButNotValues() async throws {
        let poll = HTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Type": "application/json",
                "Set-Cookie": "fixture_cookie=TOP_SECRET_SHOULD_NOT_REACH_DIAGNOSTICS; Path=/; Secure; HttpOnly",
            ],
            body: Data(
                #"{"code":0,"data":{"url":"https://www.bilibili.com/?first_name=TOP_SECRET_SHOULD_NOT_REACH_DIAGNOSTICS&second_name=TOP_SECRET_SHOULD_NOT_REACH_DIAGNOSTICS","refresh_token":"TOP_SECRET_SHOULD_NOT_REACH_DIAGNOSTICS","timestamp":1700000001,"code":12345,"message":"fixture"}}"#.utf8
            )
        )
        let transport = RecordingAuthTransport(
            responses: [try fixtureResponse("qr-generate"), poll]
        )
        let session = WebQRLoginSession(transport: transport)

        _ = try await session.requestQRCode()
        let state = try await session.pollOnce()

        guard case let .failed(.unsupportedStatus(observation)) = state else {
            Issue.record("未知状态应生成安全观察结果")
            return
        }
        #expect(observation.urlScheme == "https")
        #expect(observation.urlHost == "www.bilibili.com")
        #expect(observation.urlQueryNames == ["first_name", "second_name"])
        #expect(observation.refreshTokenPresent)
        #expect(observation.cookieNames == ["fixture_cookie"])
        #expect(observation.cookieAttributeNames.contains("Name"))
        #expect(observation.cookieAttributeNames.contains("Value"))

        let diagnostics = String(describing: observation)
            + String(reflecting: observation)
            + state.description
        #expect(!diagnostics.contains("TOP_SECRET"))
    }

    @Test
    func mapsNetworkFailureToSafeState() async throws {
        let session = WebQRLoginSession(
            transport: RecordingAuthTransport(errors: [StubAuthError.offline])
        )

        let state = try await session.requestQRCode()

        #expect(state == .failed(.network))
    }

    @Test
    func rejectsHTMLBeforeDecoding() async throws {
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/html"],
            body: Data("<html>risk control</html>".utf8)
        )
        let session = WebQRLoginSession(
            transport: RecordingAuthTransport(responses: [response])
        )

        let state = try await session.requestQRCode()

        #expect(state == .failed(.nonJSONResponse))
    }

    @Test
    func cancellationClearsStateAndPropagates() async throws {
        let transport = BlockingAuthTransport()
        let session = WebQRLoginSession(transport: transport)
        let task = Task { try await session.requestQRCode() }

        while !(await transport.hasStarted) {
            await Task.yield()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await session.state == .signedOut)
        #expect(await transport.wasCancelled)
    }

    @Test
    func pollingWithoutChallengeDoesNotSendRequest() async throws {
        let transport = RecordingAuthTransport(responses: [])
        let session = WebQRLoginSession(transport: transport)

        let state = try await session.pollOnce()

        #expect(state == .failed(.noActiveChallenge))
        #expect(await transport.requests.isEmpty)
    }

    @Test
    func rejectsQRCodeURLOutsideExactHostAllowlist() async throws {
        let body = Data(
            #"{"code":0,"data":{"url":"https://account.bilibili.com.evil.invalid/login","qrcode_key":"FIXTURE_QR_KEY_00000000000000000"}}"#.utf8
        )
        let session = WebQRLoginSession(
            transport: RecordingAuthTransport(
                responses: [
                    HTTPResponse(
                        statusCode: 200,
                        headers: ["Content-Type": "application/json"],
                        body: body
                    ),
                ]
            )
        )

        let state = try await session.requestQRCode()

        #expect(state == .failed(.invalidResponse))
    }

    @Test
    func olderQRCodeResultCannotOverwriteNewGeneration() async throws {
        let response = try fixtureResponse("qr-generate")
        let transport = SupersedingAuthTransport(response: response)
        let session = WebQRLoginSession(transport: transport)
        let first = Task { try await session.requestQRCode() }

        while !(await transport.firstRequestStarted) {
            await Task.yield()
        }
        let secondState = try await session.requestQRCode()
        #expect(secondState.description == "awaiting-scan")

        await transport.completeFirstRequest()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        #expect(await session.state.description == "awaiting-scan")
    }

    @Test
    func olderPollCannotResetNewerPollState() async throws {
        let generate = try fixtureResponse("qr-generate")
        let notScanned = try fixtureResponse("qr-poll-not-scanned")
        let transport = SupersedingPollTransport(
            generateResponse: generate,
            pollResponse: notScanned
        )
        let session = WebQRLoginSession(transport: transport)
        _ = try await session.requestQRCode()
        let firstPoll = Task { try await session.pollOnce() }

        while !(await transport.firstPollStarted) {
            await Task.yield()
        }
        let secondState = try await session.pollOnce()
        #expect(secondState.description == "awaiting-scan")

        await transport.completeFirstPoll()
        await #expect(throws: CancellationError.self) {
            try await firstPoll.value
        }
        #expect(await session.state.description == "awaiting-scan")
    }
}

private actor RecordingAuthTransport: HTTPTransport {
    private var queuedResponses: [HTTPResponse]
    private var queuedErrors: [any Error]
    private(set) var requests: [HTTPRequest] = []

    init(
        responses: [HTTPResponse] = [],
        errors: [any Error] = []
    ) {
        queuedResponses = responses
        queuedErrors = errors
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if !queuedErrors.isEmpty {
            throw queuedErrors.removeFirst()
        }
        guard !queuedResponses.isEmpty else {
            throw StubAuthError.missingResponse
        }
        return queuedResponses.removeFirst()
    }
}

private actor BlockingAuthTransport: HTTPTransport {
    private(set) var hasStarted = false
    private(set) var wasCancelled = false

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        hasStarted = true
        do {
            try await Task.sleep(for: .seconds(60))
            throw StubAuthError.missingResponse
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }
}

private actor SupersedingAuthTransport: HTTPTransport {
    private let response: HTTPResponse
    private var requestCount = 0
    private var firstContinuation: CheckedContinuation<HTTPResponse, any Error>?
    private(set) var firstRequestStarted = false

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestCount += 1
        guard requestCount == 1 else { return response }
        firstRequestStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            firstContinuation = continuation
        }
    }

    func completeFirstRequest() {
        firstContinuation?.resume(returning: response)
        firstContinuation = nil
    }
}

private actor SupersedingPollTransport: HTTPTransport {
    private let generateResponse: HTTPResponse
    private let pollResponse: HTTPResponse
    private var requestCount = 0
    private var firstPollContinuation: CheckedContinuation<HTTPResponse, any Error>?
    private(set) var firstPollStarted = false

    init(
        generateResponse: HTTPResponse,
        pollResponse: HTTPResponse
    ) {
        self.generateResponse = generateResponse
        self.pollResponse = pollResponse
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestCount += 1
        if requestCount == 1 { return generateResponse }
        if requestCount > 2 { return pollResponse }
        firstPollStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            firstPollContinuation = continuation
        }
    }

    func completeFirstPoll() {
        firstPollContinuation?.resume(returning: pollResponse)
        firstPollContinuation = nil
    }
}

private actor SupersedingValidationTransport: HTTPTransport {
    private let generateResponse: HTTPResponse
    private let successResponse: HTTPResponse
    private let navigationResponse: HTTPResponse
    private var requestCount = 0
    private var validationContinuation: CheckedContinuation<HTTPResponse, any Error>?
    private(set) var validationStarted = false

    init(
        generateResponse: HTTPResponse,
        successResponse: HTTPResponse,
        navigationResponse: HTTPResponse
    ) {
        self.generateResponse = generateResponse
        self.successResponse = successResponse
        self.navigationResponse = navigationResponse
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestCount += 1
        switch requestCount {
        case 1, 4:
            return generateResponse
        case 2:
            return successResponse
        case 3:
            validationStarted = true
            return try await withCheckedThrowingContinuation { continuation in
                validationContinuation = continuation
            }
        default:
            throw StubAuthError.missingResponse
        }
    }

    func completeValidation() {
        validationContinuation?.resume(returning: navigationResponse)
        validationContinuation = nil
    }
}

private enum StubAuthError: Error {
    case offline
    case missingResponse
}

private enum FixtureCredentialStoreError: Error {
    case unavailable
}

private let fixtureSetCookieHeader = [
    "DedeUserID=FIXTURE_USER_ID_VALUE; Domain=.bilibili.com; Path=/; Secure; Expires=Wed, 21 Oct 2099 07:28:00 GMT",
    "DedeUserID__ckMd5=FIXTURE_USER_HASH_VALUE; Domain=.bilibili.com; Path=/; Secure; Expires=Wed, 21 Oct 2099 07:28:00 GMT",
    "SESSDATA=FIXTURE_SESSDATA_VALUE; Domain=.bilibili.com; Path=/; Secure; HttpOnly; Expires=Wed, 21 Oct 2099 07:28:00 GMT",
    "bili_jct=FIXTURE_BILI_JCT_VALUE; Domain=.bilibili.com; Path=/; Secure; Expires=Wed, 21 Oct 2099 07:28:00 GMT",
    "sid=FIXTURE_SID_VALUE; Domain=.bilibili.com; Path=/; Secure; Expires=Wed, 21 Oct 2099 07:28:00 GMT",
    "unknown_cookie=FIXTURE_UNKNOWN_VALUE; Domain=.bilibili.com; Path=/; Secure; Expires=Wed, 21 Oct 2099 07:28:00 GMT",
].joined(separator: ", ")

private func fixtureResponse(
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
