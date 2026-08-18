import BiliApplication
import BiliModels
import Foundation
import Observation

public enum PlaybackCommentsRootState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case empty
    case failed(CommentReadError)
}

public struct PlaybackCommentReplyState: Sendable, Equatable {
    public var isExpanded = false
    public var replies: [BiliModels.Comment] = []
    public var pageNumber = 1
    public var requestedPageNumber: Int?
    public var totalCount = 0
    public var isLoading = false
    public var isEnd = false
    public var error: CommentReadError?

    public init() {}
}

@MainActor
@Observable
/// 独立拥有当前视频评论的 root 与楼中楼状态，不拥有或控制播放器。
public final class PlaybackCommentsViewModel {
    private struct PendingReplyRequest {
        let rootID: CommentID
        let page: Int
        let subject: CommentSubjectIdentity
        let rootGeneration: Int
    }

    public private(set) var subject: CommentSubjectIdentity?
    public private(set) var sort: CommentSort = .hot
    public private(set) var rootState: PlaybackCommentsRootState = .idle
    public private(set) var threads: [CommentThread] = []
    public private(set) var totalCount = 0
    public private(set) var isLoadingNextPage = false
    public private(set) var paginationError: CommentReadError?
    public private(set) var paginationTermination: CommentPaginationTermination?
    public private(set) var reachedEnd = false
    public private(set) var reachedMemoryLimit = false
    public private(set) var replyStates: [CommentID: PlaybackCommentReplyState] = [:]
    /// 仅在确认评论凭据失效时递增，由 App 层协调账户重校验。
    public private(set) var authenticationRevalidationGeneration = 0

    @ObservationIgnored private let useCase: CommentUseCase
    @ObservationIgnored private var rootTask: Task<Void, Never>?
    @ObservationIgnored private var activeReplyTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeReplyRoots: [UUID: CommentID] = [:]
    @ObservationIgnored private var replyRequestIDs: [CommentID: UUID] = [:]
    @ObservationIgnored private var pendingReplyRequests: [PendingReplyRequest] = []
    @ObservationIgnored private var continuation: CommentContinuation?
    @ObservationIgnored private var rootGeneration = 0
    private static let maximumRetainedRootThreads = 1_000
    private static let maximumConcurrentReplyRequests = 4

    public init(useCase: CommentUseCase) {
        self.useCase = useCase
    }

    public func activateVideo(aid: Int64) {
        guard aid > 0 else {
            reset()
            return
        }
        activate(subject: .video(aid: aid))
    }

    deinit {
        rootTask?.cancel()
        for task in activeReplyTasks.values {
            task.cancel()
        }
    }

    public func activate(subject newSubject: CommentSubjectIdentity) {
        guard subject != newSubject else {
            if rootState == .idle {
                loadInitialPage()
            }
            return
        }
        replaceRootWorkset(subject: newSubject, sort: sort)
    }

    public func selectSort(_ newSort: CommentSort) {
        guard sort != newSort else { return }
        sort = newSort
        guard let subject else { return }
        replaceRootWorkset(subject: subject, sort: newSort)
    }

    public func loadNextPage() {
        guard subject != nil, !isLoadingNextPage, !reachedEnd,
            continuation != nil, paginationTermination == nil,
            rootState == .loaded
        else { return }
        loadRootPage(isInitial: false)
    }

    public func retryRoot() {
        switch rootState {
        case .failed:
            loadInitialPage()
        case .loaded where paginationError != nil:
            loadNextPage()
        case .loaded where paginationTermination != nil:
            paginationTermination = nil
            loadRootPage(isInitial: false)
        case .empty where paginationTermination != nil:
            loadInitialPage()
        case .idle, .loading, .loaded, .empty:
            break
        }
    }

    public func expandReplies(for rootID: CommentID) {
        guard threads.contains(where: { $0.id == rootID }) else { return }
        var state = replyStates[rootID] ?? PlaybackCommentReplyState()
        state.isExpanded = true
        replyStates[rootID] = state
        guard state.replies.isEmpty, !state.isLoading else { return }
        loadReplyPage(rootID: rootID, page: 1)
    }

    public func collapseReplies(for rootID: CommentID) {
        guard var state = replyStates[rootID] else { return }
        pendingReplyRequests.removeAll { $0.rootID == rootID }
        if let requestID = replyRequestIDs.removeValue(forKey: rootID) {
            activeReplyTasks[requestID]?.cancel()
        }
        state.isExpanded = false
        state.isLoading = false
        state.error = nil
        state.requestedPageNumber = nil
        replyStates[rootID] = state
    }

