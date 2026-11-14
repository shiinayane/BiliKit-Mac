import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定评论 repository 的请求契约：根评论走带账户增强的 WBI 请求，回复按根与页码分页，
/// continuation 保持不透明，凭据、风控与服务端失败映射为 `CommentReadError` 并失败关闭。
@Suite("Comment API", .timeLimit(.minutes(1)))
struct CommentAPIClientTests {
    @Test
    func rootCommentsUseAccountEnhancedWBIAndMapReadableRows() async throws {
        let transport = StubTransport(
            responses: [try fixtureResponse("nav"), try fixtureResponse("comment-main")]
        )
        let authorizer = StubAuthorizer()
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: authorizer,
                timestampProvider: { 1_700_000_000 }
            )
        )

        let page = try await repository.rootComments(
            for: .video(aid: 700_001),
            sort: .hot,
            after: nil
        )

        #expect(page.totalCount == 3)
        #expect(page.threads.count == 3)
        #expect(page.continuation != nil)
        #expect(page.isEnd == false)
        #expect(await authorizer.authorizationCount == 1)
        let first = try #require(available(page.threads[0].root))
        #expect(first.author.isVIP)
        #expect(first.location == "东京")
        #expect(first.provenance == [.adminPinned, .uploaderLiked])
        let second = try #require(available(page.threads[1].root))
        #expect(second.author.isUploader)
        #expect(
            second.content.links == [
                CommentLink(
                    range: CommentTextRange(location: 5, length: 5),
                    target: .member(
                        CommentAuthor(id: CommentAuthorID(rawValue: "301"), name: "回复用户")
                    )
                )
            ]
        )
        #expect(second.content.pictureCount == 0)
        #expect(page.threads[1].replyPreview.count == 1)
        guard case .unavailable(.unknown(rawValue: 7)) = page.threads[2].root.payload else {
            Issue.record("Expected unknown unavailable marker")
            return
        }

        let requests = transport.capturedRequests()
        #expect(
            requests.map(\.url.path) == [
                StubTransport.wbiNavPath, "/x/v2/reply/wbi/main"
            ]
        )
        let query = URLComponents(
            url: requests[1].url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(query?.first(where: { $0.name == "type" })?.value == "1")
        #expect(query?.first(where: { $0.name == "oid" })?.value == "700001")
        #expect(query?.first(where: { $0.name == "mode" })?.value == "3")
        #expect(query?.first(where: { $0.name == "wts" })?.value == "1700000000")
        #expect(query?.first(where: { $0.name == "w_rid" })?.value?.count == 32)
        #expect(requests[0].headers["Cookie"] == nil)
        #expect(requests[1].headers["Cookie"] == StubAuthorizer.cookie)
    }

    @Test
    func continuationStaysOpaqueAndSuppliesNextOffset() async throws {
        let transport = StubTransport(
            responses: [
                try fixtureResponse("comment-main"),
                try fixtureResponse("comment-main")
            ],
            answersWBINavOnce: true
        )
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: transport,
                timestampProvider: { 1_700_000_000 }
            )
        )
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let first = try await repository.rootComments(
            for: subject,
            sort: .latest,
            after: nil
        )
        let continuation = try #require(first.continuation)
        let second = try await repository.rootComments(
            for: subject,
            sort: .latest,
            after: continuation
        )

        #expect(second.continuation == continuation)
        let requests = transport.capturedRequests()
        let queries = requests.filter { $0.url.path == "/x/v2/reply/wbi/main" }
        #expect(queries.count == 2)
        let firstItems = URLComponents(
            url: queries[0].url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        let secondItems = URLComponents(
            url: queries[1].url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(firstItems?.first(where: { $0.name == "mode" })?.value == "2")
        #expect(
            secondItems?.first(where: { $0.name == "pagination_str" })?.value
                == #"{"offset":"fixture-page-2"}"#
        )
    }

    /// 评论区为空时 cursor 不带 `all_count`，结果是空的末页而不是数据错误。
    @Test
    func emptyCommentSectionWithoutAllCountIsAnEmptyLastPage() async throws {
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: StubTransport(
                    responses: [
                        jsonResponse(
                            #"{"code":0,"message":"OK","data":{"cursor":{"is_begin":true,"prev":0,"next":2,"is_end":true,"pagination_reply":{},"mode":3,"name":"热门评论"},"replies":[],"top":{"admin":null,"upper":null,"vote":null},"top_replies":[],"upper":{"mid":113524}}}"#
                        )
                    ],
                    answersWBINavOnce: true
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        let page = try await repository.rootComments(
            for: .video(aid: 423_029),
            sort: .hot,
            after: nil
        )

        #expect(page.threads.isEmpty)
        #expect(page.totalCount == 0)
        #expect(page.isEnd)
        #expect(page.continuation == nil)
    }

    /// 评论区禁止新增（`control.input_disable`）或只读（`config.read_only`）时不能发评论；接口给的占位文字原样带出，空串当作没有。
    @Test(
        arguments: [
            (
                #""control":{"input_disable":false,"root_input_text":"说点什么","child_input_text":""}"#,
                true, "说点什么"
            ),
            (
                #""control":{"input_disable":true,"root_input_text":"当前评论区不可新增评论"}"#, false,
                "当前评论区不可新增评论"
            ),
            (#""config":{"read_only":true}"#, false, nil),
            (#""upper":{"mid":113524}"#, true, nil)
        ] as [(String, Bool, String?)]
    )
    func rootPageCarriesTheCommentInputPolicy(
        fields: String,
        accepts: Bool,
        rootPlaceholder: String?
    ) async throws {
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: StubTransport(
                    responses: [
                        jsonResponse(
                            #"{"code":0,"message":"OK","data":{"cursor":{"is_end":true},"replies":[],"#
                                + fields + "}}"
                        )
                    ],
                    answersWBINavOnce: true
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        let page = try await repository.rootComments(
            for: .video(aid: 423_029),
            sort: .hot,
            after: nil
        )

        #expect(page.inputPolicy.acceptsNewComments == accepts)
        #expect(page.inputPolicy.rootPlaceholder == rootPlaceholder)
        #expect(page.inputPolicy.replyPlaceholder == nil)
    }

    @Test
    func replyPageUsesRootAndTenItemPageContract() async throws {
        let transport = StubTransport(
            responses: [try fixtureResponse("comment-replies")]
        )
        let authorizer = StubAuthorizer()
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: authorizer
            )
        )

        let page = try await repository.replies(
            for: .video(aid: 700_001),
            rootID: CommentID(rawValue: 102),
            page: 2,
            pageSize: 10
        )

        #expect(page.rootID == CommentID(rawValue: 102))
        #expect(page.pageNumber == 2)
        #expect(page.pageSize == 10)
        #expect(page.totalCount == 11)
        #expect(page.replies.map(\.id) == [CommentID(rawValue: 211)])
        let request = try #require(transport.capturedRequests().first)
        let query = URLComponents(
            url: request.url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(request.url.path == "/x/v2/reply/reply")
        #expect(query?.first(where: { $0.name == "root" })?.value == "102")
        #expect(query?.first(where: { $0.name == "pn" })?.value == "2")
        #expect(query?.first(where: { $0.name == "ps" })?.value == "10")
        #expect(request.headers["Cookie"] == StubAuthorizer.cookie)
        #expect(await authorizer.authorizationCount == 1)
    }

    /// 对话按根评论与对话 ID 取 20 条，下一页带 `min_floor`；丢弃明确属于别的对话的行，缺 `dialog` 的占位保留；
    /// 本页最大楼层追上整串对话即到底，没到底却缺下一页起点时整页失败。
    @Test
    func dialogPageUsesFloorCursorAndKeepsOnlyThatDialog() async throws {
        let terminal = jsonResponse(
            #"{"code":0,"message":"OK","data":{"cursor":{"max_floor":30,"next":31},"dialog":{"max_floor":30},"replies":[{"rpid":305,"oid":700001,"type":1,"root":102,"parent":301,"dialog":301,"state":1}]}}"#
        )
        let missingNext = jsonResponse(
            #"{"code":0,"message":"OK","data":{"cursor":{"max_floor":25},"dialog":{"max_floor":30},"replies":[{"rpid":306,"oid":700001,"type":1,"root":102,"parent":301,"dialog":301,"state":1}]}}"#
        )
        let transport = StubTransport(
            responses: [try fixtureResponse("comment-dialog"), terminal, missingNext]
        )
        let authorizer = StubAuthorizer()
        let repository = BiliCommentRepository(
            client: BiliAPIClient(transport: transport, requestAuthorizer: authorizer)
        )

        let page = try await repository.dialog(
            for: .video(aid: 700_001),
            rootID: CommentID(rawValue: 102),
            dialogID: CommentID(rawValue: 301),
            fromFloor: nil,
            pageSize: 20
        )
        #expect(page.replies.map(\.id.rawValue) == [301, 302, 304])
        #expect(
            page.replies.map(\.dialogID)
                == [CommentID(rawValue: 301), CommentID(rawValue: 301), nil]
        )
        #expect(page.replies[1].isReplyInDialog)
        #expect(page.nextFloor == 21)

        let last = try await repository.dialog(
            for: .video(aid: 700_001),
            rootID: CommentID(rawValue: 102),
            dialogID: CommentID(rawValue: 301),
            fromFloor: 21,
            pageSize: 20
        )
        #expect(last.replies.map(\.id.rawValue) == [305])
        #expect(last.nextFloor == nil)
        await #expect(throws: CommentReadError.self) {
            try await repository.dialog(
                for: .video(aid: 700_001),
                rootID: CommentID(rawValue: 102),
                dialogID: CommentID(rawValue: 301),
                fromFloor: 21,
                pageSize: 20
            )
        }

        let requests = transport.capturedRequests()
        let queries = requests.map(queryFields)
        #expect(requests.allSatisfy { $0.url.path == "/x/v2/reply/dialog/cursor" })
        #expect(
            queries.first == [
                "type": "1", "oid": "700001", "root": "102", "dialog": "301", "size": "20"
            ]
        )
        #expect(queries.last?["min_floor"] == "21")
        #expect(requests.first?.headers["Cookie"] == StubAuthorizer.cookie)
    }

    /// 本地凭据失败时根评论与回复都不发出业务请求：凭据失效触发账户复核，Keychain 不可用不当作失效，
    /// 授权器 allowlist 拒绝是客户端发不出的 `invalidRequest`（见 SECURITY-MODEL §3）。
    @Test(
        arguments: [
            (
                HTTPRequestAuthorizationFailureKind.invalidCredential,
                CommentReadError.authenticationInvalid
            ),
            (.unavailable, .authenticationUnavailable),
            (.denied, .invalidRequest)
        ],
        [false, true]
    )
    func localCredentialFailureSendsNoBusinessRequest(
        failure: (HTTPRequestAuthorizationFailureKind, CommentReadError),
        readsReplies: Bool
    ) async {
        let transport = StubTransport(responses: [], answersWBINavOnce: true)
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: StubAuthorizer(.fail(failure.0)),
                timestampProvider: { 1_700_000_000 }
            )
        )

        await #expect(throws: failure.1) {
            if readsReplies {
                _ = try await repository.replies(
                    for: .video(aid: 700_001),
                    rootID: CommentID(rawValue: 102),
                    page: 1,
                    pageSize: 10
                )
            } else {
                _ = try await repository.rootComments(
                    for: .video(aid: 700_001),
                    sort: .hot,
                    after: nil
                )
            }
        }
        #expect(transport.businessRequests().isEmpty)
    }

    /// 根评论遇到风控、HTTP 403 或稿件、根评论不存在与不可见时失败关闭：只发一次业务请求，既不自动重试，
    /// 也不刷新 WBI key；不存在与不可见归为不可重试的 `contentUnavailable`。
    @Test(arguments: [
        (jsonResponse(#"{"code":-352,"message":"blocked"}"#), CommentReadError.requestRestricted),
        (jsonResponse("", statusCode: 403), .requestRestricted),
        (jsonResponse(#"{"code":-404,"message":"fixture"}"#), .contentUnavailable),
        (jsonResponse(#"{"code":62002,"message":"fixture"}"#), .contentUnavailable),
        (jsonResponse(#"{"code":62004,"message":"fixture"}"#), .contentUnavailable)
    ])
    func rootFailuresFailClosedWithoutRetryOrWBIRefresh(
        rejected: HTTPResponse,
        expected: CommentReadError
    ) async throws {
        let transport = StubTransport(responses: [rejected], answersWBINavOnce: true)
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: transport,
                timestampProvider: { 1_700_000_000 }
            )
        )

        await #expect(throws: expected) {
            try await repository.rootComments(
                for: .video(aid: 700_001),
                sort: .hot,
                after: nil
            )
        }
        #expect(transport.businessRequests().count == 1)
    }

    @Test(arguments: [
        (htmlRiskControlResponse(), CommentReadError.requestRestricted),
        (jsonResponse("", statusCode: 412), .requestRestricted),
        (jsonResponse(#"{"code":-412,"message":"fixture"}"#), .requestRestricted),
        (jsonResponse(#"{"code":-500,"message":"fixture"}"#), .serviceRejected(code: -500)),
        (jsonResponse(#"{"code":12002,"message":"评论区已关闭"}"#), .closed),
        (jsonResponse("", statusCode: 500), .unavailable),
        (jsonResponse("{"), .invalidResponse),
        // 回复以账户凭据请求：-101 是凭据失效，不是“需要登录”。
        (jsonResponse(#"{"code":-101,"message":"账号未登录"}"#), .authenticationInvalid)
    ])
    func replyFailuresMapToCommentReadError(
        response: HTTPResponse,
        expected: CommentReadError
    ) async {
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [response]),
                requestAuthorizer: StubAuthorizer()
            )
        )

        await #expect(throws: expected) {
            try await repository.replies(
                for: .video(aid: 700_001),
                rootID: CommentID(rawValue: 102),
                page: 1,
                pageSize: 10
            )
        }
    }

    @Test
    func terminalRootPageIgnoresMalformedUnusedPaginationReply() async throws {
        let response = try mutatedFixture("comment-main") { data in
            var cursor = try #require(data["cursor"] as? [String: Any])
            cursor["is_end"] = true
            cursor["pagination_reply"] = ["next_offset": ["unexpected"]]
            data["cursor"] = cursor
        }
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: StubTransport(
                    responses: [response],
                    answersWBINavOnce: true
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        let page = try await repository.rootComments(
            for: .video(aid: 700_001),
            sort: .hot,
            after: nil
        )

        #expect(page.isEnd)
        #expect(page.continuation == nil)
        #expect(!page.threads.isEmpty)
    }

    @Test
    func nonTerminalRootPageStillRequiresAReadableNextOffset() async throws {
        let response = try mutatedFixture("comment-main") { data in
            var cursor = try #require(data["cursor"] as? [String: Any])
            cursor["is_end"] = false
            cursor["pagination_reply"] = ["next_offset": ["unexpected"]]
            data["cursor"] = cursor
        }
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: StubTransport(
                    responses: [response],
                    answersWBINavOnce: true
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        await #expect(throws: CommentReadError.invalidResponse) {
            try await repository.rootComments(
                for: .video(aid: 700_001),
                sort: .hot,
                after: nil
            )
        }
    }
}
