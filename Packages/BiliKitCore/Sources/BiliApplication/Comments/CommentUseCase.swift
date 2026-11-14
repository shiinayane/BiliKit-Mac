import BiliModels

/// 评论读取的一次性用例：主评论按已显示的 ID 去重并判定分页终止，楼中楼校验页码与页大小，
/// 并校验响应与请求衔接。
///
/// 不拥有 Task、分页状态与并发上限（`PlaybackCommentsViewModel`）；adapter 调用前后都检查取消，
/// 被取消的请求抛出 `CancellationError` 而不返回结果。
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
            termination: termination,
            inputPolicy: page.inputPolicy
        )
    }

    /// 「查看对话」一页请求的条数，与网页一致；对话按楼层游标往下加载，没有页码。
    ///
    /// 调大一次加载更多、点「加载更多」的次数更少，响应也更大。
    public static let dialogPageSize = 20

    /// 一串对话从 `fromFloor` 楼起的一页；起点不是正数时不请求（`invalidRequest`）。
    ///
    /// 响应的根评论或对话与请求不符、或下一页起点没有越过请求楼层时按无效响应失败，服务端反复给出同一起点时不会
    /// 原地重复请求。是否到底由 adapter 按接口的楼层信息判断，这里不改。
    public func loadDialog(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        dialogID: CommentID,
        fromFloor: Int?
    ) async throws -> CommentDialogPage {
        if let fromFloor, fromFloor <= 0 {
            throw CommentReadError.invalidRequest
        }
        try Task.checkCancellation()
        let result = try await repository.dialog(
            for: subject,
            rootID: rootID,
            dialogID: dialogID,
            fromFloor: fromFloor,
            pageSize: Self.dialogPageSize
        )
        try Task.checkCancellation()
        guard result.rootID == rootID, result.dialogID == dialogID,
            result.nextFloor.map({ $0 > (fromFloor ?? 0) }) ?? true
        else {
            throw CommentReadError.invalidResponse
        }
        var seen: Set<CommentID> = []
        let uniqueReplies = result.replies.filter { seen.insert($0.id).inserted }
        return CommentDialogPage(
            rootID: rootID,
            dialogID: dialogID,
            replies: uniqueReplies,
            nextFloor: result.nextFloor
        )
    }

    /// 楼中楼一页请求的条数，楼中楼面板也按它推算总页数。
    ///
    /// 调大每页更长、翻页更少，响应也更大。
    public static let replyPageSize = 10

    public func loadReplies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int
    ) async throws -> CommentReplyBatch {
        let pageSize = Self.replyPageSize
        guard page > 0 else {
            throw CommentReadError.invalidRequest
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
