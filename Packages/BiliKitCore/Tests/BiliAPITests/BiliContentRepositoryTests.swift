import BiliAPI
import BiliApplication
import BiliNetworking
import Foundation
import Testing

struct BiliContentRepositoryTests {
    @Test
    func mapsInvalidRequestAtAdapterBoundary() async {
        let transport = StubTransport(responses: [])
        let repository = BiliContentRepository(
            client: BiliAPIClient(transport: transport)
        )

        await #expect(throws: ContentApplicationError.invalidRequest) {
            try await repository.popular(page: 0, pageSize: 20)
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    @Test(arguments: [
        (HTTPResponse(statusCode: 403, body: Data()), ContentApplicationError.requestRestricted),
        (HTTPResponse(statusCode: 412, body: Data()), .requestRestricted),
        (jsonResponse(#"{"code":-352,"message":"blocked"}"#), .requestRestricted),
        (htmlRiskControlResponse(), .requestRestricted),
        (jsonResponse(#"{"code":0,"data":{"v_voucher":"voucher_fixture"}}"#), .requestRestricted),
        (jsonResponse(#"{"code":-500,"message":"fixture"}"#), .serviceRejected(code: -500)),
        (HTTPResponse(statusCode: 500, body: Data()), .unavailable),
        (jsonResponse("{"), .invalidResponse)
    ])
    func mapsFailedPopularResponseAtAdapterBoundary(
        response: HTTPResponse,
        expected: ContentApplicationError
    ) async {
        let repository = BiliContentRepository(
            client: BiliAPIClient(transport: StubTransport(responses: [response]))
        )

        await #expect(throws: expected) {
            try await repository.popular(page: 1, pageSize: 20)
        }
    }

    @Test
    func mapsUnsupportedPlaybackAtAdapterBoundary() async throws {
        let fixture = try fixtureResponse("playurl")
        let body = String(decoding: fixture.body, as: UTF8.self)
            .replacingOccurrences(of: #""codecid": 7"#, with: #""codecid": 12"#)
            .replacingOccurrences(of: "avc1.64001f", with: "hev1.1.6.L120.90")
        let repository = BiliContentRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [
                    try fixtureResponse("nav"),
                    HTTPResponse(
                        statusCode: fixture.statusCode,
                        headers: fixture.headers,
                        body: Data(body.utf8)
                    )
                ])
            )
        )

        await #expect(throws: ContentApplicationError.unsupportedMedia) {
            try await repository.playback(
                for: "BV1FixtureA1",
                cid: 900_001
            )
        }
    }

    @Test
    func preservesCancellationAtAdapterBoundary() async {
        let repository = BiliContentRepository(
            client: BiliAPIClient(transport: StubTransport([.cancellation]))
        )

        await #expect(throws: CancellationError.self) {
            try await repository.popular(page: 1, pageSize: 20)
        }
    }
}
