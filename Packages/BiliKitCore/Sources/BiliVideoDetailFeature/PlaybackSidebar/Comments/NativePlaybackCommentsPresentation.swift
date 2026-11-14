import BiliApplication
import BiliModels
import Foundation

/// 评论行上的写入此刻能不能用：赞与踩要窗口能写入，回复还要评论区接受新评论（只读、禁止新增或已关闭时输入卡片不显示，
/// 回复点了也没有去处）。
struct NativePlaybackCommentWriteAvailability: Equatable, Hashable {
    let canReact: Bool
    let canReply: Bool

    static let unavailable = NativePlaybackCommentWriteAvailability(
        canReact: false,
        canReply: false
    )
}

/// 一条根评论在侧栏里的呈现：评论、楼中楼状态，以及由全部可见内容算出的 `revision` 与 `reactionRevision`。
///
/// `revision` 在构造时按评论对象、根评论、预览回复与楼中楼状态（含已加载的回复）求哈希；它变化时这一行重载，
/// 并作为行高缓存键与正文渲染作用域的一部分，旧作用域里记下的表情失败随之作废。点赞数与当前账户的赞踩不进 `revision`，
/// 单独算进 `reactionRevision`：它变化时这一行只就地重新配置；正文的渲染作用域不变，评论行据此跳过正文的重新渲染，行高也不
/// 重新测量（元信息一行的高度与计数无关）。
struct NativePlaybackCommentThreadPresentation: Equatable {
    let subject: CommentSubjectIdentity
    let thread: CommentThread
    let replyState: PlaybackCommentReplyState?
    let revision: Int
    let reactionRevision: Int
    /// 行上的赞、踩、回复此刻是否可用；变化时并进 `reactionRevision`，行就地重新配置。
    let writeAvailability: NativePlaybackCommentWriteAvailability

    /// 根评论、预览回复或已加载的回复里有没有时间戳链接；只有这些评论随分 P 时长变化需要重新配置。
    var containsTimestampLinks: Bool {
        let comments = [thread.root] + thread.replyPreview + (replyState?.shownReplies ?? [])
        return comments.contains { comment in
            guard case .available(let details) = comment.payload else { return false }
            return NativePlaybackTextLinks.containsTimestamp(details.content.links)
        }
    }

    var textScope: NativePlaybackCommentTextScope {
        NativePlaybackCommentTextScope(
            subject: subject,
            rootID: thread.id,
            revision: revision
        )
    }

    init(
        subject: CommentSubjectIdentity,
        thread: CommentThread,
        replyState: PlaybackCommentReplyState?,
        writeAvailability: NativePlaybackCommentWriteAvailability
    ) {
        self.subject = subject
        self.thread = thread
        self.replyState = replyState
        self.writeAvailability = writeAvailability
        var hasher = Hasher()
        hasher.combine(subject)
        hasher.combine(thread.id)
        Self.hash(thread.root, into: &hasher)
        for reply in thread.replyPreview { Self.hash(reply, into: &hasher) }
        if let replyState {
            hasher.combine(replyState.isExpanded)
            hasher.combine(replyState.pageNumber)
            hasher.combine(replyState.requestedPageNumber)
            hasher.combine(replyState.totalCount)
            hasher.combine(replyState.isLoading)
            // 加载提示延迟露出时只有它变化；漏掉它时提示永远露不出来。
            hasher.combine(replyState.isLoadingStatusVisible)
            hasher.combine(replyState.isEnd)
            hasher.combine(String(describing: replyState.error))
            for reply in replyState.replies { Self.hash(reply, into: &hasher) }
            // 对话状态同样决定面板内容：漏掉它时进出对话、加载更多都不会让这一行重载。
            if let dialog = replyState.dialog {
                hasher.combine(dialog.dialogID)
                hasher.combine(dialog.nextFloor)
                hasher.combine(dialog.hasLoadedFirstPage)
                hasher.combine(dialog.isLoading)
                hasher.combine(String(describing: dialog.error))
                for reply in dialog.replies { Self.hash(reply, into: &hasher) }
            }
        }
        revision = hasher.finalize()
        var reactionHasher = Hasher()
        reactionHasher.combine(writeAvailability)
        let reacted =
            [thread.root] + thread.replyPreview + (replyState?.replies ?? [])
            + (replyState?.dialog?.replies ?? [])
        for comment in reacted {
            guard case .available(let details) = comment.payload else { continue }
            reactionHasher.combine(comment.id)
            reactionHasher.combine(details.likeCount)
            reactionHasher.combine(details.viewerReaction)
        }
        reactionRevision = reactionHasher.finalize()
    }

