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
public final class WatchHistoryViewModel {
    public private(set) var state: WatchHistoryState = .idle

    public var requiresAuthentication: Bool {
        switch state {
        case .failed(.authenticationRequired),
             .loaded(_, _, .authenticationRequired):
            true
        default:
            false
        }
    }

    @ObservationIgnored private let useCase: WatchHistoryUseCase
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(useCase: WatchHistoryUseCase) {
        self.useCase = useCase
    }

    public func loadIfNeeded() {
        guard state == .idle else { return }
        reload()
    }

    public func reload() {
        begin(state: .loading) { [weak self] operationGeneration in
            guard let self else { return }
            do {
                let page = try await useCase.load()
                apply(
                    .loaded(
                        items: page.items,
                        continuation: page.continuation,
                        loadMoreError: nil
                    ),
                    generation: operationGeneration
                )
            } catch is CancellationError {
                return
            } catch let error as WatchHistoryError {
                apply(.failed(error), generation: operationGeneration)
            } catch {
                apply(.failed(.transportFailure), generation: operationGeneration)
            }
        }
    }

    public func loadMore() {
        guard case let .loaded(items, .some(continuation), _) = state else { return }
        begin(
            state: .loadingMore(items: items, continuation: continuation),
            clearExistingTask: false
        ) { [weak self] operationGeneration in
            guard let self else { return }
            do {
                let page = try await useCase.load(after: continuation)
                var seen = Set(items.map(\.bvid))
                let merged = items + page.items.filter {
                    seen.insert($0.bvid).inserted
                }
                apply(
                    .loaded(
                        items: merged,
                        continuation: page.continuation,
                        loadMoreError: nil
                    ),
                    generation: operationGeneration
                )
            } catch is CancellationError {
                return
            } catch let error as WatchHistoryError {
                apply(
                    .loaded(
                        items: items,
                        continuation: continuation,
                        loadMoreError: error
                    ),
                    generation: operationGeneration
                )
            } catch {
                apply(
                    .loaded(
                        items: items,
                        continuation: continuation,
                        loadMoreError: .transportFailure
                    ),
                    generation: operationGeneration
                )
            }
        }
    }

    public func reset() {
        generation += 1
        task?.cancel()
        task = nil
        state = .idle
    }

    public func cancelTransientWork() {
        task?.cancel()
        task = nil
    }

    public func deactivateRoute() {
        generation += 1
        task?.cancel()
        task = nil
        switch state {
        case .loading:
            state = .idle
        case let .loadingMore(items, continuation):
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
        await task?.value
    }

    private func begin(
        state initialState: WatchHistoryState,
        clearExistingTask: Bool = true,
        operation: @escaping @MainActor (Int) async -> Void
    ) {
        generation += 1
        let operationGeneration = generation
        if clearExistingTask {
            task?.cancel()
        }
        state = initialState
        task = Task { [weak self] in
            await operation(operationGeneration)
            guard let self, generation == operationGeneration else { return }
            task = nil
        }
    }

    private func apply(
        _ nextState: WatchHistoryState,
        generation operationGeneration: Int
    ) {
        guard generation == operationGeneration, !Task.isCancelled else { return }
        state = nextState
    }
}
