import BiliModels

public struct WatchHistoryUseCase: Sendable {
    private let repository: any WatchHistoryRepository

    public init(repository: any WatchHistoryRepository) {
        self.repository = repository
    }

    public func load(
        after cursor: WatchHistoryCursor? = nil,
        pageSize: Int = 20
    ) async throws -> WatchHistoryPage {
        guard (1...50).contains(pageSize) else {
            throw WatchHistoryError.invalidResponse
        }
        return try await repository.watchHistory(
            after: cursor,
            pageSize: pageSize
        )
    }
}
