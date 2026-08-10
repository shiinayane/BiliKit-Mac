import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

@Suite
struct BiliDanmakuRepositoryTests {
    private let identity = PlaybackItemIdentity(
        bvid: "BV1DanmakuFixture",
        cid: 700_001
    )

    @Test
    func productionDecoderMapsMinimalFixtureAndBuildsWBIAnonymousRequest() async throws {
        let transport = DanmakuRecordingTransport(
            responses: [
                try jsonFixtureResponse("nav"),
                try binaryFixtureResponse("danmaku-segment-minimal"),
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            timestampProvider: { 1_700_000_000 }
        )
        let repository = BiliDanmakuRepository(client: client)

        let segment = try await repository.segment(index: 1, for: identity)
        let event = try #require(segment.events.first)

        #expect(segment.index == 1)
        #expect(segment.events.count == 1)
        #expect(event.id == "fixture-1001")
        #expect(event.timeSeconds == 1.5)
        #expect(event.mode == .scrolling)
        #expect(event.text == "fixture danmaku")
        #expect(event.fontSize == 25)
        #expect(event.colorRGB == 0xFF_FF_FF)
        #expect(event.weight == 5)
        #expect(event.description == "DanmakuEvent(redacted)")

        let requests = await transport.requests()
        #expect(
            requests.map(\.url.path) == [
                "/x/web-interface/nav",
                "/x/v2/dm/wbi/web/seg.so",
            ]
        )
        #expect(requests[0].headers["Cookie"] == nil)
        let request = requests[1]
        let query = try #require(
            URLComponents(
                url: request.url,
                resolvingAgainstBaseURL: false
            )?.queryItems
        )
        #expect(
            Set(query.map(\.name)) == [
                "type", "oid", "segment_index", "wts", "w_rid",
            ]
        )
        #expect(query.first(where: { $0.name == "type" })?.value == "1")
        #expect(query.first(where: { $0.name == "oid" })?.value == "700001")
        #expect(query.first(where: { $0.name == "segment_index" })?.value == "1")
        #expect(query.first(where: { $0.name == "wts" })?.value == "1700000000")
        #expect(query.first(where: { $0.name == "w_rid" })?.value?.count == 32)
        #expect(request.headers["Accept"] == "application/octet-stream")
        #expect(request.headers["Cookie"] == nil)
    }

    @Test
    func productionAuthorizesOnlyTheWBIRequestWhenCredentialIsAvailable()
        async throws
    {
        let transport = DanmakuRecordingTransport(
            responses: [
                try jsonFixtureResponse("nav"),
                try binaryFixtureResponse("danmaku-segment-minimal"),
            ]
        )
        let authorizer = DanmakuRecordingAuthorizer()
        let repository = BiliDanmakuRepository(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: authorizer,
                timestampProvider: { 1_700_000_000 }
            )
        )

        let segment = try await repository.segment(index: 1, for: identity)

        #expect(segment.events.count == 1)
        #expect(await authorizer.capturedPaths() == ["/x/v2/dm/wbi/web/seg.so"])
        let requests = await transport.requests()
        #expect(requests[0].headers["Cookie"] == nil)
        #expect(requests[1].headers["Cookie"] == "FIXTURE_AUTHORIZED")
    }

    @Test
    func productionFallsBackToTheSameWBIRequestWhenCredentialIsMissing()
        async throws
    {
        let transport = DanmakuRecordingTransport(
            responses: [
                try jsonFixtureResponse("nav"),
                try binaryFixtureResponse("danmaku-segment-minimal"),
            ]
        )
        let authorizer = DanmakuRecordingAuthorizer(failureKind: .missingCredential)
        let repository = BiliDanmakuRepository(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: authorizer,
                timestampProvider: { 1_700_000_000 }
            )
        )

        let segment = try await repository.segment(index: 1, for: identity)

        #expect(segment.events.count == 1)
        #expect(await authorizer.capturedPaths() == ["/x/v2/dm/wbi/web/seg.so"])
        let requests = await transport.requests()
        #expect(
            requests.map(\.url.path) == [
                "/x/web-interface/nav",
                "/x/v2/dm/wbi/web/seg.so",
            ]
        )
        #expect(requests.allSatisfy { $0.headers["Cookie"] == nil })
    }

    @Test
    func invalidCredentialFailsBeforeTheWBIRequestIsSent() async throws {
        let transport = DanmakuRecordingTransport(
            responses: [try jsonFixtureResponse("nav")]
        )
        let authorizer = DanmakuRecordingAuthorizer(failureKind: .invalidCredential)
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer,
            timestampProvider: { 1_700_000_000 }
        )

        await #expect(throws: BiliAPIError.authenticationInvalid) {
            try await client.danmakuSegmentData(index: 1, for: identity)
        }

        #expect(await transport.requests().map(\.url.path) == ["/x/web-interface/nav"])
    }

    @Test
    func cancellationDuringAuthorizationStopsBeforeTheWBIRequestIsSent() async throws {
        let transport = DanmakuRecordingTransport(
            responses: [
                try jsonFixtureResponse("nav"),
                try binaryFixtureResponse("danmaku-segment-minimal"),
            ]
        )
        let authorizer = DanmakuSuspendingAuthorizer()
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer,
            timestampProvider: { 1_700_000_000 }
        )
        let task = Task {
            try await client.danmakuSegmentData(index: 1, for: identity)
        }
        await authorizer.waitUntilAuthorizationStarts()

        task.cancel()
        await authorizer.resumeAuthorization()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(
            await transport.requests().map(\.url.path) == ["/x/web-interface/nav"]
        )
    }

    @Test
    func remoteAuthenticationInvalidationIsRecognizedBeforeProtobufDecoding()
        async throws
    {
        let repository = BiliDanmakuRepository(
            client: BiliAPIClient(
                transport: DanmakuRecordingTransport(
                    responses: [
                        try jsonFixtureResponse("nav"),
                        HTTPResponse(
                            statusCode: 200,
                            headers: ["Content-Type": "application/json"],
                            body: Data(#"{"code":-101,"message":"fixture"}"#.utf8)
                        ),
                    ]
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        await #expect(throws: DanmakuApplicationError.authenticationInvalid) {
            try await repository.segment(index: 1, for: identity)
        }
    }

    @Test
    func wbiRejectionRefreshesTheKeyOnce() async throws {
        let transport = DanmakuRecordingTransport(
            responses: [
                try jsonFixtureResponse("nav"),
                HTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"code":-403,"message":"fixture"}"#.utf8)
                ),
                try jsonFixtureResponse("nav-refreshed"),
                try binaryFixtureResponse("danmaku-segment-minimal"),
            ]
        )
        let repository = BiliDanmakuRepository(
            client: BiliAPIClient(
                transport: transport,
                timestampProvider: { 1_700_000_000 }
            )
        )

        let segment = try await repository.segment(index: 1, for: identity)

        #expect(segment.events.count == 1)
        #expect(
            await transport.requests().map(\.url.path) == [
                "/x/web-interface/nav",
                "/x/v2/dm/wbi/web/seg.so",
                "/x/web-interface/nav",
                "/x/v2/dm/wbi/web/seg.so",
            ]
        )
    }

    #if DEBUG
        @Test
        func debugPoolProbeSummarizesTheProductionResponse() async throws {
            let client = BiliAPIClient(
                transport: DanmakuRecordingTransport(
                    responses: [
                        try jsonFixtureResponse("nav"),
                        try binaryFixtureResponse("danmaku-segment-minimal"),
                    ]
                ),
                timestampProvider: { 1_700_000_000 }
            )

            let summary = try await client.danmakuPoolProbe(
                index: 1,
                for: identity
            )

            #expect(summary.rawEventCount == 1)
            #expect(summary.basicEventCount == 1)
            #expect(summary.rawModeCounts == [1: 1])
            #expect(summary.bytes > 0)
        }
    #endif

    @Test
    func truncatedFixtureFailsClosed() async throws {
        let repository = try repository(
            response: try binaryFixtureResponse("danmaku-segment-truncated")
        )

        await #expect(throws: DanmakuApplicationError.invalidResponse) {
            try await repository.segment(index: 1, for: identity)
        }
    }

    @Test
    func errorBodiesAndWrongContentTypesFailBeforeDecoder() async throws {
        for response in [
            HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"code":-412}"#.utf8)
            ),
            HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/octet-stream"],
                body: Data(" \n{\"code\":-412}\n".utf8)
            ),
            HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/octet-stream"],
                body: Data(" \n<!doctype html><title>blocked</title>".utf8)
            ),
        ] {
            let repository = try repository(response: response)
            await #expect(throws: DanmakuApplicationError.requestRestricted) {
                try await repository.segment(index: 1, for: identity)
            }
        }
    }

    @Test
    func validProtobufLengthByteThatLooksLikeJSONIsAccepted() async throws {
        var element = Bilikit_Danmaku_Element()
        element.id = 1
        element.progressMilliseconds = 1_000
        element.mode = 1
        element.fontSize = 25
        element.colorRgb = 0xFF_FF_FF
        element.content = String(repeating: "x", count: 96)
        element.weight = 5
        element.idString = "fixture"

        let encodedElement = try element.serializedData()
        #expect(encodedElement.count == 123)

        var payload = Bilikit_Danmaku_SegmentReply()
        payload.elements = [element]
        let body = try payload.serializedData()
        #expect(body.starts(with: [0x0A, 0x7B]))

        let repository = try repository(
            response: HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/octet-stream"],
                body: body
            )
        )
        let segment = try await repository.segment(index: 1, for: identity)

        #expect(segment.events.count == 1)
        #expect(segment.events.first?.id == "fixture")
    }

    @Test
    func emptyAndOversizedResponsesFailClosed() async throws {
        let responses = [
            HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/octet-stream"],
                body: Data()
            ),
            HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/octet-stream"],
                body: Data(repeating: 0, count: 2 * 1_024 * 1_024 + 1)
            ),
        ]

        for response in responses {
            let repository = try repository(response: response)
            await #expect(throws: DanmakuApplicationError.invalidResponse) {
                try await repository.segment(index: 1, for: identity)
            }
        }
    }

    @Test
    func decoderDropsUnsupportedModesAndBlankContent() async throws {
        var unsupported = Bilikit_Danmaku_Element()
        unsupported.id = 1
        unsupported.progressMilliseconds = 1_000
        unsupported.mode = 7
        unsupported.fontSize = 25
        unsupported.colorRgb = 0xFF_FF_FF
        unsupported.content = "advanced fixture"
        var valid = unsupported
        valid.id = 2
        valid.idString = "fixture-valid"
        valid.mode = 5
        valid.content = "top fixture"
        var blank = valid
        blank.id = 3
        blank.idString = "fixture-blank"
        blank.content = "\u{00A0}\n"
        var payload = Bilikit_Danmaku_SegmentReply()
        payload.elements = [unsupported, blank, valid]

        let events = try DanmakuPayloadDecoder.events(
            from: payload.serializedData()
        )
        #expect(events.count == 1)
        #expect(events.first?.mode == .top)

        payload.elements = [blank]
        let blankEvents = try DanmakuPayloadDecoder.events(
            from: payload.serializedData()
        )
        #expect(blankEvents.isEmpty)
    }

    @Test
    func decoderStillRejectsMissingRequiredFields() throws {
        var missingID = Bilikit_Danmaku_Element()
        missingID.progressMilliseconds = 1_000
        missingID.mode = 1
        missingID.fontSize = 25
        missingID.colorRgb = 0xFF_FF_FF
        missingID.content = "fixture text"
        var payload = Bilikit_Danmaku_SegmentReply()
        payload.elements = [missingID]

        #expect(throws: BiliAPIError.invalidDanmakuData) {
            try DanmakuPayloadDecoder.events(from: payload.serializedData())
        }
    }

    @Test
    func decoderNormalizesBaseColorRGBWithoutDroppingTheEvent() throws {
        var element = Bilikit_Danmaku_Element()
        element.id = 4
        element.progressMilliseconds = 1_000
        element.mode = 1
        element.fontSize = 25
        element.colorRgb = 0xAB12_3456
        element.content = "colored fixture"
        var payload = Bilikit_Danmaku_SegmentReply()
        payload.elements = [element]

        let events = try DanmakuPayloadDecoder.events(
            from: payload.serializedData()
        )
        let event = try #require(events.first)

        #expect(events.count == 1)
        #expect(event.colorRGB == 0x12_3456)
    }

    @Test
    func decoderUsesOnlySupportedReceivedFontSizes() throws {
        let sizes: [Int32] = [0, 12, 18, 25, 36, 45, 64]
        var payload = Bilikit_Danmaku_SegmentReply()
        payload.elements = sizes.enumerated().map { index, fontSize in
            var element = Bilikit_Danmaku_Element()
            element.id = Int64(index + 1)
            element.progressMilliseconds = 1_000
            element.mode = 1
            element.fontSize = fontSize
            element.colorRgb = 0xFF_FF_FF
            element.content = "font size fixture"
            return element
        }

        let events = try DanmakuPayloadDecoder.events(
            from: payload.serializedData()
        )

        #expect(events.map(\.fontSize) == [25, 25, 18, 25, 36, 25, 25])
    }

    @Test
    func cancellationIsNotCollapsedIntoTransportFailure() async {
        let client = BiliAPIClient(transport: DanmakuCancellationTransport())
        let repository = BiliDanmakuRepository(client: client)
        let task = Task {
            try await repository.segment(index: 1, for: identity)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private func repository(response: HTTPResponse) throws -> BiliDanmakuRepository {
        BiliDanmakuRepository(
            client: BiliAPIClient(
                transport: DanmakuRecordingTransport(
                    responses: [
                        try jsonFixtureResponse("nav"),
                        response,
                    ]
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )
    }

    private func binaryFixtureResponse(_ name: String) throws -> HTTPResponse {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "hex",
                subdirectory: "Fixtures"
            )
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        let digits = text.filter { $0.isHexDigit }
        var body = Data()
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            let byte = try #require(UInt8(digits[index..<next], radix: 16))
            body.append(byte)
            index = next
        }
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/octet-stream"],
            body: body
        )
    }

    private func jsonFixtureResponse(_ name: String) throws -> HTTPResponse {
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
}

private actor DanmakuRecordingTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private var capturedRequests: [HTTPRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        capturedRequests.append(request)
        guard !responses.isEmpty else {
            throw DanmakuTestError.missingResponse
        }
        return responses.removeFirst()
    }

    func requests() -> [HTTPRequest] {
        capturedRequests
    }
}

