import BiliApplication
import BiliModels
import Foundation
import Observation

public enum WatchHistoryState: Sendable, Equatable {
    case idle
    case loading
    case loaded(
        items: [WatchHistoryItem],
        continuation: WatchHistoryContinuation?,
        loadMoreError: WatchHistoryError?
    )
    case loadingMore(
        items: [WatchHistoryItem],
        continuation: WatchHistoryContinuation
    )
    case failed(WatchHistoryError)
}

@MainActor
@Observable
/// 拥有当前登录会话的历史工作集、分页 continuation 与最新请求 Task。
///
/// `reset` 会清除个性化内容；普通路由停用只取消在途请求，并在分页中断时保留已显示条目。
public final class WatchHistoryViewModel {
    public private(set) var state: WatchHistoryState = .idle
    public private(set) var successfulReloadGeneration: UInt64 = 0
    /// 仅供 renderer 对 near-end 事件去重；不包含或编码远端 continuation。
    public private(set) var paginationTailIdentity: String?
    /// 空页或全重复页保留 continuation 时，必须由用户显式继续，避免 near-end 连续扫描。
    public private(set) var requiresManualLoadMore = false

    public var requiresAuthentication: Bool {
        switch state {
        case .failed(.authenticationRequired),
            .loaded(_, _, .authenticationRequired):
            true
        default:
            false
        }
    }

    public var isBusy: Bool {
        switch state {
        case .loading, .loadingMore:
            true
        case .idle, .loaded, .failed:
            false
        }
    }

    @ObservationIgnored private let useCase: WatchHistoryUseCase
    @ObservationIgnored private let loadTask = LatestTask()
    @ObservationIgnored private var tailIdentityGeneration: UInt64 = 0
    @ObservationIgnored private var loadingMoreWasManual = false
    @ObservationIgnored private var consumedContinuations: [WatchHistoryContinuation] = []

    public init(useCase: WatchHistoryUseCase) {
        self.useCase = useCase
    }

    public func loadIfNeeded() {
        guard state == .idle else { return }
        reload()
    }

    public func reload() {
        clearTailIdentity()
        requiresManualLoadMore = false
        loadingMoreWasManual = false
        consumedContinuations.removeAll(keepingCapacity: false)
        begin(state: .loading) { [weak self] isCurrent in
            guard let self else { return }
            do {
                let page = try await useCase.load()
                guard isCurrent() else { return }
                applyLoaded(
                    items: page.items,
                    continuation: page.continuation,
                    loadMoreError: nil,
                    rearmAutomaticTail: !page.items.isEmpty,
                    requiresManualLoadMore: page.items.isEmpty && page.continuation != nil
                )
                successfulReloadGeneration &+= 1
            } catch {
                guard isCurrent() else { return }
                // 本任务未被取消却收到取消，说明认证会话在请求途中切换；给出可重试终态而不是停在 loading。
                state = .failed(error as? WatchHistoryError ?? .transportFailure)
            }
        }
    }

    public func loadMore() {
        guard case .loaded(let items, .some(let continuation), _) = state else { return }
        loadingMoreWasManual = requiresManualLoadMore
        requiresManualLoadMore = false
        begin(state: .loadingMore(items: items, continuation: continuation)) {
            [weak self] isCurrent in
            guard let self else { return }
            do {
                let page = try await useCase.load(after: continuation)
                guard isCurrent() else { return }
                var seen = Set(items.map(\.bvid))
                let appended = page.items.filter {
                    seen.insert($0.bvid).inserted
                }
                consumedContinuations.append(continuation)
                let continuationLoops =
                    page.continuation.map {
                        consumedContinuations.contains($0)
                    } ?? false
                applyLoaded(
                    items: items + appended,
                    continuation: continuationLoops ? nil : page.continuation,
                    loadMoreError: continuationLoops ? .invalidResponse : nil,
                    rearmAutomaticTail: !continuationLoops && !appended.isEmpty,
                    requiresManualLoadMore: !continuationLoops && appended.isEmpty
                        && page.continuation != nil
                )
            } catch {
                guard isCurrent() else { return }
                // 认证切换带来的取消只保留已显示条目，并要求用户显式继续。
                let wasCancelled = error is CancellationError
                applyLoaded(
                    items: items,
                    continuation: continuation,
                    loadMoreError: wasCancelled
                        ? nil : error as? WatchHistoryError ?? .transportFailure,
                    rearmAutomaticTail: false,
                    requiresManualLoadMore: wasCancelled || loadingMoreWasManual
                )
            }
        }
    }

    /// 取消请求并从内存删除全部个性化历史，供登出与窗口关闭调用。
    public func reset() {
        loadTask.cancel()
        clearTailIdentity()
        requiresManualLoadMore = false
        loadingMoreWasManual = false
        consumedContinuations.removeAll(keepingCapacity: false)
        state = .idle
    }

    /// 停用页面请求而不抹掉已加载条目；迟到结果由 `LatestTask` 拒绝。
    public func deactivateRoute() {
        loadTask.cancel()
        switch state {
        case .loading:
            state = .idle
        case .loadingMore(let items, let continuation):
            requiresManualLoadMore = loadingMoreWasManual
            loadingMoreWasManual = false
            state = .loaded(
                items: items,
                continuation: continuation,
                loadMoreError: nil
            )
        case .idle, .loaded, .failed:
            break
        }
    }

    public func waitForCurrentTask() async {
        await loadTask.wait()
    }

    /// 认证重新确认失败时保持已清理的隐私边界，并给 History 提供可重试的终态。
    public func reportAuthenticationRevalidationFailure() {
        guard state == .idle else { return }
        state = .failed(.transportFailure)
    }

    private func begin(
        state initialState: WatchHistoryState,
        operation: @escaping @MainActor (_ isCurrent: @escaping LatestTask.IsCurrent) async -> Void
    ) {
        state = initialState
        loadTask.replace(operation)
    }

    private func applyLoaded(
        items: [WatchHistoryItem],
        continuation: WatchHistoryContinuation?,
        loadMoreError: WatchHistoryError?,
        rearmAutomaticTail: Bool,
        requiresManualLoadMore: Bool
    ) {
        self.requiresManualLoadMore = requiresManualLoadMore
        loadingMoreWasManual = false
        if continuation == nil || requiresManualLoadMore {
            paginationTailIdentity = nil
        } else if rearmAutomaticTail {
            tailIdentityGeneration &+= 1
            paginationTailIdentity = "history-tail-\(tailIdentityGeneration)"
        }
        state = .loaded(
            items: items,
            continuation: continuation,
            loadMoreError: loadMoreError
        )
    }

    private func clearTailIdentity() {
        paginationTailIdentity = nil
    }
}
