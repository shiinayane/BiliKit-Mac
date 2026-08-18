import BiliApplication
import BiliModels
import Testing

@testable import BiliBrowseFeature

@Suite(.timeLimit(.minutes(1)))
struct PlaybackCommentsViewModelTests {
    @Test
    @MainActor
    func initialLoadAndPaginationAppendWithoutMovingExistingThreads() async {
        let continuation = CommentContinuation(rawValue: "page-2")
        let repository = SequencedCommentRepository(
            rootPages: [
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
                ),
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
        #expect(model.reachedEnd)
        #expect(model.rootState == .loaded)
    }

    @Test
    @MainActor
    func stableContinuationCanAppendMultiplePagesUntilTheServerEnds() async {
        let continuation = CommentContinuation(rawValue: "stable-session")
        let repository = SequencedCommentRepository(
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
                ),
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
        let repository = SequencedCommentRepository(
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
                ),
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
        let repository = SequencedCommentRepository(
            rootPages: [
                endPage([thread(1)]),
                endPage([thread(2)]),
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
        let repository = ControlledRootCommentRepository()
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await repository.waitForRequestCount(1)
        let oldTask = try #require(model.rootTaskSnapshotForTesting())

        model.selectSort(.latest)
        await repository.waitForRequestCount(2)
        await repository.releaseRequest(1, page: endPage([thread(2)]))
        await model.waitForCurrentRootTask()
        await repository.releaseRequest(0, page: endPage([thread(1)]))
        await oldTask.value

        #expect(model.sort == .latest)
        #expect(model.threads.map(\.id.rawValue) == [2])
    }

    @Test
    @MainActor
    func collapsingThreadCancelsItsLateReplyReplacement() async throws {
        let rootID = CommentID(rawValue: 10)
        let repository = ControlledReplyCommentRepository(root: thread(10))
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: rootID)
        await repository.waitForReplyRequest()
        let replyTask = try #require(
            model.replyTaskSnapshotForTesting(rootID: rootID)
        )

        model.collapseReplies(for: rootID)
        await repository.releaseReply(
            CommentReplyPage(
                rootID: rootID,
                replies: [comment(11)],
                pageNumber: 1,
                pageSize: 10,
                totalCount: 1
            )
        )
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
        let repository = RetryingReplyCommentRepository(root: thread(20))
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: rootID)
        await model.waitForActiveReplyTaskForTesting(rootID: rootID)

        model.showNextReplyPage(for: rootID)
        await model.waitForActiveReplyTaskForTesting(rootID: rootID)
        #expect(model.replyStates[rootID]?.error == .transportFailure)

        model.showNextReplyPage(for: rootID)
        #expect(await repository.requestedPages == [1, 2])

        model.retryReplies(for: rootID)
        await model.waitForActiveReplyTaskForTesting(rootID: rootID)
        #expect(await repository.requestedPages == [1, 2, 2])
        #expect(model.replyStates[rootID]?.error == nil)
    }

    @Test
    @MainActor
    func rootRetentionStopsAtTheInMemoryLimit() async {
        let repository = SequencedCommentRepository(
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
        let repository = PagingControlledReplyCommentRepository(root: thread(30))
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: rootID)
        await model.waitForActiveReplyTaskForTesting(rootID: rootID)
        model.showNextReplyPage(for: rootID)
        await repository.waitForSecondPageRequest()
        let pendingTask = try #require(
            model.replyTaskSnapshotForTesting(rootID: rootID)
        )

        model.collapseReplies(for: rootID)
        await repository.releaseSecondPage()
        await pendingTask.value
        model.expandReplies(for: rootID)

