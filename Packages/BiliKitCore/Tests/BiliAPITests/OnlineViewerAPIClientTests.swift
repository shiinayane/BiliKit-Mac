import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定「正在看」人数契约：登录时也匿名读取、不签 WBI、只带 BV 与 CID；人数文本原样给出，B 站关掉显示或文本异常时为
/// nil；无效 BV 或 CID 不发请求（见 SECURITY-MODEL §3）。
struct OnlineViewerAPIClientTests {
    private static let identity = PlaybackItemIdentity(bvid: "BV1FixtureA1", cid: 900_001)

    @Test
    func requestIsAnonymousUnsignedAndReturnsTotalText() async throws {
        let transport = StubTransport(
            responses: [
                jsonResponse(
                    #"{"code":0,"data":{"total":" 1000+ ","count":"6","show_switch":{"total":true,"count":true}}}"#
                )
            ]
        )
        let authorizer = StubAuthorizer()
        let client = BiliAPIClient(transport: transport, requestAuthorizer: authorizer)

        let text = try await client.onlineViewerText(for: Self.identity)

        #expect(text == "1000+")
        #expect(await authorizer.capturedPaths().isEmpty)
        let requests = transport.capturedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.url.path == "/x/player/online/total")
        #expect(requests.first?.url.query == "bvid=BV1FixtureA1&cid=900001")
        #expect(requests.first?.headers["Cookie"] == nil)
    }

    /// B 站关掉显示、没有人数、空白、过长或带换行时都不显示。
    @Test(arguments: [
        #"{"total":"12","show_switch":{"total":false}}"#,
        #"{"count":"6"}"#,
        #"{"total":"  ","show_switch":{"total":true}}"#,
        #"{"total":"12345678901234567","show_switch":{"total":true}}"#,
        #"{"total":"12\n点我","show_switch":{"total":true}}"#
    ])
    func hiddenOrMalformedTotalIsNil(data: String) async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(#"{"code":0,"data":\#(data)}"#)]),
            requestAuthorizer: StubAuthorizer()
        )

        #expect(try await client.onlineViewerText(for: Self.identity) == nil)
    }

    @Test(arguments: [
        PlaybackItemIdentity(bvid: "not-a-bvid", cid: 1),
        PlaybackItemIdentity(bvid: "BV1FixtureA1", cid: 0)
    ])
    func invalidIdentitySendsNothing(identity: PlaybackItemIdentity) async {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.onlineViewerText(for: identity)
        }
        #expect(transport.capturedRequests().isEmpty)
    }
}
