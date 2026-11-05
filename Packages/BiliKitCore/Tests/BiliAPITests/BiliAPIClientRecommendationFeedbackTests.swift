import BiliAPI
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

/// 固定首页推荐「不感兴趣」的请求契约：反馈与撤销是 App 端的 GET，发同一组字段（稿件 aid、卡片给出的原因 id，加首页
/// 推荐请求的客户端身份），经 App 写授权器绑定账户，不带 Referer；业务拒绝保留错误码。
@Suite(.timeLimit(.minutes(1)))
struct BiliAPIClientRecommendationFeedbackTests {
    @Test(arguments: [(false, "/x/feed/dislike"), (true, "/x/feed/dislike/cancel")])
    func feedbackSendsTheAppFieldsBoundToTheAccount(cancel: Bool, path: String) async throws {
        let transport = StubTransport(responses: [statusResponse(code: 0)])
        let authorizer = StubSubjectBoundAuthorizer()
        let repository = BiliRecommendationFeedbackRepository(
            client: BiliAPIClient(transport: transport, appWriteAuthorizer: authorizer)
        )
        let feedback = try feedback()

        if cancel {
            try await repository.cancelDislike(feedback, accountID: 42)
        } else {
            try await repository.dislike(feedback, accountID: 42)
        }

        let authorized = try #require(await authorizer.capturedRequests().last)
        #expect(await authorizer.subjects == ["42"])
        #expect(authorized.method == .get)
        #expect(authorized.body == nil)
        #expect(authorized.url.host == "app.bilibili.com")
        #expect(authorized.url.path == path)
        #expect(authorized.headers["Referer"] == nil)
        #expect(
            queryFields(authorized) == [
                "goto": "av",
                "id": "170001",
                "reason_id": "12",
                "mobi_app": "iphone",
                "device": "pad",
                "build": "1"
            ]
        )
    }

    @Test
    func businessRejectionKeepsItsCode() async throws {
        let repository = BiliRecommendationFeedbackRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [statusResponse(code: 12_345)]),
                appWriteAuthorizer: StubSubjectBoundAuthorizer()
            )
        )

        await #expect(throws: AccountWriteError.rejected(code: 12_345)) {
            try await repository.dislike(try feedback(), accountID: 42)
        }
    }

    private func feedback() throws -> RecommendationFeedback {
        RecommendationFeedback(
            target: try #require(VideoWriteTarget(bvid: "BV17x411w7KC")),
            reason: try #require(RecommendationDislikeReason(id: 12, name: "此类内容过多"))
        )
    }
}
