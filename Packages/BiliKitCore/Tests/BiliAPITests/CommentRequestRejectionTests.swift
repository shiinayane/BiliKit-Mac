import BiliApplication
import BiliModels
import BiliNetworking
import Testing

@testable import BiliAPI

/// 参数不合规、客户端无法发出的评论请求是 `invalidRequest`，不是接口数据错误，也不发出业务请求；
/// 授权器 allowlist 拒绝的同类结果在 `CommentAPIClientTests` 固定。
@Suite(.timeLimit(.minutes(1)))
struct CommentRequestRejectionTests {
    @Test
    func malformedReplyPageRequestIsAnInvalidRequest() async {
        let transport = StubTransport(responses: [])
        let repository = BiliCommentRepository(client: BiliAPIClient(transport: transport))

        await #expect(throws: CommentReadError.invalidRequest) {
            try await repository.replies(
                for: .video(aid: 700_001),
                rootID: CommentID(rawValue: 102),
                page: 1,
                pageSize: 20
            )
        }
        #expect(transport.capturedRequests().isEmpty)
    }
}
