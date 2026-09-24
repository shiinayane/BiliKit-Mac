import BiliApplication
import BiliModels
import Testing

@testable import BiliBrowseFeature

@Suite(.timeLimit(.minutes(1)))
struct PlaybackCommentsViewModelTests {
    @Test
    @MainActor
    func stableContinuationCanAppendMultiplePagesUntilTheServerEnds() async {
        let continuation = CommentContinuation(rawValue: "stable-session")
        let repository = CommentRepositoryStub(
            rootPages: [
                CommentRootPage(
                    threads: [thread(1)],
                    totalCount: 3,
                    continuation: continuation,
                    isEnd: false
                ),
                CommentRootPage(
                    threads: [thread(2)],
                    totalCount: 3,
                    continuation: continuation,
                    isEnd: false
                ),
                CommentRootPage(
                    threads: [thread(3)],
                    totalCount: 3,
                    continuation: continuation,
                    isEnd: true
                )
            ]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.loadNextPage()
        await model.waitForCurrentRootTask()

        #expect(model.threads.map(\.id.rawValue) == [1, 2])
        #expect(!model.reachedEnd)
        #expect(model.paginationTermination == nil)

        model.loadNextPage()
        await model.waitForCurrentRootTask()

        #expect(model.threads.map(\.id.rawValue) == [1, 2, 3])
        #expect(model.reachedEnd)
        #expect(model.paginationTermination == .serverEnd)
    }

    @Test
    @MainActor
    func duplicatePageStopsAutomaticPagingAndExplicitRetryUsesTheSameContinuation() async {
        let continuation = CommentContinuation(rawValue: "stable-session")
        let repository = CommentRepositoryStub(
            rootPages: [
                CommentRootPage(
                    threads: [thread(1)],
                    totalCount: 2,
                    continuation: continuation,
                    isEnd: false
                ),
                CommentRootPage(
                    threads: [thread(1)],
                    totalCount: 2,
                    continuation: continuation,
                    isEnd: false
                ),
                CommentRootPage(
                    threads: [thread(2)],
                    totalCount: 2,
                    continuation: nil,
                    isEnd: true
                )
            ]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.loadNextPage()
        await model.waitForCurrentRootTask()

        #expect(model.threads.map(\.id.rawValue) == [1])
        #expect(!model.reachedEnd)
        #expect(model.paginationTermination == .duplicatePage)

        model.loadNextPage()
        await model.waitForCurrentRootTask()
        #expect(await repository.rootRequestCount == 2)

        model.retryRoot()
        await model.waitForCurrentRootTask()

        #expect(model.threads.map(\.id.rawValue) == [1, 2])
        #expect(model.paginationTermination == .serverEnd)
        #expect(await repository.rootRequestCount == 3)
    }

    @Test
    @MainActor
    func sameSubjectKeepsWorksetWhileNewSubjectReplacesIt() async {
        let repository = CommentRepositoryStub(
            rootPages: [
                endPage([thread(1)]),
                endPage([thread(2)])
            ]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )
        let firstSubject = CommentSubjectIdentity.video(aid: 700_001)

        model.activate(subject: firstSubject)
        await model.waitForCurrentRootTask()
        model.activate(subject: firstSubject)
        await model.waitForCurrentRootTask()
        #expect(await repository.rootRequestCount == 1)

        model.activate(subject: .video(aid: 700_002))
        await model.waitForCurrentRootTask()

        #expect(model.threads.map(\.id.rawValue) == [2])
        #expect(await repository.rootRequestCount == 2)
    }

    @Test
    @MainActor
    func sortReplacementRejectsLateOldResult() async throws {
        let repository = CommentRepositoryStub(holdsRoots: true)
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await repository.waitForRootRequestCount(1)
        let oldTask = try #require(model.rootTaskSnapshotForTesting())

        model.selectSort(.latest)
        await repository.waitForRootRequestCount(2)
        await repository.releaseRoot(1, page: endPage([thread(2)]))
        await model.waitForCurrentRootTask()
        await repository.releaseRoot(0, page: endPage([thread(1)]))
        await oldTask.value

        #expect(model.sort == .latest)
        #expect(model.threads.map(\.id.rawValue) == [2])
    }

    @Test
    @MainActor
    func collapsingThreadCancelsItsLateReplyReplacement() async throws {
        let rootID = CommentID(rawValue: 10)
        let repository = CommentRepositoryStub(
            rootPages: [endPage([thread(10)])],
            heldReplyPages: [1]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: rootID)
        await repository.waitForReplyRequestCount(1)
        let replyTask = try #require(
            model.replyTaskSnapshotForTesting(rootID: rootID)
        )

        model.collapseReplies(for: rootID)
        await repository.releaseReply(at: 0)
        await replyTask.value

        let state = try #require(model.replyStates[rootID])
        #expect(!state.isExpanded)
        #expect(!state.isLoading)
        #expect(state.replies.isEmpty)
    }

    @Test
    @MainActor
    func failedReplyPageCannotBeSkippedAndRetryRequestsSamePage() async throws {
        let rootID = CommentID(rawValue: 20)
        let repository = CommentRepositoryStub(
            rootPages: [endPage([thread(20)])],
            replyTotalCount: 25,
            failingReplyPagesOnce: [2]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: rootID)
        await model.replyTaskSnapshotForTesting(rootID: rootID)?.value

        model.showNextReplyPage(for: rootID)
        await model.replyTaskSnapshotForTesting(rootID: rootID)?.value
        #expect(model.replyStates[rootID]?.error == .transportFailure)

        model.showNextReplyPage(for: rootID)
        #expect(await repository.requestedReplyPages == [1, 2])

        model.retryReplies(for: rootID)
        await model.replyTaskSnapshotForTesting(rootID: rootID)?.value
        #expect(await repository.requestedReplyPages == [1, 2, 2])
        #expect(model.replyStates[rootID]?.error == nil)
    }

    @Test
    @MainActor
    func rootRetentionStopsAtTheInMemoryLimit() async {
        let repository = CommentRepositoryStub(
            rootPages: [endPage((1...1_001).map { thread(Int64($0)) })]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()

        #expect(model.threads.count == 1_000)
        #expect(model.reachedMemoryLimit)
        #expect(model.reachedEnd)
    }

    @Test
    @MainActor
    func collapsingPendingNextPageKeepsTheLastSuccessfulReplyPage() async throws {
        let rootID = CommentID(rawValue: 30)
        let repository = CommentRepositoryStub(
            rootPages: [endPage([thread(30)])],
            replyTotalCount: 11,
            heldReplyPages: [2]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: rootID)
        await model.replyTaskSnapshotForTesting(rootID: rootID)?.value
        model.showNextReplyPage(for: rootID)
        await repository.waitForReplyRequestCount(2)
        let pendingTask = try #require(
            model.replyTaskSnapshotForTesting(rootID: rootID)
        )

        model.collapseReplies(for: rootID)
        await repository.releaseReply(at: 1)
        await pendingTask.value
        model.expandReplies(for: rootID)

        let state = try #require(model.replyStates[rootID])
        #expect(state.pageNumber == 1)
        #expect(state.requestedPageNumber == nil)
        #expect(state.replies.map(\.id.rawValue) == [3001])
        #expect(await repository.requestedReplyPages == [1, 2])
    }

    @Test
    @MainActor
    func replyRequestsUseBoundedWindowConcurrency() async {
        let roots = (1...6).map { thread(Int64($0)) }
        let repository = CommentRepositoryStub(
            rootPages: [endPage(roots)],
            heldReplyPages: [1]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        for root in roots {
            model.expandReplies(for: root.id)
        }
        await repository.waitForReplyRequestCount(4)

        // 折叠不会提前释放仍在途的请求位；重新展开排到队尾。
        model.collapseReplies(for: roots[0].id)
        model.expandReplies(for: roots[0].id)
        await repository.releaseReplies(rootID: roots[0].id)
        await repository.waitForReplyRequestCount(5)
        await repository.releaseAllHeldReplies()
        await repository.waitForReplyRequestCount(7)
        await repository.releaseAllHeldReplies()

        #expect(await repository.maximumActiveReplyCount == 4)
        #expect(await repository.replyRequestCount == 7)
    }

    @Test
    @MainActor
    func subjectReplacementRejectsLateReplyWithReusedRootID() async throws {
        let root = thread(50)
        let repository = CommentRepositoryStub(
            rootPages: [endPage([root])],
            heldReplyPages: [1]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: root.id)
        await repository.waitForReplyRequestCount(1)

        model.activate(subject: .video(aid: 700_002))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: root.id)

        await repository.releaseReply(at: 0, replyID: 51)
        await repository.waitForReplyRequestCount(2)
        await repository.releaseReply(at: 1, replyID: 52)
        await model.replyTaskSnapshotForTesting(rootID: root.id)?.value

        let state = try #require(model.replyStates[root.id])
        #expect(state.replies.map(\.id.rawValue) == [52])
        #expect(await repository.replyRequestCount == 2)
    }

    @Test
    @MainActor
    func rootAndReplyAuthenticationInvalidationPublishRevalidationIntent() async throws {
        let rootFailureModel = PlaybackCommentsViewModel(
            useCase: CommentUseCase(
                repository: CommentRepositoryStub(rootFailure: .authenticationInvalid)
            )
        )
        rootFailureModel.activate(subject: .video(aid: 700_001))
        await rootFailureModel.waitForCurrentRootTask()

        #expect(rootFailureModel.rootState == .failed(.authenticationInvalid))
        #expect(rootFailureModel.authenticationRevalidationGeneration == 1)

        let root = thread(80)
        let replyFailureModel = PlaybackCommentsViewModel(
            useCase: CommentUseCase(
                repository: CommentRepositoryStub(
                    rootPages: [endPage([root])],
                    replyFailure: .authenticationInvalid
                )
            )
        )
        replyFailureModel.activate(subject: .video(aid: 700_001))
        await replyFailureModel.waitForCurrentRootTask()
        replyFailureModel.expandReplies(for: root.id)
        await replyFailureModel.replyTaskSnapshotForTesting(rootID: root.id)?.value

        #expect(
            replyFailureModel.replyStates[root.id]?.error
                == .authenticationInvalid
        )
        #expect(replyFailureModel.authenticationRevalidationGeneration == 1)
    }
}

