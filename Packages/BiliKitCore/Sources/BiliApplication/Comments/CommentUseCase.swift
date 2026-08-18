import BiliModels

public struct CommentUseCase: Sendable {
    private let repository: any CommentRepository

    public init(repository: any CommentRepository) {
        self.repository = repository
    }

    public func loadRoots(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation? = nil,
        excluding existingIDs: Set<CommentID> = []
    ) async throws -> CommentRootBatch {
        try Task.checkCancellation()
        let page = try await repository.rootComments(
            for: subject,
            sort: sort,
            after: continuation
        )
        try Task.checkCancellation()

        var seen = existingIDs
        let uniqueThreads = page.threads.filter { seen.insert($0.id).inserted }
        let termination: CommentPaginationTermination?
        if page.isEnd || page.continuation == nil {
            termination = .serverEnd
        } else if page.threads.isEmpty {
            termination = .emptyPage
        } else if uniqueThreads.isEmpty {
            termination = .duplicatePage
        } else {
            termination = nil
        }

        return CommentRootBatch(
            threads: uniqueThreads,
            totalCount: page.totalCount,
            continuation: termination == .serverEnd ? nil : page.continuation,
            termination: termination
        )
    }

    public func loadReplies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int = 10
    ) async throws -> CommentReplyBatch {
        guard page > 0, pageSize > 0 else {
            throw CommentReadError.invalidResponse
        }
        try Task.checkCancellation()
        let result = try await repository.replies(
            for: subject,
            rootID: rootID,
            page: page,
            pageSize: pageSize
        )
        try Task.checkCancellation()
        guard result.rootID == rootID, result.pageNumber == page,
            result.pageSize == pageSize, result.totalCount >= 0
        else {
            throw CommentReadError.invalidResponse
        }

        var seen: Set<CommentID> = []
        let uniqueReplies = result.replies.filter { seen.insert($0.id).inserted }
        let finalPage =
            result.totalCount == 0
            ? 0
            : (result.totalCount - 1) / result.pageSize + 1
        return CommentReplyBatch(
            rootID: rootID,
            replies: uniqueReplies,
            pageNumber: result.pageNumber,
            pageSize: result.pageSize,
            totalCount: result.totalCount,
            isEnd: result.pageNumber >= finalPage
                || result.replies.isEmpty
        )
    }
}