    private static func hash(_ comment: BiliModels.Comment, into hasher: inout Hasher) {
        hasher.combine(comment.id)
        switch comment.payload {
        case .unavailable(let reason):
            hasher.combine(String(describing: reason))
        case .available(let details):
            hasher.combine(details.author.id)
            hasher.combine(details.author.name)
            hasher.combine(details.author.avatar)
            hasher.combine(details.author.sex)
            hasher.combine(details.author.level)
            hasher.combine(details.author.isHardcoreMember)
            hasher.combine(details.author.isVIP)
            hasher.combine(details.author.verification)
            hasher.combine(details.author.isUploader)
            hasher.combine(details.content.message)
            hasher.combine(details.content.emotes)
            hasher.combine(details.content.links)
            hasher.combine(details.content.pictures)
            hasher.combine(details.content.pictureCount)
            hasher.combine(details.createdAt)
            hasher.combine(details.location)
            hasher.combine(details.replyCount)
            hasher.combine(details.provenance)
        }
    }
}

/// 评论区的呈现快照：从 `PlaybackCommentsViewModel` 读出的评论对象、排序、根状态、列表与分页状态。
///
/// 只是值；页脚、排序是否可用等派生状态都从这里计算。
struct NativePlaybackCommentsPresentation: Equatable {
    let subject: CommentSubjectIdentity?
    let sort: CommentSort
    let rootState: PlaybackCommentsRootState
    let totalCount: Int
    let threads: [NativePlaybackCommentThreadPresentation]
    let isLoadingNextPage: Bool
    let paginationError: CommentReadError?
    let paginationTermination: CommentPaginationTermination?
    let reachedEnd: Bool
    let reachedMemoryLimit: Bool

    /// `canWrite` 是窗口此刻能否写入；与评论区是否接受新评论一起决定每一楼行上的操作是否可用。
    ///
    /// 没有评论 ViewModel 时没有可写的评论。
    @MainActor
    init(model: PlaybackCommentsViewModel?, canWrite: Bool) {
        subject = model?.subject
        sort = model?.sort ?? .hot
        rootState = model?.rootState ?? .idle
        totalCount = model?.totalCount ?? 0
        isLoadingNextPage = model?.isLoadingNextPage ?? false
        paginationError = model?.paginationError
        paginationTermination = model?.paginationTermination
        reachedEnd = model?.reachedEnd ?? false
        reachedMemoryLimit = model?.reachedMemoryLimit ?? false
        guard let model, let subject = model.subject else {
            threads = []
            return
        }
        threads = model.threads.map {
            NativePlaybackCommentThreadPresentation(
                subject: subject,
                thread: $0,
                replyState: model.replyStates[$0.id],
                writeAvailability: NativePlaybackCommentWriteAvailability(
                    canReact: canWrite,
                    canReply: canWrite && model.acceptsNewComments
                )
            )
        }
    }

    var sortIsEnabled: Bool {
        rootState == .loaded || rootState == .empty
    }

    var footer: NativePlaybackCommentsFooter {
        if isLoadingNextPage { return .loading }
        if let paginationError { return .failed(paginationError) }
        if paginationTermination == .emptyPage
            || paginationTermination == .duplicatePage
        {
            return .stopped
        }
        if reachedEnd {
            return .end(memoryLimited: reachedMemoryLimit)
        }
        return .loadMore
    }
}

extension CommentReadError {
    /// 不给重试的失败在评论列表、分页与楼中楼显示的说明。
    ///
    /// 可重试的失败由各处自己的“加载失败”文案加重试按钮表示；无法发出的请求与内容页同一中性说明，
    /// 见 SECURITY-MODEL §3。
    var nonRetryableDescription: String {
        switch self {
        case .authenticationRequired:
            VideoDetailFeatureStrings.localized("需要登录")
        case .closed:
            VideoDetailFeatureStrings.localized("评论区已关闭")
        case .contentUnavailable:
            VideoDetailFeatureStrings.localized("内容不存在或不可见")
        default:
            VideoDetailFeatureStrings.localized("当前无法完成这次请求。")
        }
    }
}

/// 评论列表末尾的页脚状态：加载中、失败、服务端给了空页或重复页而停止、到底（含达到条数上限）或可以加载更多。
enum NativePlaybackCommentsFooter: Equatable, Hashable {
    case loading
    /// 是否给重试只由 `CommentReadError.isRetryable` 决定。
    case failed(CommentReadError)
    case stopped
    case end(memoryLimited: Bool)
    case loadMore
}

/// 近尾分页的尾部身份：评论对象加最后一条根评论。
///
/// 尾部变化（新的一页到达）才允许再次请求。
struct NativePlaybackCommentsPaginationIdentity: Equatable {
    let subject: CommentSubjectIdentity
    let lastRootID: CommentID?
}
