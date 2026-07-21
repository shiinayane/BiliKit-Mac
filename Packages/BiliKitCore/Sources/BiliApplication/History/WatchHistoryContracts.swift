import BiliModels

public enum WatchHistoryError: Error, Sendable, Equatable {
    case authenticationRequired
    case requestRestricted
    case serviceRejected(code: Int)
    case transportFailure
    case invalidResponse
}

public protocol WatchHistoryRepository: Sendable {
    func watchHistory(
        after cursor: WatchHistoryCursor?,
        pageSize: Int
    ) async throws -> WatchHistoryPage
}
