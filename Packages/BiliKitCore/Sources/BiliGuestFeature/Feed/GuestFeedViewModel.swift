import BiliApplication
import Foundation
import Observation

public enum GuestFeedState: Sendable, Equatable {
    case idle
    case loading(GuestFeedRequest)
    case loaded(GuestFeedContent)
    case failed(request: GuestFeedRequest, error: GuestApplicationError)
}

@MainActor
@Observable
public final class GuestFeedViewModel {
    public private(set) var state: GuestFeedState = .idle

    @ObservationIgnored private let useCase: GuestFeedUseCase
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(useCase: GuestFeedUseCase) {
        self.useCase = useCase
    }

    public func loadPopular(page: Int = 1, pageSize: Int = 20) {
        load(.popular(page: page, pageSize: pageSize))
    }

    public func search(_ query: String, page: Int = 1) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = GuestFeedRequest.search(query: normalizedQuery, page: page)
        guard !normalizedQuery.isEmpty,
              normalizedQuery.count <= 100,
              page > 0
        else {
            fail(request: request, error: .invalidRequest)
            return
        }
        load(request)
    }

    public func retry() {
        guard case let .failed(request, _) = state else { return }
        load(request)
    }

    public func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        state = .idle
    }

    public func waitForCurrentTask() async {
        await task?.value
    }

    private func load(_ request: GuestFeedRequest) {
        generation += 1
        let currentGeneration = generation
        task?.cancel()
        state = .loading(request)
        task = Task { [weak self] in
            await self?.perform(request, generation: currentGeneration)
        }
    }

    private func fail(
        request: GuestFeedRequest,
        error: GuestApplicationError
    ) {
        generation += 1
        task?.cancel()
        task = nil
        state = .failed(request: request, error: error)
    }

    private func perform(
        _ request: GuestFeedRequest,
        generation currentGeneration: Int
    ) async {
        do {
            let content = try await useCase.execute(request)
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            state = .loaded(content)
        } catch is CancellationError {
            guard generation == currentGeneration else { return }
            state = .idle
        } catch let error as GuestApplicationError {
            guard generation == currentGeneration else { return }
            state = .failed(request: request, error: error)
        } catch {
            guard generation == currentGeneration else { return }
            state = .failed(request: request, error: .unavailable)
        }
        if generation == currentGeneration {
            task = nil
        }
    }
}
