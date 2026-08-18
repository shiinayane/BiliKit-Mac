import BiliApplication
import BiliModels
import Testing

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
    func repeatedContinuationTerminatesAfterKeepingNewItems() async throws {
        let continuation = commentContinuation("same")
        let useCase = CommentUseCase(
            repository: CommentRepositoryStub(
                rootPages: [
                    CommentRootPage(
                        threads: [thread(1)],
                        totalCount: 2,
                        continuation: continuation,
                        isEnd: false
                    )
                ]
            )
        )

        let batch = try await useCase.loadRoots(
            for: .video(aid: 700_001),
            sort: .latest,
            after: continuation
        )

        #expect(batch.threads.map(\.id.rawValue) == [1])
        #expect(batch.continuation == nil)
        #expect(batch.termination == .continuationStalled)
    }

    @Test
    func emptyRootPageTerminatesWithoutScanningAhead() async throws {
        let useCase = CommentUseCase(
            repository: CommentRepositoryStub(
                rootPages: [
                    CommentRootPage(
                        threads: [],
                        totalCount: 0,
                        continuation: commentContinuation("next"),
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
        #expect(batch.continuation == nil)
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
}

private actor CommentRepositoryStub: CommentRepository {
    private var rootPages: [CommentRootPage]
    private var replyPages: [CommentReplyPage]

    init(
        rootPages: [CommentRootPage] = [],
        replyPages: [CommentReplyPage] = []
    ) {
        self.rootPages = rootPages
        self.replyPages = replyPages
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
        payload: .unavailable(.deleted)
    )
}
