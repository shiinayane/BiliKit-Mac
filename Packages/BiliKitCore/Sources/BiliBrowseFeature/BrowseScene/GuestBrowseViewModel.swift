import BiliApplication
import Foundation
import Observation

public enum GuestFeedState: Sendable, Equatable {
    case idle
    case loading(GuestFeedRequest)
    case loaded(GuestFeedContent)
    case failed(request: GuestFeedRequest, error: GuestApplicationError)
}

struct GuestFeedPresentation: Sendable, Equatable {
    let state: GuestFeedState
    let isRefreshing: Bool
    let refreshError: GuestApplicationError?
}

@MainActor
@Observable
public final class GuestBrowseViewModel {
    public private(set) var state: GuestFeedState = .idle
    private(set) var activeRequestIdentity: GuestFeedRequest?
    private(set) var isRefreshing = false
    private(set) var refreshError: GuestApplicationError?

    @ObservationIgnored private let useCase: GuestFeedUseCase
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    private var popularWorkset = FeedWorkset()
    private var searchWorkset = FeedWorkset()

    public init(useCase: GuestFeedUseCase) {
        self.useCase = useCase
    }

    public func activatePopular(page: Int = 1, pageSize: Int = 20) {
        let request = GuestFeedRequest.popular(page: page, pageSize: pageSize)
        let workset =
            popularWorkset.request == request
            ? popularWorkset
            : FeedWorkset(request: request)
        if popularWorkset.request != request {
            popularWorkset = workset
        }
        activateWorkset(request, workset: workset)
    }

    public func activateSearch(_ query: String, page: Int = 1) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = GuestFeedRequest.search(query: normalizedQuery, page: page)
        guard isValidSearch(normalizedQuery, page: page) else {
            fail(request: request, error: .invalidRequest)
            return
        }

        let workset =
            searchWorkset.request == request
            ? searchWorkset
            : FeedWorkset(request: request)
        if searchWorkset.request != request {
            searchWorkset = workset
        }
        activateWorkset(request, workset: workset)
    }

    func refreshPopular(page: Int = 1, pageSize: Int = 20) {
        refresh(.popular(page: page, pageSize: pageSize))
    }

    public func search(_ query: String, page: Int = 1) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = GuestFeedRequest.search(query: normalizedQuery, page: page)
        guard isValidSearch(normalizedQuery, page: page) else {
            fail(request: request, error: .invalidRequest)
            return
        }
        if searchWorkset.request != request {
            searchWorkset = FeedWorkset(request: request)
        }
        refresh(request)
    }

    func retry(_ request: GuestFeedRequest) {
        guard
            case .failed(let failedRequest, _) =
                presentation(for: request).state,
            failedRequest == request
        else {
            return
        }
        refresh(request)
    }

    public func deactivateRoute() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        normalizeInterruptedLoad()
        storeActiveWorkset()
        activeRequestIdentity = nil
        state = .idle
        isRefreshing = false
        refreshError = nil
    }

    public func reset() {
        deactivateRoute()
        popularWorkset = FeedWorkset()
        searchWorkset = FeedWorkset()
    }

    func presentation(
        for request: GuestFeedRequest
    ) -> GuestFeedPresentation {
        guard let workset = workset(for: request) else {
            return GuestFeedPresentation(
                state: .idle,
                isRefreshing: false,
                refreshError: nil
            )
        }
        return GuestFeedPresentation(
            state: workset.state,
            isRefreshing: workset.isRefreshing,
            refreshError: workset.refreshError
        )
    }

    public func waitForCurrentTask() async {
        await loadTask?.value
    }

    func taskSnapshotForTesting() -> Task<Void, Never>? {
        loadTask
    }

    private func activateWorkset(
        _ request: GuestFeedRequest,
        workset: FeedWorkset
    ) {
        if activeRequestIdentity == request {
            if case .idle = state {
                refresh(request)
            }
            return
        }

        deactivateRoute()
        activeRequestIdentity = request
        apply(workset)
        if case .idle = state {
            refresh(request)
        }
    }

    private func refresh(_ request: GuestFeedRequest) {
        if activeRequestIdentity != request {
            deactivateRoute()
            activeRequestIdentity = request
            apply(workset(for: request) ?? FeedWorkset(request: request))
        }

        generation += 1
        let currentGeneration = generation
        loadTask?.cancel()
        refreshError = nil

        if case .loaded = state {
            isRefreshing = true
        } else {
            state = .loading(request)
            isRefreshing = false
        }
        storeActiveWorkset()
        loadTask = Task { [weak self] in
            await self?.performLoad(request, generation: currentGeneration)
        }
    }

    private func fail(
        request: GuestFeedRequest,
        error: GuestApplicationError
    ) {
        deactivateRoute()
        activeRequestIdentity = request
        state = .failed(request: request, error: error)
        storeActiveWorkset()
    }

    private func performLoad(
        _ request: GuestFeedRequest,
        generation currentGeneration: Int
    ) async {
        do {
            let content = try await useCase.execute(request)
            try Task.checkCancellation()
            guard generation == currentGeneration, activeRequestIdentity == request else {
                return
            }
            state = .loaded(content)
            isRefreshing = false
            refreshError = nil
        } catch is CancellationError {
            guard generation == currentGeneration, activeRequestIdentity == request else {
                return
            }
            normalizeInterruptedLoad()
        } catch let error as GuestApplicationError {
            guard generation == currentGeneration, activeRequestIdentity == request else {
                return
            }
            handleFailure(error, request: request)
        } catch {
            guard generation == currentGeneration, activeRequestIdentity == request else {
                return
            }
            handleFailure(.unavailable, request: request)
        }

        if generation == currentGeneration, activeRequestIdentity == request {
            loadTask = nil
            storeActiveWorkset()
        }
    }

    private func handleFailure(
        _ error: GuestApplicationError,
        request: GuestFeedRequest
    ) {
        if case .loaded = state {
            isRefreshing = false
            refreshError = error
        } else {
            state = .failed(request: request, error: error)
        }
    }

    private func normalizeInterruptedLoad() {
        isRefreshing = false
        refreshError = nil
        if case .loading = state {
            state = .idle
        }
    }

    private func apply(_ workset: FeedWorkset) {
        state = workset.state
        isRefreshing = workset.isRefreshing
        refreshError = workset.refreshError
    }

    private func storeActiveWorkset() {
        guard let activeRequestIdentity else { return }
        updateWorkset(for: activeRequestIdentity) {
            $0.request = activeRequestIdentity
            $0.state = state
            $0.isRefreshing = isRefreshing
            $0.refreshError = refreshError
        }
    }

    private func updateWorkset(
        for request: GuestFeedRequest,
        _ update: (inout FeedWorkset) -> Void
    ) {
        switch request {
        case .popular:
            update(&popularWorkset)
        case .search:
            update(&searchWorkset)
        }
    }

    private func workset(for request: GuestFeedRequest) -> FeedWorkset? {
        switch request {
        case .popular:
            guard popularWorkset.request == request else { return nil }
            return popularWorkset
        case .search:
            guard searchWorkset.request == request else { return nil }
            return searchWorkset
        }
    }

    private func isValidSearch(_ query: String, page: Int) -> Bool {
        !query.isEmpty && query.count <= 100 && page > 0
    }
}

private struct FeedWorkset {
    var request: GuestFeedRequest?
    var state: GuestFeedState = .idle
    var isRefreshing = false
    var refreshError: GuestApplicationError?
}
