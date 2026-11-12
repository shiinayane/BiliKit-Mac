import BiliAPI
import BiliApplication
import BiliNetworking
import Foundation
import Testing

/// 固定发送弹幕契约：网页表单发往 `dm/post`，经账户写授权器绑定窗口账户，正文原样到达（`+` 不被服务端解成空格，
/// `;` 不被当成字段分隔）；返回服务端给的弹幕 ID；发送太频繁按受限失败，其余业务码带出错误码。
@Suite(.timeLimit(.minutes(1)))
struct BiliDanmakuPostRepositoryTests {
    @Test
    func sendsTheWebFormAndReturnsTheDanmakuID() async throws {
        let transport = StubTransport(responses: [
            jsonResponse(
                #"{"code":0,"data":{"dmid":1987654321012345678,"dmid_str":"1987654321012345678"}}"#
            )
        ])
        let authorizer = StubSubjectBoundAuthorizer()
        let repository = BiliDanmakuPostRepository(
            client: BiliAPIClient(transport: transport, accountWriteAuthorizer: authorizer)
        )

        let receipt = try await repository.post(
            try request(text: "好+1 & =;x", at: 93.45),
            accountID: 42
        )

        #expect(receipt.danmakuID == "1987654321012345678")
        let authorized = try #require(await authorizer.capturedRequests().last)
        #expect(await authorizer.subjects == ["42"])
        #expect(authorized.url.absoluteString == "https://api.bilibili.com/x/v2/dm/post")
        #expect(authorized.headers["Referer"] == "https://www.bilibili.com/")
        var fields = formFields(authorized)
        #expect(fields.removeValue(forKey: "rnd").flatMap { Int64($0) }.map { $0 > 0 } == true)
        #expect(
            fields == [
                "type": "1", "oid": "1176840", "msg": "好+1 & =;x", "bvid": "BV1xx411c7mD",
                "progress": "93450", "color": "16777215", "fontsize": "25", "pool": "0", "mode": "1"
            ]
        )
        let body = try #require(authorized.body.flatMap { String(data: $0, encoding: .utf8) })
        #expect(!body.contains("+") && !body.contains(";"))
    }

    @Test(
        arguments: [
            (36_703, AccountWriteError.restricted),
            (36_704, .contentUnavailable),
            (36_701, .rejected(code: 36_701)),
            (-101, .authenticationInvalid)
        ] as [(Int, AccountWriteError)]
    )
    func mapsItsBusinessCodes(code: Int, expected: AccountWriteError) async throws {
        let repository = BiliDanmakuPostRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [statusResponse(code: code)]),
                accountWriteAuthorizer: StubSubjectBoundAuthorizer()
            )
        )
        let request = try request(text: "好", at: 0)

        await #expect(throws: expected) {
            try await repository.post(request, accountID: 42)
        }
    }

    private func request(text: String, at seconds: Double) throws -> DanmakuPostRequest {
        try #require(
            DanmakuPostUseCase.request(
                text: text,
                identity: PlaybackItemIdentity(bvid: "BV1xx411c7mD", cid: 1_176_840),
                positionSeconds: seconds
            )
        )
    }
}
