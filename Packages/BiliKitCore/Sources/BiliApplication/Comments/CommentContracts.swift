import BiliModels

/// 评论读取的应用级错误，由 BiliAPI 的 `BiliCommentRepository` 从 `BiliAPIError.Failure` 映射，
/// 不并入内容域。
///
/// 认证与内容页同一四态：无凭据、凭据失效（唯一触发账户复核）、本地凭据读不到、风控。调用方只读
/// `requiresAccountRevalidation` 与 `isRetryable`，不各自比较错误值。
public enum CommentReadError: Error, Sendable, Hashable {
    /// 客户端无法发出的请求：参数不合规，或授权器拒绝（path 不在 allowlist），见 SECURITY-MODEL §3。
    case invalidRequest
    case authenticationRequired
    case authenticationInvalid
    case authenticationUnavailable
    case requestRestricted
    case serviceRejected(code: Int)
    /// 稿件或根评论不存在、已删除或不可见（业务码 -404／62002／62004），与内容域同一分类。
    case contentUnavailable
    /// 评论区已关闭；不是可重试的失败。
    case closed
    case transportFailure
    case invalidResponse
    case unavailable
}

extension CommentReadError {
    /// 只有凭据失效需要窗口复核账户会话；评论 ViewModel 据此递增复核计数，不各自比较错误值。
    public var requiresAccountRevalidation: Bool {
        self == .authenticationInvalid
    }

    /// 用户重试可能得到不同结果才提供重试；评论列表、分页与楼中楼的失败界面据此决定是否显示重试。
    ///
    /// 需要登录、内容不存在或不可见、评论区已关闭与客户端无法发出的请求重试只会得到同样的结果，
    /// 与内容域规则一致。
    public var isRetryable: Bool {
        switch self {
        case .authenticationRequired, .contentUnavailable, .closed, .invalidRequest:
            false
        case .authenticationInvalid, .authenticationUnavailable, .requestRestricted,
            .serviceRejected, .transportFailure, .invalidResponse, .unavailable:
            true
        }
    }
}

/// API adapter 生成并消费的不透明主评论分页令牌。
public struct CommentContinuation: Sendable, Equatable, Hashable {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// 评论区此刻能否发新评论，以及接口给的输入框占位文字；由 BiliAPI 从根评论页的 `control` 与 `config` 映射。
///
/// 评论区只读（`config.read_only`）或禁止新增（`control.input_disable`，例如用户涉及合约争议时）都不能发；占位文字为空时
/// 为 nil，由界面用自己的文案。评论区关闭时根评论读取本身就失败（`CommentReadError.closed`），不经这里。
public struct CommentInputPolicy: Sendable, Equatable {
    public let acceptsNewComments: Bool
    /// 发楼层评论时的占位文字。
    public let rootPlaceholder: String?
    /// 回复时的占位文字。
    public let replyPlaceholder: String?

    /// 接口没给限制时的缺省：可以发，用界面自己的占位文字。
    public static let open = CommentInputPolicy(
        acceptsNewComments: true,
        rootPlaceholder: nil,
        replyPlaceholder: nil
    )

    public init(acceptsNewComments: Bool, rootPlaceholder: String?, replyPlaceholder: String?) {
        self.acceptsNewComments = acceptsNewComments
        self.rootPlaceholder = rootPlaceholder
        self.replyPlaceholder = replyPlaceholder
    }
}

/// `CommentRepository.rootComments` 返回的一页主评论，尚未去重，也未判定分页是否终止。
///
/// `isEnd` 为真或 `continuation` 为 nil 时 `CommentUseCase` 视为远端已到底；`totalCount`
/// 是远端报告的评论数。
public struct CommentRootPage: Sendable, Equatable {
    public let threads: [CommentThread]
    public let totalCount: Int
    public let continuation: CommentContinuation?
    public let isEnd: Bool
    public let inputPolicy: CommentInputPolicy

    public init(
        threads: [CommentThread],
        totalCount: Int,
        continuation: CommentContinuation?,
        isEnd: Bool,
        inputPolicy: CommentInputPolicy
    ) {
        self.threads = threads
        self.totalCount = totalCount
        self.continuation = continuation
        self.isEnd = isEnd
        self.inputPolicy = inputPolicy
    }
}

/// `CommentRepository.replies` 返回的一页楼中楼回复。
///
/// `CommentUseCase` 校验它与请求的根评论、页码、页大小一致且总数不为负，否则按无效响应处理。
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

/// `CommentRepository.dialog` 返回的一页「查看对话」：同一串对话里按楼层排列的回复，以及下一页的起点楼层。
///
/// `nextFloor` 为 nil 表示已到底。`CommentUseCase.loadDialog` 校验根评论与对话和请求一致、下一页起点在请求楼层之后，
/// 并按 `CommentID` 去重后原样交给评论 ViewModel。
public struct CommentDialogPage: Sendable, Equatable {
    public let rootID: CommentID
    public let dialogID: CommentID
    public let replies: [Comment]
    public let nextFloor: Int?

    public init(rootID: CommentID, dialogID: CommentID, replies: [Comment], nextFloor: Int?) {
        self.rootID = rootID
        self.dialogID = dialogID
        self.replies = replies
        self.nextFloor = nextFloor
    }
}

/// 匿名只读评论 port；endpoint、WBI 和远端 DTO 留在具体 adapter。
///
/// 实现是 BiliAPI 的 `BiliCommentRepository`，只经 `CommentUseCase` 调用。失败抛出
/// `CommentReadError`，取消原样传播为 `CancellationError`；分页令牌只能回传 adapter 自己发出的
/// `CommentContinuation`。
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

    /// 一串对话从 `fromFloor` 楼起（含；nil 为第一页）的一页回复。
    func dialog(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        dialogID: CommentID,
        fromFloor: Int?,
        pageSize: Int
    ) async throws -> CommentDialogPage
}

/// 主评论分页停止的原因，由 `CommentUseCase.loadRoots` 判定。
///
/// `serverEnd`：远端表示已到底；`emptyPage`：本页没有评论；`duplicatePage`：
/// 本页全部与已显示的重复。后两种仍带回游标，但评论 ViewModel 不再翻页，侧栏显示为“已停止”
/// 而不是“已到底”。
public enum CommentPaginationTermination: Sendable, Equatable {
    case serverEnd
    case emptyPage
    case duplicatePage
}

/// `CommentUseCase.loadRoots` 交给评论 ViewModel 的一批主评论，已按 `CommentID`
/// 去掉与已显示及本页前文重复的条目。
///
/// `termination` 为 nil 表示可以继续翻页；为 `.serverEnd` 时 `continuation` 一定为 nil。
public struct CommentRootBatch: Sendable, Equatable {
    public let threads: [CommentThread]
    public let totalCount: Int
    public let continuation: CommentContinuation?
    public let termination: CommentPaginationTermination?
    public let inputPolicy: CommentInputPolicy

    public init(
        threads: [CommentThread],
        totalCount: Int,
        continuation: CommentContinuation?,
        termination: CommentPaginationTermination?,
        inputPolicy: CommentInputPolicy
    ) {
        self.threads = threads
        self.totalCount = totalCount
        self.continuation = continuation
        self.termination = termination
        self.inputPolicy = inputPolicy
    }
}

/// `CommentUseCase.loadReplies` 交给评论 ViewModel 的一页楼中楼，页内已按 `CommentID` 去重。
///
/// `isEnd` 在本页已是按总数推算的最后一页，或本页为空时为真。
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
