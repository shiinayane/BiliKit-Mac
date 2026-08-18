import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

@Suite("Comment API")
struct CommentAPIClientTests {
    @Test
    func rootCommentsUseAccountEnhancedWBIAndMapReadableRows() async throws {
        let transport = CommentRecordingTransport(
            responses: [try fixture("nav"), try fixture("comment-main")]
        )
        let authorizer = CommentRecordingAuthorizer()
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
        #expect(await authorizer.count == 1)
        let first = try #require(available(page.threads[0].root))
        #expect(first.author.isVIP)
        #expect(first.location == "东京")
        #expect(first.provenance == [.adminPinned, .uploaderLiked])
        let second = try #require(available(page.threads[1].root))
        #expect(second.author.isUploader)
        #expect(second.content.links.isEmpty)
        #expect(second.content.pictureCount == 0)
        #expect(page.threads[1].replyPreview.count == 1)
        guard case .unavailable(.unknown(rawValue: 7)) = page.threads[2].root.payload else {
            Issue.record("Expected unknown unavailable marker")
            return
        }

        let requests = await transport.requests
        #expect(
            requests.map(\.url.path) == [
                "/x/web-interface/nav", "/x/v2/reply/wbi/main",
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
        #expect(requests[1].headers["Cookie"] == "FIXTURE_AUTHORIZED")
    }

    @Test
    func continuationStaysOpaqueAndSuppliesNextOffset() async throws {
        let transport = CommentRecordingTransport(
            responses: [
                try fixture("nav"),
                try fixture("comment-main"),
                try fixture("comment-main"),
            ]
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
        let requests = await transport.requests
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

    @Test
    func replyPageUsesRootAndTenItemPageContract() async throws {
        let transport = CommentRecordingTransport(
            responses: [try fixture("comment-replies")]
        )
        let authorizer = CommentRecordingAuthorizer()
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
        let request = try #require(await transport.requests.first)
        let query = URLComponents(
            url: request.url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(request.url.path == "/x/v2/reply/reply")
        #expect(query?.first(where: { $0.name == "root" })?.value == "102")
        #expect(query?.first(where: { $0.name == "pn" })?.value == "2")
        #expect(query?.first(where: { $0.name == "ps" })?.value == "10")
        #expect(request.headers["Cookie"] == "FIXTURE_AUTHORIZED")
        #expect(await authorizer.count == 1)
    }

    @Test
    func authenticationInvalidationIsPreservedForRootAndReplies() async throws {
        let rootTransport = CommentRecordingTransport(
            responses: [try fixture("nav")]
        )
        let rootRepository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: rootTransport,
                requestAuthorizer: CommentRecordingAuthorizer(
                    failureKind: .invalidCredential
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        await #expect(throws: CommentReadError.authenticationInvalid) {
            try await rootRepository.rootComments(
                for: .video(aid: 700_001),
                sort: .hot,
                after: nil
            )
        }
        #expect(await rootTransport.requests.map(\.url.path) == ["/x/web-interface/nav"])

        let rejected = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"code":-101,"message":"账号未登录"}"#.utf8)
        )
        let replyRepository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: CommentRecordingTransport(responses: [rejected]),
                requestAuthorizer: CommentRecordingAuthorizer()
            )
        )
        await #expect(throws: CommentReadError.authenticationInvalid) {
            try await replyRepository.replies(
                for: .video(aid: 700_001),
                rootID: CommentID(rawValue: 102),
                page: 1,
                pageSize: 10
            )
        }
    }

    @Test
    func riskControlMapsToRestrictedWithoutAutomaticRetry() async throws {
        let rejected = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"code":-352,"message":"blocked"}"#.utf8)
        )
        let transport = CommentRecordingTransport(
            responses: [try fixture("nav"), rejected]
        )
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: transport,
                timestampProvider: { 1_700_000_000 }
            )
        )

        await #expect(throws: CommentReadError.requestRestricted) {
            try await repository.rootComments(
                for: .video(aid: 700_001),
                sort: .hot,
                after: nil
            )
        }
        #expect(await transport.requests.count == 2)
    }

    @Test
    func httpForbiddenFailsClosedWithoutRefreshingWBI() async throws {
        let forbidden = HTTPResponse(
            statusCode: 403,
            headers: ["Content-Type": "application/json"],
            body: Data()
        )
        let transport = CommentRecordingTransport(
            responses: [try fixture("nav"), forbidden]
        )
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: transport,
                timestampProvider: { 1_700_000_000 }
            )
        )

        await #expect(throws: CommentReadError.requestRestricted) {
            try await repository.rootComments(
                for: .video(aid: 700_001),
                sort: .hot,
                after: nil
            )
        }
        #expect(await transport.requests.count == 2)
    }

    @Test
    func topRepliesRemainInServerOrderWithoutInventingProvenance() async throws {
        let response = try mutatedFixture("comment-main") { data in
            var replies = try #require(data["replies"] as? [[String: Any]])
            var highlighted = try #require(replies.first)
            highlighted["rpid"] = 104
            highlighted["root"] = 0
            highlighted["parent"] = 0
            highlighted["replies"] = []
            data["top_replies"] = [highlighted]
            replies.removeFirst()
            data["replies"] = replies
        }
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: CommentRecordingTransport(
                    responses: [try fixture("nav"), response]
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        let page = try await repository.rootComments(
            for: .video(aid: 700_001),
            sort: .hot,
            after: nil
        )

        #expect(page.threads.map(\.id.rawValue) == [101, 104, 103])
        let highlighted = try #require(available(page.threads[1].root))
        #expect(highlighted.provenance.isEmpty)
    }

    @Test
    func malformedEnhancementsDoNotDiscardReadableComment() async throws {
        let response = try mutatedFixture("comment-main") { data in
            var replies = try #require(data["replies"] as? [[String: Any]])
            var reply = replies[0]
            var member = try #require(reply["member"] as? [String: Any])
            member["avatar"] = 42
            member["sex"] = ["unexpected"]
            member["level_info"] = "unexpected"
            member["vip"] = "unexpected"
            member["official_verify"] = "unexpected"
            member["is_senior_member"] = "unexpected"
            reply["member"] = member
            reply["reply_control"] = "unexpected"
            var content = try #require(reply["content"] as? [String: Any])
            content["emote"] = ["fixture": 42]
            content["jump_url"] = ["fixture": 42]
            content["members"] = [42]
            content["pictures"] = [
                ["img_src": "https://example.invalid/fixture.png"],
                42,
            ]
            reply["content"] = content
            replies[0] = reply
            data["replies"] = replies
        }
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: CommentRecordingTransport(
                    responses: [try fixture("nav"), response]
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        let page = try await repository.rootComments(
            for: .video(aid: 700_001),
            sort: .hot,
            after: nil
        )

        let details = try #require(
            page.threads.first(where: { $0.id.rawValue == 102 })
                .flatMap { available($0.root) }
        )
        #expect(details.content.message == "主评论与 @回复用户")
        #expect(details.content.pictureCount == 2)
        #expect(details.content.links.isEmpty)
        #expect(details.author.level == nil)
        #expect(!details.author.isHardcoreMember)
    }

    @Test
    func malformedPageEnhancementsAndReplyPreviewDegradeLocally() async throws {
        let response = try mutatedFixture("comment-main") { data in
            data["top_replies"] = 42
            data["top"] = "unexpected"
            data["upper"] = ["unexpected"]
            var replies = try #require(data["replies"] as? [[String: Any]])
            replies[0]["replies"] = "unexpected"
            data["replies"] = replies
        }
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: CommentRecordingTransport(
                    responses: [try fixture("nav"), response]
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        let page = try await repository.rootComments(
            for: .video(aid: 700_001),
            sort: .hot,
            after: nil
        )

        let thread = try #require(page.threads.first(where: { $0.id.rawValue == 102 }))
        let details = try #require(available(thread.root))
        #expect(details.content.message == "主评论与 @回复用户")
        #expect(!details.author.isUploader)
        #expect(thread.replyPreview.isEmpty)
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
                transport: CommentRecordingTransport(
                    responses: [try fixture("nav"), response]
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
                transport: CommentRecordingTransport(
                    responses: [try fixture("nav"), response]
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

    @Test
    func malformedReplyPageUploaderEnhancementDoesNotFailPage() async throws {
        let response = try mutatedFixture("comment-replies") { data in
            data["upper"] = "unexpected"
        }
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: CommentRecordingTransport(responses: [response])
            )
        )

        let page = try await repository.replies(
            for: .video(aid: 700_001),
            rootID: CommentID(rawValue: 102),
            page: 2,
            pageSize: 10
        )

        #expect(page.replies.map(\.id.rawValue) == [211])
        let details = try #require(available(page.replies[0]))
        #expect(!details.author.isUploader)
    }

    @Test
    func rootPageRejectsNestedRowsAndMapsHardcoreMembership() async throws {
        let response = try mutatedFixture("comment-main") { data in
            var replies = try #require(data["replies"] as? [[String: Any]])
            var nested = replies[0]
            nested["root"] = 101
            nested["parent"] = 101
            var unavailable = replies[1]
            unavailable["rpid"] = 105
            unavailable["state"] = 0
            unavailable["oid"] = 700_001
            unavailable["type"] = 1
            unavailable["root"] = 0
            unavailable["parent"] = 0
            unavailable["ctime"] = 1_700_000_400
            unavailable["like"] = 0
            unavailable["rcount"] = 0
            unavailable["member"] = [
                "mid": "305",
                "uname": "硬核会员",
                "is_senior_member": 1,
            ]
            unavailable["content"] = ["message": "硬核会员评论"]
            replies = [nested, unavailable]
            data["replies"] = replies
        }
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: CommentRecordingTransport(
                    responses: [try fixture("nav"), response]
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        let page = try await repository.rootComments(
            for: .video(aid: 700_001),
            sort: .hot,
            after: nil
        )

        #expect(!page.threads.contains(where: { $0.id.rawValue == 102 }))
        let details = try #require(
            page.threads.first(where: { $0.id.rawValue == 105 })
                .flatMap { available($0.root) }
        )
        #expect(details.author.isHardcoreMember)
    }

    @Test
    func rootPageRejectsNegativeRootShape() async throws {
        let response = try mutatedFixture("comment-main") { data in
            var replies = try #require(data["replies"] as? [[String: Any]])
            replies[0]["root"] = -1
            replies[0]["parent"] = -1
            data["replies"] = replies
        }
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: CommentRecordingTransport(
                    responses: [try fixture("nav"), response]
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        let page = try await repository.rootComments(
            for: .video(aid: 700_001),
            sort: .hot,
            after: nil
        )

        #expect(!page.threads.contains(where: { $0.id.rawValue == 102 }))
    }

    @Test
    func unavailableRowsCannotCrossCommentSubjects() async throws {
        let rootResponse = try mutatedFixture("comment-main") { data in
            var replies = try #require(data["replies"] as? [[String: Any]])
            var unavailable = replies[1]
            unavailable["oid"] = 999_999
            unavailable["type"] = 1
            replies[1] = unavailable
            data["replies"] = replies
        }
        let rootRepository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: CommentRecordingTransport(
                    responses: [try fixture("nav"), rootResponse]
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        let rootPage = try await rootRepository.rootComments(
            for: .video(aid: 700_001),
            sort: .hot,
            after: nil
        )
        #expect(!rootPage.threads.contains(where: { $0.id.rawValue == 103 }))

        let replyResponse = try mutatedFixture("comment-replies") { data in
            var replies = try #require(data["replies"] as? [[String: Any]])
            replies[0]["state"] = 7
            replies[0]["oid"] = 999_999
            replies[0]["type"] = 1
            data["replies"] = replies
        }
        let replyRepository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: CommentRecordingTransport(responses: [replyResponse])
            )
        )
        let replyPage = try await replyRepository.replies(
            for: .video(aid: 700_001),
            rootID: CommentID(rawValue: 102),
            page: 2,
            pageSize: 10
        )
        #expect(replyPage.replies.isEmpty)
    }

    @Test
    func commentVideoLinksRequireAValidHTTPSBVID() throws {
        let validJSON =
            #"{"message":"视频","jump_url":{"视频":{"pc_url":"https://www.bilibili.com/video/BV1FixtureA1"}}}"#
        let valid = try JSONDecoder().decode(
            CommentContentPayload.self,
            from: Data(validJSON.utf8)
        )
        #expect(try valid.model().links.count == 1)

        let invalidValues = [
            "http://www.bilibili.com/video/BV1FixtureA1",
            "https://user@example.com/video/BV1FixtureA1",
            "https://www.bilibili.com/video/BV😈",
            "https://example.com/video/BV1FixtureA1",
            "https://www.bilibili.com/video/BV",
        ]
        for value in invalidValues {
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "message": "视频",
                    "jump_url": ["视频": ["pc_url": value]],
                ]
            )
            let payload = try JSONDecoder().decode(CommentContentPayload.self, from: data)
            #expect(try payload.model().links.isEmpty)
        }
    }

    @Test
    func moreThanNinePicturesRejectsOnlyThatContent() throws {
        let picture = #"{"img_src":"https://i0.hdslb.com/fixture.jpg"}"#
        let onePicturePayload = try JSONDecoder().decode(
            CommentContentPayload.self,
            from: Data(
                "{\"message\":\"fixture\",\"pictures\":[\(picture)]}".utf8
            )
        )
        let onePictureContent = try onePicturePayload.model()
        #expect(onePictureContent.pictureCount == 1)
        #expect(onePictureContent.pictures.isEmpty)

        let pictures = Array(repeating: picture, count: 10).joined(separator: ",")
        let body = Data(
            "{\"message\":\"fixture\",\"pictures\":[\(pictures)]}".utf8
        )
        let payload = try JSONDecoder().decode(
            CommentContentPayload.self,
            from: body
        )

        #expect(throws: BiliAPIError.self) {
            try payload.model()
        }
    }

    @Test
    func replyPageDropsRowsFromAnotherRoot() async throws {
        let fixtureResponse = try fixture("comment-replies")
        let body = try #require(String(data: fixtureResponse.body, encoding: .utf8))
        let response = HTTPResponse(
            statusCode: 200,
            headers: fixtureResponse.headers,
            body: Data(
                body.replacingOccurrences(
                    of: #""root": 102"#,
                    with: #""root": 999"#
                ).utf8
            )
        )
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: CommentRecordingTransport(responses: [response])
            )
        )

        let page = try await repository.replies(
            for: .video(aid: 700_001),
            rootID: CommentID(rawValue: 102),
            page: 2,
            pageSize: 10
        )

        #expect(page.replies.isEmpty)
    }

    private func available(_ comment: BiliModels.Comment) -> CommentDetails? {
        guard case .available(let details) = comment.payload else { return nil }
        return details
    }

    private func fixture(_ name: String) throws -> HTTPResponse {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: try Data(contentsOf: url)
        )
    }

    private func mutatedFixture(
        _ name: String,
        mutate: (inout [String: Any]) throws -> Void
    ) throws -> HTTPResponse {
        let response = try fixture(name)
        var object = try #require(
            JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        )
        var data = try #require(object["data"] as? [String: Any])
        try mutate(&data)
        object["data"] = data
        return HTTPResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            body: try JSONSerialization.data(withJSONObject: object)
        )
    }
}

private actor CommentRecordingTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw CommentTransportError.noResponse }
        return responses.removeFirst()
    }
}

private actor CommentRecordingAuthorizer: HTTPRequestAuthorizing {
    private let failureKind: HTTPRequestAuthorizationFailureKind?
    private(set) var count = 0

    init(failureKind: HTTPRequestAuthorizationFailureKind? = nil) {
        self.failureKind = failureKind
    }

    func authorize(_ request: HTTPRequest) throws -> HTTPRequest {
        count += 1
        if let failureKind {
            throw CommentAuthorizationFailure(
                authorizationFailureKind: failureKind
            )
        }
        var headers = request.headers
        headers["Cookie"] = "FIXTURE_AUTHORIZED"
        return HTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: request.body
        )
    }
}

private struct CommentAuthorizationFailure: HTTPRequestAuthorizationFailure {
    let authorizationFailureKind: HTTPRequestAuthorizationFailureKind
}

private enum CommentTransportError: Error {
    case noResponse
}