    public func showPreviousReplyPage(for rootID: CommentID) {
        guard let state = replyStates[rootID], state.error == nil,
            state.pageNumber > 1
        else {
            return
        }
        loadReplyPage(rootID: rootID, page: state.pageNumber - 1)
    }

    public func showNextReplyPage(for rootID: CommentID) {
        guard let state = replyStates[rootID], state.error == nil,
            !state.isEnd
        else { return }
        loadReplyPage(rootID: rootID, page: state.pageNumber + 1)
    }

    public func retryReplies(for rootID: CommentID) {
        guard let state = replyStates[rootID], state.error != nil else {
            return
        }
        loadReplyPage(
            rootID: rootID,
            page: state.requestedPageNumber ?? state.pageNumber
        )
    }

    public func reset() {
        rootGeneration += 1
        rootTask?.cancel()
        rootTask = nil
        cancelAllReplyTasks()
        subject = nil
        rootState = .idle
        threads = []
        totalCount = 0
        continuation = nil
        isLoadingNextPage = false
        paginationError = nil
        paginationTermination = nil
        reachedEnd = false
        reachedMemoryLimit = false
        replyStates = [:]
    }

    public func waitForCurrentRootTask() async {
        await rootTask?.value
    }

    func waitForActiveReplyTaskForTesting(rootID: CommentID) async {
        guard let requestID = replyRequestIDs[rootID] else { return }
        await activeReplyTasks[requestID]?.value
    }

    func rootTaskSnapshotForTesting() -> Task<Void, Never>? {
        rootTask
    }

    func replyTaskSnapshotForTesting(rootID: CommentID) -> Task<Void, Never>? {
        guard let requestID = replyRequestIDs[rootID] else { return nil }
        return activeReplyTasks[requestID]
    }

    func replyWorkCountsForTesting() -> (active: Int, pending: Int) {
        (activeReplyTasks.count, pendingReplyRequests.count)
    }

    private func replaceRootWorkset(
        subject newSubject: CommentSubjectIdentity,
        sort newSort: CommentSort
    ) {
        rootGeneration += 1
        rootTask?.cancel()
        rootTask = nil
        cancelAllReplyTasks()
        subject = newSubject
        sort = newSort
        rootState = .idle
        threads = []
        totalCount = 0
        continuation = nil
        isLoadingNextPage = false
        paginationError = nil
        paginationTermination = nil
        reachedEnd = false
        reachedMemoryLimit = false
        replyStates = [:]
        loadInitialPage()
    }

    private func loadInitialPage() {
        guard subject != nil else { return }
        rootGeneration += 1
        rootTask?.cancel()
        continuation = nil
        rootState = .loading
        threads = []
        totalCount = 0
        isLoadingNextPage = false
        paginationError = nil
        paginationTermination = nil
        reachedEnd = false
        reachedMemoryLimit = false
        replyStates = [:]
        loadRootPage(isInitial: true)
    }

    private func loadRootPage(isInitial: Bool) {
        guard let subject else { return }
        let currentGeneration = rootGeneration
        let requestedContinuation = continuation
        let requestedSort = sort
        let existingIDs = Set(threads.map(\.id))
        if !isInitial {
            isLoadingNextPage = true
            paginationError = nil
        }
        let useCase = self.useCase
        rootTask = Task { [weak self, useCase] in
            do {
                let batch = try await useCase.loadRoots(
                    for: subject,
                    sort: requestedSort,
                    after: requestedContinuation,
                    excluding: existingIDs
                )
                try Task.checkCancellation()
                guard let self else { return }
                guard rootGeneration == currentGeneration,
                    self.subject == subject
                else { return }
                let remainingCapacity = max(
                    0,
                    Self.maximumRetainedRootThreads - threads.count
                )
                let droppedByMemoryLimit = batch.threads.count > remainingCapacity
                threads.append(contentsOf: batch.threads.prefix(remainingCapacity))
                totalCount = batch.totalCount
                reachedMemoryLimit =
                    droppedByMemoryLimit
                    || (threads.count == Self.maximumRetainedRootThreads
                        && batch.termination == nil)
                continuation = reachedMemoryLimit ? nil : batch.continuation
                paginationTermination = batch.termination
                reachedEnd =
                    batch.termination == .serverEnd || reachedMemoryLimit
                rootState = threads.isEmpty ? .empty : .loaded
                isLoadingNextPage = false
                paginationError = nil
            } catch is CancellationError {
                guard let self else { return }
                guard rootGeneration == currentGeneration else { return }
                if isInitial {
                    rootState = .idle
                }
                isLoadingNextPage = false
            } catch let error as CommentReadError {
                guard let self else { return }
                guard rootGeneration == currentGeneration else { return }
                recordRootFailure(error, isInitial: isInitial)
            } catch {
                guard let self else { return }
                guard rootGeneration == currentGeneration else { return }
                recordRootFailure(.unavailable, isInitial: isInitial)
            }
            if let self, rootGeneration == currentGeneration {
                rootTask = nil
            }
        }
    }