        let state = try #require(model.replyStates[rootID])
        #expect(state.pageNumber == 1)
        #expect(state.requestedPageNumber == nil)
        #expect(state.replies.map(\.id.rawValue) == [31])
        #expect(await repository.requestedPages == [1, 2])
    }

    @Test
    @MainActor
    func replyRequestsUseBoundedWindowConcurrency() async {
        let roots = (1...6).map { thread(Int64($0)) }
        let repository = ConcurrentReplyCommentRepository(roots: roots)
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        for root in roots {
            model.expandReplies(for: root.id)
        }
        await repository.waitForRequestCount(4)

        #expect(model.replyWorkCountsForTesting() == (active: 4, pending: 2))
        #expect(await repository.maximumActiveCount == 4)

        model.collapseReplies(for: roots[0].id)
        model.expandReplies(for: roots[0].id)
        await Task.yield()
        #expect(await repository.requestCount == 4)
        #expect(model.replyWorkCountsForTesting() == (active: 4, pending: 3))

        await repository.release(rootID: roots[0].id)
        await repository.waitForRequestCount(5)
        #expect(model.replyWorkCountsForTesting() == (active: 4, pending: 2))
        #expect(await repository.maximumActiveCount == 4)

        await repository.releaseAllActive()
        await repository.waitForRequestCount(7)
        await repository.releaseAllActive()
    }

    @Test
    @MainActor
    func subjectReplacementRejectsLateReplyWithReusedRootID() async throws {
        let root = thread(50)
        let repository = ReusedRootReplyCommentRepository(root: root)
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
        await Task.yield()
        #expect(await repository.replyRequestCount == 1)

        await repository.releaseReply(at: 0, replyID: 51)
        await repository.waitForReplyRequestCount(2)
        await repository.releaseReply(at: 1, replyID: 52)
        await model.waitForActiveReplyTaskForTesting(rootID: root.id)

        let state = try #require(model.replyStates[root.id])
        #expect(state.replies.map(\.id.rawValue) == [52])
        #expect(model.replyWorkCountsForTesting() == (active: 0, pending: 0))

        model.reset()
        #expect(model.replyWorkCountsForTesting() == (active: 0, pending: 0))
    }

    @Test
    @MainActor
    func rootAndReplyAuthenticationInvalidationPublishRevalidationIntent() async throws {
        let rootFailureModel = PlaybackCommentsViewModel(
            useCase: CommentUseCase(
                repository: AuthenticationInvalidCommentRepository(root: nil)
            )
        )
        rootFailureModel.activate(subject: .video(aid: 700_001))
        await rootFailureModel.waitForCurrentRootTask()

        #expect(rootFailureModel.rootState == .failed(.authenticationInvalid))
        #expect(rootFailureModel.authenticationRevalidationGeneration == 1)

        let root = thread(80)
        let replyFailureModel = PlaybackCommentsViewModel(
            useCase: CommentUseCase(
                repository: AuthenticationInvalidCommentRepository(root: root)
            )
        )
        replyFailureModel.activate(subject: .video(aid: 700_001))
        await replyFailureModel.waitForCurrentRootTask()
        replyFailureModel.expandReplies(for: root.id)
        await replyFailureModel.waitForActiveReplyTaskForTesting(rootID: root.id)

        #expect(
            replyFailureModel.replyStates[root.id]?.error
                == .authenticationInvalid
        )
        #expect(replyFailureModel.authenticationRevalidationGeneration == 1)
    }
}

private actor AuthenticationInvalidCommentRepository: CommentRepository {
    private let root: CommentThread?

    init(root: CommentThread?) {
        self.root = root
    }

    func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) throws -> CommentRootPage {
        guard let root else { throw CommentReadError.authenticationInvalid }
        return CommentRootPage(
            threads: [root],
            totalCount: 1,
            continuation: nil,
            isEnd: true
        )
    }

    func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) throws -> CommentReplyPage {
        throw CommentReadError.authenticationInvalid
    }
}

private actor SequencedCommentRepository: CommentRepository {
    private var rootPages: [CommentRootPage]
    private(set) var rootRequestCount = 0

    init(rootPages: [CommentRootPage]) {
        self.rootPages = rootPages
    }

    func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) throws -> CommentRootPage {
        rootRequestCount += 1
        return rootPages.removeFirst()
    }

    func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) throws -> CommentReplyPage {
        throw CommentReadError.unavailable
    }
}

private actor ControlledRootCommentRepository: CommentRepository {
    private var requests: [CheckedContinuation<CommentRootPage, any Error>?] = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) async throws -> CommentRootPage {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            resumeRequestWaitersIfNeeded()
        }
    }

    func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) throws -> CommentReplyPage {
        throw CommentReadError.unavailable
    }

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func releaseRequest(_ index: Int, page: CommentRootPage) {
        requests[index]?.resume(returning: page)
        requests[index] = nil
    }

    private func resumeRequestWaitersIfNeeded() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestWaiters {
            if requests.count >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        requestWaiters = pending
    }
}

private actor ControlledReplyCommentRepository: CommentRepository {
    private let root: CommentThread
    private var replyContinuation: CheckedContinuation<CommentReplyPage, any Error>?
    private var replyStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(root: CommentThread) {
        self.root = root
    }

    func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) -> CommentRootPage {
        endPage([root])
    }

    func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) async throws -> CommentReplyPage {
        try await withCheckedThrowingContinuation { continuation in
            replyContinuation = continuation
            for waiter in replyStartWaiters {
                waiter.resume()
            }
            replyStartWaiters = []
        }
    }

    func waitForReplyRequest() async {
        guard replyContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            replyStartWaiters.append(continuation)
        }
    }

    func releaseReply(_ page: CommentReplyPage) {
        replyContinuation?.resume(returning: page)
        replyContinuation = nil
    }
}

