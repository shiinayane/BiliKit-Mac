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

        #expect(state == .failed(.unsupportedStatus(12_345)))
        #expect(state.description == "failed-unsupported-status-12345")
        #expect(!state.description.contains("TOP_SECRET"))
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

private enum StubAuthError: Error {
    case offline
    case missingResponse
}

private func fixtureResponse(_ name: String) throws -> HTTPResponse {
    let url = try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        )
    )
    return HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: try Data(contentsOf: url)
    )
}