/// 唯一的 CommentRepository 替身：根评论按序返回（最后一页可重复）或逐个挂起，
/// 回复按页可挂起、首次失败或持续失败，并记录请求数与挂起回复的并发峰值。
private actor CommentRepositoryStub: CommentRepository {
    private struct ReplyRequest {
        let rootID: CommentID
        let page: Int
        var continuation: CheckedContinuation<CommentReplyPage, Never>?
    }

    private var rootPages: [CommentRootPage]
    private let rootFailure: CommentReadError?
    private let holdsRoots: Bool
    private let replyTotalCount: Int
    private let heldReplyPages: Set<Int>
    private var failingReplyPagesOnce: Set<Int>
    private let replyFailure: CommentReadError?
    private var heldRoots: [CheckedContinuation<CommentRootPage, Never>?] = []
    private var replyRequests: [ReplyRequest] = []
    private var activeReplyCount = 0
    private var rootWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var replyWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var rootRequestCount = 0
    private(set) var maximumActiveReplyCount = 0

    init(
        rootPages: [CommentRootPage] = [],
        rootFailure: CommentReadError? = nil,
        holdsRoots: Bool = false,
        replyTotalCount: Int = 1,
        heldReplyPages: Set<Int> = [],
        failingReplyPagesOnce: Set<Int> = [],
        replyFailure: CommentReadError? = nil
    ) {
        self.rootPages = rootPages
        self.rootFailure = rootFailure
        self.holdsRoots = holdsRoots
        self.replyTotalCount = replyTotalCount
        self.heldReplyPages = heldReplyPages
        self.failingReplyPagesOnce = failingReplyPagesOnce
        self.replyFailure = replyFailure
    }

    var replyRequestCount: Int { replyRequests.count }
    var requestedReplyPages: [Int] { replyRequests.map(\.page) }

    func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) async throws -> CommentRootPage {
        rootRequestCount += 1
        Self.resume(&rootWaiters, reaching: rootRequestCount)
        if let rootFailure { throw rootFailure }
        if holdsRoots {
            return await withCheckedContinuation { heldRoots.append($0) }
        }
        return rootPages.count > 1 ? rootPages.removeFirst() : rootPages[0]
    }

    func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) async throws -> CommentReplyPage {
        replyRequests.append(ReplyRequest(rootID: rootID, page: page))
        Self.resume(&replyWaiters, reaching: replyRequests.count)
        if let replyFailure { throw replyFailure }
        if failingReplyPagesOnce.remove(page) != nil {
            throw CommentReadError.transportFailure
        }
        guard heldReplyPages.contains(page) else {
            return replyPage(rootID: rootID, page: page, replyID: nil)
        }
        let index = replyRequests.count - 1
        activeReplyCount += 1
        maximumActiveReplyCount = max(maximumActiveReplyCount, activeReplyCount)
        return await withCheckedContinuation { replyRequests[index].continuation = $0 }
    }

    func waitForRootRequestCount(_ count: Int) async {
        guard rootRequestCount < count else { return }
        await withCheckedContinuation { rootWaiters.append((count, $0)) }
    }

    func waitForReplyRequestCount(_ count: Int) async {
        guard replyRequests.count < count else { return }
        await withCheckedContinuation { replyWaiters.append((count, $0)) }
    }

    func releaseRoot(_ index: Int, page: CommentRootPage) {
        heldRoots[index]?.resume(returning: page)
        heldRoots[index] = nil
    }

    /// 默认回复 ID 为 `rootID * 100 + page`；需要区分同一根评论的新旧请求时显式指定。
    func releaseReply(at index: Int, replyID: Int64? = nil) {
        guard let continuation = replyRequests[index].continuation else { return }
        replyRequests[index].continuation = nil
        activeReplyCount -= 1
        let request = replyRequests[index]
        continuation.resume(
            returning: replyPage(rootID: request.rootID, page: request.page, replyID: replyID)
        )
    }

    func releaseReplies(rootID: CommentID) {
        for index in replyRequests.indices where replyRequests[index].rootID == rootID {
            releaseReply(at: index)
        }
    }

    func releaseAllHeldReplies() {
        for index in replyRequests.indices {
            releaseReply(at: index)
        }
    }

    private func replyPage(rootID: CommentID, page: Int, replyID: Int64?) -> CommentReplyPage {
        CommentReplyPage(
            rootID: rootID,
            replies: [comment(replyID ?? rootID.rawValue * 100 + Int64(page))],
            pageNumber: page,
            pageSize: 10,
            totalCount: replyTotalCount
        )
    }

    private static func resume(
        _ waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        reaching count: Int
    ) {
        let ready = waiters.filter { count >= $0.0 }
        waiters.removeAll { count >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

private func endPage(_ threads: [CommentThread]) -> CommentRootPage {
    CommentRootPage(
        threads: threads,
        totalCount: threads.count,
        continuation: nil,
        isEnd: true
    )
}

private func thread(_ id: Int64) -> CommentThread {
    CommentThread(root: comment(id))
}

private func comment(_ id: Int64) -> BiliModels.Comment {
    BiliModels.Comment(
        id: CommentID(rawValue: id),
        payload: .unavailable(.deleted)
    )
}
