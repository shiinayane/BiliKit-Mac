import BiliModels

public enum CommentReadError: Error, Sendable, Equatable {
    case authenticationInvalid
    case requestRestricted
    case serviceRejected(code: Int)
    case transportFailure
    case invalidResponse
    case unavailable
}

/// API adapter 生成并消费的不透明主评论分页令牌。
public struct CommentContinuation: Sendable, Equatable, Hashable {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct CommentRootPage: Sendable, Equatable {
    public let threads: [CommentThread]
    public let totalCount: Int
    public let continuation: CommentContinuation?
    public let isEnd: Bool

    public init(
        threads: [CommentThread],
        totalCount: Int,
        continuation: CommentContinuation?,
        isEnd: Bool
    ) {
        self.threads = threads
        self.totalCount = totalCount
        self.continuation = continuation
        self.isEnd = isEnd
    }
}

public struct CommentReplyPage: Sendable, Equatable {
    public let rootID: CommentID
    public let replies: [Comment]
    public let pageNumber: Int
    public let pageSize: Int
    public let totalCount: Int

    public init(
        rootID: CommentID,
        replies: [Comment],
        pageNumber: Int,
        pageSize: Int,
        totalCount: Int
    ) {
        self.rootID = rootID
        self.replies = replies
        self.pageNumber = pageNumber
        self.pageSize = pageSize
        self.totalCount = totalCount
    }
}

/// 匿名只读评论 port；endpoint、WBI 和远端 DTO 留在具体 adapter。
public protocol CommentRepository: Sendable {
    func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) async throws -> CommentRootPage

    func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) async throws -> CommentReplyPage
}

public enum CommentPaginationTermination: Sendable, Equatable {
    case serverEnd
    case emptyPage
    case duplicatePage
    case continuationStalled
}

public struct CommentRootBatch: Sendable, Equatable {
    public let threads: [CommentThread]
    public let totalCount: Int
    public let continuation: CommentContinuation?
    public let termination: CommentPaginationTermination?

    public init(
        threads: [CommentThread],
        totalCount: Int,
        continuation: CommentContinuation?,
        termination: CommentPaginationTermination?
    ) {
        self.threads = threads
        self.totalCount = totalCount
        self.continuation = continuation
        self.termination = termination
    }
}

public struct CommentReplyBatch: Sendable, Equatable {
    public let rootID: CommentID
    public let replies: [Comment]
    public let pageNumber: Int
    public let pageSize: Int
    public let totalCount: Int
    public let isEnd: Bool

    public init(
        rootID: CommentID,
        replies: [Comment],
        pageNumber: Int,
        pageSize: Int,
        totalCount: Int,
        isEnd: Bool
    ) {
        self.rootID = rootID
        self.replies = replies
        self.pageNumber = pageNumber
        self.pageSize = pageSize
        self.totalCount = totalCount
        self.isEnd = isEnd
    }
}
