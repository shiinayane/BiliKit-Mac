import BiliApplication
import BiliModels

@testable import BiliVideoDetailFeature

/// 本 target 唯一的 CommentRepository 替身：根评论按序返回（最后一页可重复）、挂起或失败——前
/// `answeredRootRequestCount` 次请求照常返回，之后的才挂起或失败；回复按页可挂起、首次失败或持续失败，并记录
/// 请求数与挂起回复的并发峰值。对话固定两页：第一页两条、下一页从 3 楼起一条后到底，可整体挂起，也可让第一次请求失败。
actor CommentRepositoryStub: CommentRepository {
    private struct ReplyRequest {
        let rootID: CommentID
        let page: Int
        var continuation: CheckedContinuation<CommentReplyPage, Never>?
    }

    private var rootPages: [CommentRootPage]
    private let rootFailure: CommentReadError?
    private let holdsRoots: Bool
    private let answeredRootRequestCount: Int
    private let replyTotalCount: Int
    private let heldReplyPages: Set<Int>
    private var failingReplyPagesOnce: Set<Int>
    private let replyFailure: CommentReadError?
    private var heldRoots: [CheckedContinuation<CommentRootPage, Never>?] = []
    private var replyRequests: [ReplyRequest] = []
    private var activeReplyCount = 0
    private var rootWaiters = CountWaiters()
    private var replyWaiters = CountWaiters()
    private(set) var rootRequestCount = 0
    private(set) var maximumActiveReplyCount = 0
    private let holdsDialogs: Bool
    private let failsFirstDialogRequest: Bool
    private var heldDialogs: [CheckedContinuation<Void, Never>] = []
    private var dialogWaiters = CountWaiters()
    /// 对话请求的起点楼层，按到达顺序。
    private(set) var dialogRequests: [Int?] = []

    init(
        rootPages: [CommentRootPage] = [],
        rootFailure: CommentReadError? = nil,
        holdsRoots: Bool = false,
        answeredRootRequestCount: Int = 0,
        replyTotalCount: Int = 1,
        heldReplyPages: Set<Int> = [],
        failingReplyPagesOnce: Set<Int> = [],
        replyFailure: CommentReadError? = nil,
        holdsDialogs: Bool = false,
        failsFirstDialogRequest: Bool = false
    ) {
        self.holdsDialogs = holdsDialogs
        self.failsFirstDialogRequest = failsFirstDialogRequest
        self.rootPages = rootPages
        self.rootFailure = rootFailure
        self.holdsRoots = holdsRoots
        self.answeredRootRequestCount = answeredRootRequestCount
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
        rootWaiters.resume(reaching: rootRequestCount)
        let isAnswered = rootRequestCount <= answeredRootRequestCount
        if let rootFailure, !isAnswered { throw rootFailure }
        if holdsRoots, !isAnswered {
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
        replyWaiters.resume(reaching: replyRequests.count)
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

    func dialog(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        dialogID: CommentID,
        fromFloor: Int?,
        pageSize: Int
    ) async throws -> CommentDialogPage {
        dialogRequests.append(fromFloor)
        dialogWaiters.resume(reaching: dialogRequests.count)
        if holdsDialogs {
            await withCheckedContinuation { heldDialogs.append($0) }
        }
        if failsFirstDialogRequest, dialogRequests.count == 1 {
            throw CommentReadError.transportFailure
        }
        let base = rootID.rawValue * 1_000
        let ids: [Int64] = fromFloor == nil ? [base + 1, base + 2] : [base + 3]
        return CommentDialogPage(
            rootID: rootID,
            dialogID: dialogID,
            replies: ids.map {
                BiliModels.Comment(
                    id: CommentID(rawValue: $0),
                    rootID: rootID,
                    dialogID: dialogID,
                    payload: .unavailable(.unavailable)
                )
            },
            nextFloor: fromFloor == nil ? 3 : nil
        )
    }

    func waitForDialogRequestCount(_ count: Int) async {
        await withCheckedContinuation {
            dialogWaiters.add($0, until: count, current: dialogRequests.count)
        }
    }

    func releaseDialogs() {
        for continuation in heldDialogs { continuation.resume() }
        heldDialogs.removeAll()
    }

    func waitForRootRequestCount(_ count: Int) async {
        await withCheckedContinuation {
            rootWaiters.add($0, until: count, current: rootRequestCount)
        }
    }

    func waitForReplyRequestCount(_ count: Int) async {
        await withCheckedContinuation {
            replyWaiters.add($0, until: count, current: replyRequests.count)
        }
    }

    func releaseRoot(_ index: Int, page: CommentRootPage) {
        heldRoots[index]?.resume(returning: page)
        heldRoots[index] = nil
    }

    /// 放行全部仍挂起的根评论请求，测试结束前调用，不留下永不恢复的请求。
    func releaseAllHeldRoots(page: CommentRootPage) {
        for index in heldRoots.indices {
            releaseRoot(index, page: page)
        }
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
            replies: [
                BiliModels.Comment(
                    id: CommentID(rawValue: replyID ?? rootID.rawValue * 100 + Int64(page)),
                    payload: .unavailable(.unavailable)
                )
            ],
            pageNumber: page,
            pageSize: 10,
            totalCount: replyTotalCount
        )
    }
}

/// 评论区呈现之后的分页状态，经 ViewModel 的真实翻页得到。
enum CommentsFixtureNextPage {
    /// 还有下一页、没有在加载。
    case available
    /// 下一页请求挂起中。
    case loading
    /// 下一页请求失败。
    case failed(CommentReadError)
    /// 下一页与已有评论完全重复，自动翻页停止。
    case duplicate
    /// 首页即服务端最后一页。
    case serverEnd
}

/// 经生产路径构造评论区呈现：驱动 `PlaybackCommentsViewModel` 到目标状态，再取
/// `NativePlaybackCommentsPresentation(model:canWrite:)`；结束前放行挂起的请求，ViewModel 随之释放。
@MainActor
func liveCommentsPresentation(
    subject: CommentSubjectIdentity = .video(aid: 700_001),
    sort: CommentSort = .hot,
    threads: [CommentThread] = [],
    totalCount: Int? = nil,
    rootFailure: CommentReadError? = nil,
    rootIsLoading: Bool = false,
    next: CommentsFixtureNextPage = .available
) async -> NativePlaybackCommentsPresentation {
    let firstPage = CommentRootPage(
        threads: threads,
        totalCount: totalCount ?? threads.count,
        continuation: CommentContinuation(rawValue: "fixture"),
        isEnd: {
            guard case .serverEnd = next else { return false }
            return true
        }(),
        inputPolicy: .open
    )
    let nextFailure: CommentReadError? = {
        if case .failed(let error) = next { return error }
        return nil
    }()
    let holdsNext: Bool = {
        if case .loading = next { return true }
        return false
    }()
    let repository = CommentRepositoryStub(
        rootPages: [firstPage],
        rootFailure: rootFailure ?? nextFailure,
        holdsRoots: rootIsLoading || holdsNext,
        answeredRootRequestCount: rootFailure == nil && !rootIsLoading ? 1 : 0
    )
    let model = PlaybackCommentsViewModel(useCase: CommentUseCase(repository: repository))
    // 没有评论对象时换排序只记下排序、不发请求，激活时按它请求首页。
    model.selectSort(sort)
    model.activate(subject: subject)
    if rootIsLoading {
        await repository.waitForRootRequestCount(1)
    } else {
        await model.waitForCurrentRootTask()
        switch next {
        case .available, .serverEnd:
            break
        case .loading:
            model.loadNextPage()
            await repository.waitForRootRequestCount(2)
        case .failed, .duplicate:
            model.loadNextPage()
            await model.waitForCurrentRootTask()
        }
    }
    let presentation = NativePlaybackCommentsPresentation(model: model, canWrite: false)
    await repository.releaseAllHeldRoots(page: firstPage)
    await model.waitForCurrentRootTask()
    return presentation
}