    private func recordRootFailure(
        _ error: CommentReadError,
        isInitial: Bool
    ) {
        recordAuthenticationInvalidationIfNeeded(error)
        isLoadingNextPage = false
        if isInitial {
            rootState = .failed(error)
        } else {
            paginationError = error
        }
    }

    private func loadReplyPage(rootID: CommentID, page: Int) {
        guard let subject, var state = replyStates[rootID], state.isExpanded,
            !state.isLoading
        else { return }
        state.requestedPageNumber = page
        state.isLoading = true
        state.error = nil
        replyStates[rootID] = state

        pendingReplyRequests.append(
            PendingReplyRequest(
                rootID: rootID,
                page: page,
                subject: subject,
                rootGeneration: rootGeneration
            )
        )
        startPendingReplyRequests()
    }

    private func startPendingReplyRequests() {
        while activeReplyTasks.count < Self.maximumConcurrentReplyRequests,
            !pendingReplyRequests.isEmpty
        {
            let activeRoots = Set(activeReplyRoots.values)
            guard
                let index = pendingReplyRequests.firstIndex(where: { request in
                    !activeRoots.contains(request.rootID)
                })
            else { return }
            let request = pendingReplyRequests.remove(at: index)
            guard rootGeneration == request.rootGeneration,
                subject == request.subject,
                replyRequestIDs[request.rootID] == nil,
                let state = replyStates[request.rootID],
                state.isExpanded,
                state.isLoading,
                state.requestedPageNumber == request.page
            else { continue }
            startReplyRequest(request)
        }
    }

    private func startReplyRequest(_ request: PendingReplyRequest) {
        let requestID = UUID()
        replyRequestIDs[request.rootID] = requestID
        activeReplyRoots[requestID] = request.rootID
        let useCase = self.useCase
        activeReplyTasks[requestID] = Task { [weak self, useCase] in
            defer {
                self?.finishReplyRequest(
                    rootID: request.rootID,
                    requestID: requestID
                )
            }
            do {
                let batch = try await useCase.loadReplies(
                    for: request.subject,
                    rootID: request.rootID,
                    page: request.page
                )
                try Task.checkCancellation()
                guard let self else { return }
                guard replyRequestIDs[request.rootID] == requestID,
                    rootGeneration == request.rootGeneration,
                    subject == request.subject,
                    var current = replyStates[request.rootID], current.isExpanded
                else { return }
                current.replies = batch.replies
                current.pageNumber = batch.pageNumber
                current.requestedPageNumber = nil
                current.totalCount = batch.totalCount
                current.isEnd = batch.isEnd
                current.isLoading = false
                current.error = nil
                replyStates[request.rootID] = current
            } catch is CancellationError {
                guard let self else { return }
                guard replyRequestIDs[request.rootID] == requestID,
                    var current = replyStates[request.rootID]
                else { return }
                current.isLoading = false
                replyStates[request.rootID] = current
            } catch let error as CommentReadError {
                guard let self else { return }
                guard replyRequestIDs[request.rootID] == requestID,
                    rootGeneration == request.rootGeneration,
                    subject == request.subject,
                    var current = replyStates[request.rootID]
                else { return }
                recordAuthenticationInvalidationIfNeeded(error)
                current.isLoading = false
                current.error = error
                replyStates[request.rootID] = current
            } catch {
                guard let self else { return }
                guard replyRequestIDs[request.rootID] == requestID,
                    rootGeneration == request.rootGeneration,
                    subject == request.subject,
                    var current = replyStates[request.rootID]
                else { return }
                current.isLoading = false
                current.error = .unavailable
                replyStates[request.rootID] = current
            }
        }
    }

    private func finishReplyRequest(rootID: CommentID, requestID: UUID) {
        activeReplyTasks[requestID] = nil
        activeReplyRoots[requestID] = nil
        if replyRequestIDs[rootID] == requestID {
            replyRequestIDs[rootID] = nil
        }
        startPendingReplyRequests()
    }

    private func recordAuthenticationInvalidationIfNeeded(
        _ error: CommentReadError
    ) {
        guard error == .authenticationInvalid else { return }
        authenticationRevalidationGeneration += 1
    }

    private func cancelAllReplyTasks() {
        for task in activeReplyTasks.values {
            task.cancel()
        }
        replyRequestIDs = [:]
        pendingReplyRequests = []
    }
}