private actor DanmakuCancellationTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await Task.sleep(for: .seconds(30))
        throw DanmakuTestError.missingResponse
    }
}

private actor DanmakuRecordingAuthorizer: HTTPRequestAuthorizing {
    private let failureKind: HTTPRequestAuthorizationFailureKind?
    private var paths: [String] = []

    init(failureKind: HTTPRequestAuthorizationFailureKind? = nil) {
        self.failureKind = failureKind
    }

    func authorize(_ request: HTTPRequest) throws -> HTTPRequest {
        paths.append(request.url.path)
        if let failureKind {
            throw DanmakuAuthorizationFailure(
                authorizationFailureKind: failureKind
            )
        }
        var headers = request.headers
        headers["Cookie"] = "FIXTURE_AUTHORIZED"
        return HTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: request.body
        )
    }

    func capturedPaths() -> [String] {
        paths
    }
}

private actor DanmakuSuspendingAuthorizer: HTTPRequestAuthorizing {
    private var authorizationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var authorizationContinuation: CheckedContinuation<Void, Never>?

    func authorize(_ request: HTTPRequest) async -> HTTPRequest {
        authorizationStarted = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
        }
        var headers = request.headers
        headers["Cookie"] = "FIXTURE_AUTHORIZED"
        return HTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: request.body
        )
    }

    func waitUntilAuthorizationStarts() async {
        guard !authorizationStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeAuthorization() {
        authorizationContinuation?.resume()
        authorizationContinuation = nil
    }
}

private struct DanmakuAuthorizationFailure: HTTPRequestAuthorizationFailure {
    let authorizationFailureKind: HTTPRequestAuthorizationFailureKind
}

private enum DanmakuTestError: Error {
    case missingResponse
}