private actor RetryingReplyCommentRepository: CommentRepository {
    private let root: CommentThread
    private(set) var requestedPages: [Int] = []
    private var didFailSecondPage = false

    init(root: CommentThread) {
        self.root = root
    }

    func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) -> CommentRootPage {
        endPage([root])
    }

    func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) throws -> CommentReplyPage {
        requestedPages.append(page)
        if page == 2, !didFailSecondPage {
            didFailSecondPage = true
            throw CommentReadError.transportFailure
        }
        return CommentReplyPage(
            rootID: rootID,
            replies: [comment(Int64(page * 100))],
            pageNumber: page,
            pageSize: pageSize,
            totalCount: 25
        )
    }
}

private actor PagingControlledReplyCommentRepository: CommentRepository {
    private let root: CommentThread
    private(set) var requestedPages: [Int] = []
    private var secondPageContinuation: CheckedContinuation<CommentReplyPage, Never>?
    private var secondPageWaiters: [CheckedContinuation<Void, Never>] = []

    init(root: CommentThread) {
        self.root = root
    }

    func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) -> CommentRootPage {
        endPage([root])
    }

    func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) async -> CommentReplyPage {
        requestedPages.append(page)
        if page == 1 {
            return CommentReplyPage(
                rootID: rootID,
                replies: [comment(31)],
                pageNumber: 1,
                pageSize: pageSize,
                totalCount: 11
            )
        }
        return await withCheckedContinuation { continuation in
            secondPageContinuation = continuation
            for waiter in secondPageWaiters { waiter.resume() }
            secondPageWaiters = []
        }
    }

    func waitForSecondPageRequest() async {
        guard secondPageContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            secondPageWaiters.append(continuation)
        }
    }

    func releaseSecondPage() {
        secondPageContinuation?.resume(
            returning: CommentReplyPage(
                rootID: root.id,
                replies: [comment(32)],
                pageNumber: 2,
                pageSize: 10,
                totalCount: 11
            )
        )
        secondPageContinuation = nil
    }
}

private actor ConcurrentReplyCommentRepository: CommentRepository {
    private let roots: [CommentThread]
    private var continuations: [CommentID: CheckedContinuation<CommentReplyPage, Never>] = [:]
    private(set) var requestCount = 0
    private var activeCount = 0
    private(set) var maximumActiveCount = 0
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(roots: [CommentThread]) {
        self.roots = roots
    }

    func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) -> CommentRootPage {
        endPage(roots)
    }

    func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) async -> CommentReplyPage {
        requestCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        resumeRequestWaitersIfNeeded()
        return await withCheckedContinuation { continuation in
            continuations[rootID] = continuation
        }
    }

    func waitForRequestCount(_ expected: Int) async {
        guard requestCount < expected else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((expected, continuation))
        }
    }

    func release(rootID: CommentID) {
        guard let continuation = continuations.removeValue(forKey: rootID) else { return }
        activeCount -= 1
        continuation.resume(
            returning: CommentReplyPage(
                rootID: rootID,
                replies: [comment(rootID.rawValue * 100)],
                pageNumber: 1,
                pageSize: 10,
                totalCount: 1
            )
        )
    }

    func releaseAllActive() {
        let active = continuations
        continuations = [:]
        activeCount = 0
        for (rootID, continuation) in active {
            continuation.resume(
                returning: CommentReplyPage(
                    rootID: rootID,
                    replies: [comment(rootID.rawValue * 100)],
                    pageNumber: 1,
                    pageSize: 10,
                    totalCount: 1
                )
            )
        }
    }

    private func resumeRequestWaitersIfNeeded() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestWaiters {
            if requestCount >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        requestWaiters = pending
    }
}

private actor ReusedRootReplyCommentRepository: CommentRepository {
    private let root: CommentThread
    private var replyRequests: [(CommentID, CheckedContinuation<CommentReplyPage, Never>?)] = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(root: CommentThread) {
        self.root = root
    }

    var replyRequestCount: Int { replyRequests.count }

    func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) -> CommentRootPage {
        endPage([root])
    }

    func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) async -> CommentReplyPage {
        await withCheckedContinuation { continuation in
            replyRequests.append((rootID, continuation))
            resumeRequestWaitersIfNeeded()
        }
    }

    func waitForReplyRequestCount(_ count: Int) async {
        guard replyRequests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func releaseReply(at index: Int, replyID: Int64) {
        guard replyRequests.indices.contains(index),
            let continuation = replyRequests[index].1
        else { return }
        let rootID = replyRequests[index].0
        replyRequests[index].1 = nil
        continuation.resume(
            returning: CommentReplyPage(
                rootID: rootID,
                replies: [comment(replyID)],
                pageNumber: 1,
                pageSize: 10,
                totalCount: 1
            )
        )
    }

    private func resumeRequestWaitersIfNeeded() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestWaiters {
            if replyRequests.count >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        requestWaiters = pending
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
