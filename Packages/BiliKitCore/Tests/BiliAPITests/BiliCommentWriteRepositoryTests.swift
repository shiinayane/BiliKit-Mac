import BiliAPI
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

/// 固定评论写入契约：发评论以 App 鉴权发往 api 主机的 `reply/add`，回复带成对的 `root`／`parent`，回复楼中楼时带
/// `at_name_to_mid`；服务端给回的条目按列表的同一映射成为评论（标出 UP 主），给回的条目解不出时仍算发出成功；赞与踩是网页
/// 表单；评论接口的业务码映射为对应的写入错误。
@Suite(.timeLimit(.minutes(1)))
struct BiliCommentWriteRepositoryTests {
    private static let subject = CommentSubjectIdentity.video(aid: 771_792_698)

    @Test
    func postsReplyThroughTheAppFormAndMapsTheEchoedComment() async throws {
        let transport = StubTransport(responses: [
            jsonResponse(
                #"{"code":0,"data":{"reply":\#(Self.replyJSON(rpid: 31, root: 11, parent: 21))}}"#
            )
        ])
        let authorizer = StubSubjectBoundAuthorizer()
        let repository = BiliCommentWriteRepository(
            client: BiliAPIClient(transport: transport, appWriteAuthorizer: authorizer)
        )
        let request = try #require(
            CommentWriteUseCase.request(
                message: "回复 @某人 : 好+1",
                subject: Self.subject,
                replyTarget: CommentReplyTarget(
                    rootID: CommentID(rawValue: 11),
                    parentID: CommentID(rawValue: 21)
                ),
                mentions: ["某人": 7],
                uploaderID: 42
            )
        )

        let comment = try #require(try await repository.post(request, accountID: 42))

        let authorized = try #require(await authorizer.capturedRequests().last)
        #expect(await authorizer.subjects == ["42"])
        #expect(authorized.url.absoluteString == "https://api.bilibili.com/x/v2/reply/add")
        #expect(authorized.headers["Cookie"] == nil && authorized.headers["Referer"] == nil)
        #expect(
            formFields(authorized) == [
                "type": "1", "oid": "771792698", "root": "11", "parent": "21",
                "message": "回复 @某人 : 好+1", "plat": "2", "at_name_to_mid": #"{"某人":7}"#
            ]
        )
        #expect(comment.id == CommentID(rawValue: 31))
        #expect(comment.rootID == CommentID(rawValue: 11))
        guard case .available(let details) = comment.payload else {
            Issue.record("给回的评论应可见")
            return
        }
        #expect(details.author.isUploader)
    }

    /// 服务端已经收下（`code` 为 0），给回的条目缺失或映射失败只是不在本地插入：报失败会让用户重发一条已发出的评论。
    @Test(arguments: [
        #"{"code":0,"data":{}}"#,
        #"{"code":0,"data":{"reply":{"rpid":31,"oid":1,"type":1}}}"#
    ])
    func acceptedPostWithAnUnreadableEchoStillSucceeds(body: String) async throws {
        let repository = BiliCommentWriteRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [jsonResponse(body)]),
                appWriteAuthorizer: StubSubjectBoundAuthorizer()
            )
        )
        let request = try #require(
            CommentWriteUseCase.request(
                message: "好",
                subject: Self.subject,
                replyTarget: nil,
                mentions: [:],
                uploaderID: nil
            )
        )

        #expect(try await repository.post(request, accountID: 42) == nil)
    }

    @Test(arguments: [
        (CommentReactionOperation.Kind.like, true, "/x/v2/reply/action", "1"),
        (.dislike, false, "/x/v2/reply/hate", "0")
    ])
    func reactionsAreWebForms(
        kind: CommentReactionOperation.Kind,
        isOn: Bool,
        path: String,
        action: String
    ) async throws {
        let authorizer = StubSubjectBoundAuthorizer()
        let repository = BiliCommentWriteRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [statusResponse(code: 0)]),
                accountWriteAuthorizer: authorizer
            )
        )
        let target = try #require(
            CommentWriteTarget(subject: Self.subject, commentID: CommentID(rawValue: 11))
        )
        let current: CommentReaction = isOn ? .none : (kind == .like ? .liked : .disliked)
        let desired: CommentReaction = isOn ? (kind == .like ? .liked : .disliked) : .none
        let operation = try #require(
            CommentWriteUseCase.operation(for: target, from: current, to: desired)
        )

        try await repository.apply(operation, accountID: 42)

        let authorized = try #require(await authorizer.capturedRequests().last)
        #expect(authorized.url.absoluteString == "https://api.bilibili.com\(path)")
        #expect(
            formFields(authorized) == [
                "type": "1", "oid": "771792698", "rpid": "11", "action": action
            ]
        )
    }

    @Test(
        arguments: [
            (12_002, AccountWriteError.commentsClosed),
            (12_052, .commentsClosed),
            (12_035, .blockedByUploader),
            (12_016, .commentRejected),
            (12_051, .commentRejected),
            (12_015, .verificationRequired),
            (-509, .restricted),
            (12_006, .contentUnavailable),
            (12_025, .rejected(code: 12_025)),
            (-101, .authenticationInvalid)
        ] as [(Int, AccountWriteError)]
    )
    func mapsCommentBusinessCodes(code: Int, expected: AccountWriteError) async throws {
        let repository = BiliCommentWriteRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [statusResponse(code: code)]),
                appWriteAuthorizer: StubSubjectBoundAuthorizer()
            )
        )
        let request = try #require(
            CommentWriteUseCase.request(
                message: "好",
                subject: Self.subject,
                replyTarget: nil,
                mentions: [:],
                uploaderID: nil
            )
        )

        await #expect(throws: expected) {
            try await repository.post(request, accountID: 42)
        }
    }

    /// 合成的评论条目（不含真实用户信息），字段只取映射用到的。
    private static func replyJSON(rpid: Int64, root: Int64, parent: Int64) -> String {
        #"{"rpid":\#(rpid),"oid":771792698,"type":1,"root":\#(root),"parent":\#(parent),"dialog":\#(parent),"#
            + #""state":0,"ctime":1700000000,"like":0,"rcount":0,"action":0,"#
            + #""member":{"mid":"42","uname":"作者"},"content":{"message":"回复 @某人 : 好+1"}}"#
    }
}
