import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 视频详情、评论、字幕目录与弹幕分段与其他签名读取共用一条序列：会话在取 key 或换 key
/// 重试期间变化时结果被丢弃、不以新会话补发，签名被拒时只换 key 重试一次。
@Suite(.timeLimit(.minutes(1)))
struct SignedRequestSessionEpochTests {
    @Test(arguments: SignedEndpoint.allCases)
    func sessionChangeDuringWBIKeyFetchDropsTheRequest(endpoint: SignedEndpoint) async throws {
        let transport = StubTransport([
            .suspended(try fixtureResponse("nav")),
            .response(try endpoint.successResponse())
        ])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let request = Task { try await endpoint.call(client) }
        await transport.waitForRequests(1)
        await client.invalidateAuthenticatedSession()
        transport.resumeSuspendedRequest()

        await #expect(throws: CancellationError.self) {
            try await request.value
        }
        #expect(transport.businessRequests().isEmpty)
    }

    /// 首次请求属于旧会话；换 key 的 nav 期间会话变化时不再发出重试。
    @Test(arguments: SignedEndpoint.allCases)
    func sessionChangeBeforeKeyRefreshRetryDropsTheRetry(endpoint: SignedEndpoint) async throws {
        let transport = StubTransport([
            .response(try fixtureResponse("nav")),
            .response(jsonResponse(#"{"code":-403,"message":"fixture"}"#)),
            .suspended(try fixtureResponse("nav-refreshed")),
            .response(try endpoint.successResponse())
        ])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let request = Task { try await endpoint.call(client) }
        await transport.waitForRequests(3)
        await client.invalidateAuthenticatedSession()
        transport.resumeSuspendedRequest()

        await #expect(throws: CancellationError.self) {
            try await request.value
        }
        #expect(transport.businessRequests().map(\.url.path) == [endpoint.path])
    }

    @Test(arguments: SignedEndpoint.allCases)
    func signatureRejectionRefreshesTheKeyAndRetriesOnce(endpoint: SignedEndpoint) async throws {
        let transport = StubTransport(
            responses: [
                try fixtureResponse("nav"),
                jsonResponse(#"{"code":-403,"message":"fixture"}"#),
                try fixtureResponse("nav-refreshed"),
                try endpoint.successResponse()
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        try await endpoint.call(client)

        #expect(
            transport.capturedRequests().map(\.url.path) == [
                StubTransport.wbiNavPath,
                endpoint.path,
                StubTransport.wbiNavPath,
                endpoint.path
            ]
        )
    }

    /// 会话失效清掉的 key 不会被失效前发出、之后才返回的 nav 写回；下一次签名读取重新取 key。
    @Test
    func navReturningAfterSessionChangeDoesNotRepopulateTheKeyCache() async throws {
        let endpoint = SignedEndpoint.commentRoot
        let transport = StubTransport([
            .suspended(try fixtureResponse("nav")),
            .response(try fixtureResponse("nav-refreshed")),
            .response(try endpoint.successResponse())
        ])
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let staleRequest = Task { try await endpoint.call(client) }
        await transport.waitForRequests(1)
        await client.invalidateAuthenticatedSession()
        transport.resumeSuspendedRequest()
        await #expect(throws: CancellationError.self) {
            try await staleRequest.value
        }

        try await endpoint.call(client)

        #expect(
            transport.capturedRequests().map(\.url.path) == [
                StubTransport.wbiNavPath,
                StubTransport.wbiNavPath,
                endpoint.path
            ]
        )
    }

    enum SignedEndpoint: CaseIterable, Sendable {
        case videoDetail
        case commentRoot
        case subtitleCatalog
        case danmakuSegment

        private static let identity = PlaybackItemIdentity(bvid: "BV1FixtureA1", cid: 900_001)

        var path: String {
            switch self {
            case .videoDetail: "/x/web-interface/wbi/view"
            case .commentRoot: "/x/v2/reply/wbi/main"
            case .subtitleCatalog: "/x/player/wbi/v2"
            case .danmakuSegment: "/x/v2/dm/wbi/web/seg.so"
            }
        }

        func successResponse() throws -> HTTPResponse {
            switch self {
            case .videoDetail: try fixtureResponse("view")
            case .commentRoot: try fixtureResponse("comment-main")
            case .subtitleCatalog: try allowedSubtitleCatalogResponse()
            case .danmakuSegment: try hexFixtureResponse("danmaku-segment-minimal")
            }
        }

        func call(_ client: BiliAPIClient) async throws {
            switch self {
            case .videoDetail:
                _ = try await client.videoDetail(for: Self.identity.bvid)
            case .commentRoot:
                _ = try await client.commentRootPage(
                    for: .video(aid: 700_001),
                    sort: .hot,
                    offset: nil
                )
            case .subtitleCatalog:
                _ = try await client.subtitleResources(for: Self.identity)
            case .danmakuSegment:
                _ = try await client.danmakuSegmentData(index: 1, for: Self.identity)
            }
        }
    }
}
