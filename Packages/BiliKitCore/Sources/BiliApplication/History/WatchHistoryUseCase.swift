import BiliModels

public struct WatchHistoryUseCase: Sendable {
    private let repository: any WatchHistoryRepository
    private let maximumEmptyPagesToSkip: Int

    public init(
        repository: any WatchHistoryRepository,
        maximumEmptyPagesToSkip: Int = 3
    ) {
        self.repository = repository
        self.maximumEmptyPagesToSkip = max(0, maximumEmptyPagesToSkip)
    }

    public func load(
        after continuation: WatchHistoryContinuation? = nil,
        pageSize: Int = 20
    ) async throws -> WatchHistoryPage {
        guard (1...50).contains(pageSize) else {
            throw WatchHistoryError.invalidResponse
        }
        var requestContinuation = continuation
        var skippedEmptyPages = 0

        while true {
            try Task.checkCancellation()
            let page = try await repository.watchHistory(
                after: requestContinuation,
                pageSize: pageSize
            )
            guard page.items.isEmpty,
                  let nextContinuation = page.continuation
            else {
                return page
            }
            guard nextContinuation != requestContinuation else {
                throw WatchHistoryError.invalidResponse
            }
            guard skippedEmptyPages < maximumEmptyPagesToSkip else {
                return page
            }
            skippedEmptyPages += 1
            requestContinuation = nextContinuation
        }
    }
}
