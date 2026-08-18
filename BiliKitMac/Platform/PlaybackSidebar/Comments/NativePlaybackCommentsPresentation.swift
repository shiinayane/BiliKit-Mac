import BiliApplication
import BiliBrowseFeature
import BiliModels
import Foundation

struct NativePlaybackCommentThreadPresentation: Equatable {
    let subject: CommentSubjectIdentity
    let thread: CommentThread
    let replyState: PlaybackCommentReplyState?
    let revision: Int

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
        replyState: PlaybackCommentReplyState?
    ) {
        self.subject = subject
        self.thread = thread
        self.replyState = replyState
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
            hasher.combine(replyState.isEnd)
            hasher.combine(String(describing: replyState.error))
            for reply in replyState.replies { Self.hash(reply, into: &hasher) }
        }
        revision = hasher.finalize()
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
            hasher.combine(details.likeCount)
            hasher.combine(details.replyCount)
            hasher.combine(details.visibility)
            hasher.combine(details.provenance)
        }
    }
}

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

    @MainActor
    init(model: PlaybackCommentsViewModel?) {
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
                replyState: model.replyStates[$0.id]
            )
        }
    }

    init(
        subject: CommentSubjectIdentity?,
        sort: CommentSort,
        rootState: PlaybackCommentsRootState,
        totalCount: Int,
        threads: [NativePlaybackCommentThreadPresentation],
        isLoadingNextPage: Bool = false,
        paginationError: CommentReadError? = nil,
        paginationTermination: CommentPaginationTermination? = nil,
        reachedEnd: Bool = false,
        reachedMemoryLimit: Bool = false
    ) {
        self.subject = subject
        self.sort = sort
        self.rootState = rootState
        self.totalCount = totalCount
        self.threads = threads
        self.isLoadingNextPage = isLoadingNextPage
        self.paginationError = paginationError
        self.paginationTermination = paginationTermination
        self.reachedEnd = reachedEnd
        self.reachedMemoryLimit = reachedMemoryLimit
    }

    var sortIsEnabled: Bool {
        rootState == .loaded || rootState == .empty
    }

    var footer: NativePlaybackCommentsFooter {
        if isLoadingNextPage { return .loading }
        if paginationError != nil { return .retry }
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

enum NativePlaybackCommentsFooter: Equatable, Hashable {
    case loading
    case retry
    case stopped
    case end(memoryLimited: Bool)
    case loadMore
}
