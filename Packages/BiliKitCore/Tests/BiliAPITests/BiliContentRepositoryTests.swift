import BiliAPI
import BiliApplication
import BiliNetworking
import Foundation
import Testing

/// 固定内容类 adapter 共用的错误映射：HTTP 403／412、-352、HTML 风控页与 `v_voucher` 挑战归为受限，
/// 不存在或不可见归为内容不可用，匿名请求的 -101 是需要登录，不支持的媒体归为 `unsupportedMedia`，
/// 非法请求在发出前拒绝，取消原样传播，其余按服务端拒绝、不可用或无效响应分类。
@Suite(.timeLimit(.minutes(1)))
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
        // 匿名请求收到 -101：需要登录，不是业务拒绝，也不是凭据失效。
        (jsonResponse(#"{"code":-101,"message":"fixture"}"#), .authenticationRequired),
        // 不存在或不可见不是风控，也不是可重试的业务拒绝。
        (jsonResponse(#"{"code":-404,"message":"fixture"}"#), .contentUnavailable),
        (jsonResponse(#"{"code":62002,"message":"fixture"}"#), .contentUnavailable),
        (jsonResponse(#"{"code":62004,"message":"fixture"}"#), .contentUnavailable),
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
            .replacingOccurrences(of: #""codecid": 7"#, with: #""codecid": 13"#)
            .replacingOccurrences(of: #""codecid": 12"#, with: #""codecid": 13"#)
            .replacingOccurrences(of: "avc1.64001f", with: "av01.0.08M.08")
            .replacingOccurrences(of: "hev1.1.6.L120.90", with: "av01.0.08M.08")
        let repository = BiliContentRepository(
            client: BiliAPIClient(
                transport: StubTransport(
                    responses: [
                        HTTPResponse(
                            statusCode: fixture.statusCode,
                            headers: fixture.headers,
                            body: Data(body.utf8)
                        )
                    ],
                    answersWBINavOnce: true
                )
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
