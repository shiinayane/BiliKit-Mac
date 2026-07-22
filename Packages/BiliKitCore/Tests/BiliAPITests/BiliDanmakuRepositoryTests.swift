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
    func productionDecoderMapsMinimalFixtureAndBuildsAnonymousRequest() async throws {
        let transport = DanmakuRecordingTransport(
            responses: [try binaryFixtureResponse("danmaku-segment-minimal")]
        )
        let repository = BiliDanmakuRepository(
            client: BiliAPIClient(transport: transport)
        )

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

        let request = try #require(await transport.requests().first)
        #expect(request.url.path == "/x/v2/dm/web/seg.so")
        #expect(request.url.query?.contains("type=1") == true)
        #expect(request.url.query?.contains("oid=700001") == true)
        #expect(request.url.query?.contains("segment_index=1") == true)
        #expect(request.headers["Accept"] == "application/octet-stream")
        #expect(request.headers["Cookie"] == nil)
    }

    @Test
    func truncatedFixtureFailsClosed() async throws {
        let repository = repository(
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
                body: Data("<!doctype html><title>blocked</title>".utf8)
            ),
        ] {
            let repository = repository(response: response)
            await #expect(throws: DanmakuApplicationError.requestRestricted) {
                try await repository.segment(index: 1, for: identity)
            }
        }
    }

    @Test
    func emptyAndOversizedResponsesFailClosed() async {
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
            let repository = repository(response: response)
            await #expect(throws: DanmakuApplicationError.invalidResponse) {
                try await repository.segment(index: 1, for: identity)
            }
        }
    }

    @Test
    func decoderDropsUnsupportedModesButRejectsMissingRequiredFields() async throws {
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
        var payload = Bilikit_Danmaku_SegmentReply()
        payload.elements = [unsupported, valid]

        let events = try DanmakuPayloadDecoder.events(
            from: payload.serializedData()
        )
        #expect(events.count == 1)
        #expect(events.first?.mode == .top)

        valid.content = ""
        payload.elements = [valid]
        #expect(throws: BiliAPIError.invalidDanmakuData) {
            try DanmakuPayloadDecoder.events(from: payload.serializedData())
        }
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

    private func repository(response: HTTPResponse) -> BiliDanmakuRepository {
        BiliDanmakuRepository(
            client: BiliAPIClient(
                transport: DanmakuRecordingTransport(responses: [response])
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

private enum DanmakuTestError: Error {
    case missingResponse
}
