import BiliApplication
import BiliModels
import Testing

/// 评论用例去掉已显示与重复的条目而不改变顺序，空页停止自动翻页但保留游标以便重试。
///
/// 楼中楼与对话页校验服务端给出的页码、页大小与下一页起点，不合法的页码或起点不发请求。
@Suite(.timeLimit(.minutes(1)))
struct CommentUseCaseTests {
    @Test
    func rootPageRemovesExistingAndDuplicateItemsWithoutReordering() async throws {
        let next = commentContinuation("next")
        let repository = CommentRepositoryStub(
            rootPages: [
                CommentRootPage(
                    threads: [thread(1), thread(2), thread(2), thread(3)],
                    totalCount: 4,
                    continuation: next,
                    isEnd: false
                )
            ]
        )
        let useCase = CommentUseCase(repository: repository)

        let batch = try await useCase.loadRoots(
            for: .video(aid: 700_001),
            sort: .hot,
            excluding: [CommentID(rawValue: 1)]
        )

        #expect(batch.threads.map(\.id.rawValue) == [2, 3])
        #expect(batch.continuation == next)
        #expect(batch.termination == nil)
    }

    @Test
    func emptyRootPageStopsAutomaticPagingButKeepsContinuationForRetry() async throws {
        let continuation = commentContinuation("next")
        let useCase = CommentUseCase(
            repository: CommentRepositoryStub(
                rootPages: [
                    CommentRootPage(
                        threads: [],
                        totalCount: 0,
                        continuation: continuation,
                        isEnd: false
                    )
                ]
            )
        )

        let batch = try await useCase.loadRoots(
            for: .video(aid: 700_001),
            sort: .hot
        )

        #expect(batch.termination == .emptyPage)
        #expect(batch.continuation == continuation)
    }

    @Test
    func replyPageUsesServerCountAndRemovesDuplicateReplies() async throws {
        let rootID = CommentID(rawValue: 10)
        let useCase = CommentUseCase(
            repository: CommentRepositoryStub(
                replyPages: [
                    CommentReplyPage(
                        rootID: rootID,
                        replies: [comment(11), comment(11)],
                        pageNumber: 2,
                        pageSize: 10,
                        totalCount: 11
                    )
                ]
            )
        )

        let batch = try await useCase.loadReplies(
            for: .video(aid: 700_001),
            rootID: rootID,
            page: 2
        )

        #expect(batch.replies.map(\.id.rawValue) == [11])
        #expect(batch.isEnd)
    }

    @Test
    func replyPageRejectsAChangedServerPageSize() async {
        let rootID = CommentID(rawValue: 10)
        let useCase = CommentUseCase(
            repository: CommentRepositoryStub(
                replyPages: [
                    CommentReplyPage(
                        rootID: rootID,
                        replies: [comment(11)],
                        pageNumber: 1,
                        pageSize: 20,
                        totalCount: 20
                    )
                ]
            )
        )

        await #expect(throws: CommentReadError.invalidResponse) {
            try await useCase.loadReplies(
                for: .video(aid: 700_001),
                rootID: rootID,
                page: 1
            )
        }
    }

    /// 不合规的页码是客户端无法发出的请求，不是接口数据错误，也不交给 repository。
    @Test
    func replyPageRejectsInvalidPageNumberAsInvalidRequest() async {
        let useCase = CommentUseCase(repository: CommentRepositoryStub())

        await #expect(throws: CommentReadError.invalidRequest) {
            try await useCase.loadReplies(
                for: .video(aid: 700_001),
                rootID: CommentID(rawValue: 1),
                page: 0
            )
        }
    }
}

extension CommentUseCaseTests {
    /// 对话页去重，下一页起点原样交出；根评论或对话不符、下一页起点没有越过请求楼层都按无效响应，起点不是正数时不请求。
    @Test
    func dialogPageIsValidatedAndDeduped() async throws {
        let rootID = CommentID(rawValue: 1)
        let dialogID = CommentID(rawValue: 2)
        let useCase = CommentUseCase(
            repository: CommentRepositoryStub(
                dialogPages: [
                    CommentDialogPage(
                        rootID: rootID,
                        dialogID: dialogID,
                        replies: [comment(2), comment(3), comment(3)],
                        nextFloor: 21
                    ),
                    CommentDialogPage(
                        rootID: rootID,
                        dialogID: dialogID,
                        replies: [comment(4)],
                        nextFloor: nil
                    ),
                    CommentDialogPage(
                        rootID: rootID,
                        dialogID: CommentID(rawValue: 9),
                        replies: [comment(4)],
                        nextFloor: nil
                    ),
                    CommentDialogPage(
                        rootID: rootID,
                        dialogID: dialogID,
                        replies: [comment(5)],
                        nextFloor: 21
                    )
                ]
            )
        )
        let subject = CommentSubjectIdentity.video(aid: 700_001)

        let first = try await useCase.loadDialog(
            for: subject,
            rootID: rootID,
            dialogID: dialogID,
            fromFloor: nil
        )
        #expect(first.replies.map(\.id.rawValue) == [2, 3])
        #expect(first.nextFloor == 21)

        let last = try await useCase.loadDialog(
            for: subject,
            rootID: rootID,
            dialogID: dialogID,
            fromFloor: 21
        )
        #expect(last.replies.map(\.id.rawValue) == [4])
        #expect(last.nextFloor == nil)

        await #expect(throws: CommentReadError.invalidResponse) {
            try await useCase.loadDialog(
                for: subject,
                rootID: rootID,
                dialogID: dialogID,
                fromFloor: nil
            )
        }
        await #expect(throws: CommentReadError.invalidResponse) {
            try await useCase.loadDialog(
                for: subject,
                rootID: rootID,
                dialogID: dialogID,
                fromFloor: 21
            )
        }
        await #expect(throws: CommentReadError.invalidRequest) {
            try await useCase.loadDialog(
                for: subject,
                rootID: rootID,
                dialogID: dialogID,
                fromFloor: 0
            )
        }
    }
}

private actor CommentRepositoryStub: CommentRepository {
    private var rootPages: [CommentRootPage]
    private var replyPages: [CommentReplyPage]
    private var dialogPages: [CommentDialogPage]

    init(
        rootPages: [CommentRootPage] = [],
        replyPages: [CommentReplyPage] = [],
        dialogPages: [CommentDialogPage] = []
    ) {
        self.rootPages = rootPages
        self.replyPages = replyPages
        self.dialogPages = dialogPages
    }

    func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) throws -> CommentRootPage {
        rootPages.removeFirst()
    }

    func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) throws -> CommentReplyPage {
        replyPages.removeFirst()
    }

    func dialog(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        dialogID: CommentID,
        fromFloor: Int?,
        pageSize: Int
    ) throws -> CommentDialogPage {
        dialogPages.removeFirst()
    }
}

private func thread(_ id: Int64) -> CommentThread {
    CommentThread(root: comment(id))
}

private func commentContinuation(_ value: String) -> CommentContinuation {
    CommentContinuation(rawValue: value)
}

private func comment(_ id: Int64) -> BiliModels.Comment {
    BiliModels.Comment(
        id: CommentID(rawValue: id),
        payload: .unavailable(.unavailable)
    )
}
