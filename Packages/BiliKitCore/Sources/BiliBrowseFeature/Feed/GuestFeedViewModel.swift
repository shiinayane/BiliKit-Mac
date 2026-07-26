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
public final class GuestFeedViewModel {
    public private(set) var state: GuestFeedState = .idle
    private(set) var activeRequest: GuestFeedRequest?
    private(set) var isRefreshing = false
    private(set) var refreshError: GuestApplicationError?

    @ObservationIgnored private let useCase: GuestFeedUseCase
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    private var popularSnapshot = Snapshot()
    private var searchSnapshot = Snapshot()

    public init(useCase: GuestFeedUseCase) {
        self.useCase = useCase
    }

    public func activatePopular(page: Int = 1, pageSize: Int = 20) {
        let request = GuestFeedRequest.popular(page: page, pageSize: pageSize)
        let snapshot =
            popularSnapshot.request == request
            ? popularSnapshot
            : Snapshot(request: request)
        if popularSnapshot.request != request {
            popularSnapshot = snapshot
        }
        activate(request, snapshot: snapshot)
    }

    public func activateSearch(_ query: String, page: Int = 1) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = GuestFeedRequest.search(query: normalizedQuery, page: page)
        guard isValidSearch(normalizedQuery, page: page) else {
            fail(request: request, error: .invalidRequest)
            return
        }

        let snapshot =
            searchSnapshot.request == request
            ? searchSnapshot
            : Snapshot(request: request)
        if searchSnapshot.request != request {
            searchSnapshot = snapshot
        }
        activate(request, snapshot: snapshot)
    }

    func loadPopular(page: Int = 1, pageSize: Int = 20) {
        refresh(.popular(page: page, pageSize: pageSize))
    }

    public func search(_ query: String, page: Int = 1) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = GuestFeedRequest.search(query: normalizedQuery, page: page)
        guard isValidSearch(normalizedQuery, page: page) else {
            fail(request: request, error: .invalidRequest)
            return
        }
        if searchSnapshot.request != request {
            searchSnapshot = Snapshot(request: request)
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

    public func deactivate() {
        generation += 1
        task?.cancel()
        task = nil
        normalizeInterruptedLoad()
        storeActiveSnapshot()
        activeRequest = nil
        state = .idle
        isRefreshing = false
        refreshError = nil
    }

    public func reset() {
        deactivate()
        popularSnapshot = Snapshot()
        searchSnapshot = Snapshot()
    }

    func presentation(
        for request: GuestFeedRequest
    ) -> GuestFeedPresentation {
        guard let snapshot = snapshot(for: request) else {
            return GuestFeedPresentation(
                state: .idle,
                isRefreshing: false,
                refreshError: nil
            )
        }
        return GuestFeedPresentation(
            state: snapshot.state,
            isRefreshing: snapshot.isRefreshing,
            refreshError: snapshot.refreshError
        )
    }

    public func waitForCurrentTask() async {
        await task?.value
    }

    func taskSnapshotForTesting() -> Task<Void, Never>? {
        task
    }

    private func activate(
        _ request: GuestFeedRequest,
        snapshot: Snapshot
    ) {
        if activeRequest == request {
            if case .idle = state {
                refresh(request)
            }
            return
        }

        deactivate()
        activeRequest = request
        apply(snapshot)
        if case .idle = state {
            refresh(request)
        }
    }

    private func refresh(_ request: GuestFeedRequest) {
        if activeRequest != request {
            deactivate()
            activeRequest = request
            apply(snapshot(for: request) ?? Snapshot(request: request))
        }

        generation += 1
        let currentGeneration = generation
        task?.cancel()
        refreshError = nil

        if case .loaded = state {
            isRefreshing = true
        } else {
            state = .loading(request)
            isRefreshing = false
        }
        storeActiveSnapshot()
        task = Task { [weak self] in
            await self?.perform(request, generation: currentGeneration)
        }
    }

    private func fail(
        request: GuestFeedRequest,
        error: GuestApplicationError
    ) {
        deactivate()
        activeRequest = request
        state = .failed(request: request, error: error)
        storeActiveSnapshot()
    }

    private func perform(
        _ request: GuestFeedRequest,
        generation currentGeneration: Int
    ) async {
        do {
            let content = try await useCase.execute(request)
            try Task.checkCancellation()
            guard generation == currentGeneration, activeRequest == request else {
                return
            }
            state = .loaded(content)
            isRefreshing = false
            refreshError = nil
        } catch is CancellationError {
            guard generation == currentGeneration, activeRequest == request else {
                return
            }
            normalizeInterruptedLoad()
        } catch let error as GuestApplicationError {
            guard generation == currentGeneration, activeRequest == request else {
                return
            }
            handleFailure(error, request: request)
        } catch {
            guard generation == currentGeneration, activeRequest == request else {
                return
            }
            handleFailure(.unavailable, request: request)
        }

        if generation == currentGeneration, activeRequest == request {
            task = nil
            storeActiveSnapshot()
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

    private func apply(_ snapshot: Snapshot) {
        state = snapshot.state
        isRefreshing = snapshot.isRefreshing
        refreshError = snapshot.refreshError
    }

    private func storeActiveSnapshot() {
        guard let activeRequest else { return }
        updateSnapshot(for: activeRequest) {
            $0.request = activeRequest
            $0.state = state
            $0.isRefreshing = isRefreshing
            $0.refreshError = refreshError
        }
    }

    private func updateSnapshot(
        for request: GuestFeedRequest,
        _ update: (inout Snapshot) -> Void
    ) {
        switch request {
        case .popular:
            update(&popularSnapshot)
        case .search:
            update(&searchSnapshot)
        }
    }

    private func snapshot(for request: GuestFeedRequest) -> Snapshot? {
        switch request {
        case .popular:
            guard popularSnapshot.request == request else { return nil }
            return popularSnapshot
        case .search:
            guard searchSnapshot.request == request else { return nil }
            return searchSnapshot
        }
    }

    private func isValidSearch(_ query: String, page: Int) -> Bool {
        !query.isEmpty && query.count <= 100 && page > 0
    }
}

private struct Snapshot {
    var request: GuestFeedRequest?
    var state: GuestFeedState = .idle
    var isRefreshing = false
    var refreshError: GuestApplicationError?
}
