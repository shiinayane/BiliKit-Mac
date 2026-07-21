import BiliModels
import Foundation

public enum GuestFeedRequest: Sendable, Equatable {
    case popular(page: Int, pageSize: Int)
    case search(query: String, page: Int)
}

public enum GuestFeedContent: Sendable, Equatable {
    case popular(PopularPage)
    case search(query: String, page: SearchPage)
}

public struct GuestFeedUseCase: Sendable {
    private let repository: any GuestContentRepository

    public init(repository: any GuestContentRepository) {
        self.repository = repository
    }

    public func execute(_ request: GuestFeedRequest) async throws -> GuestFeedContent {
        switch request {
        case let .popular(page, pageSize):
            guard page > 0, (1...50).contains(pageSize) else {
                throw GuestApplicationError.invalidRequest
            }
            return .popular(
                try await repository.popular(page: page, pageSize: pageSize)
            )
        case let .search(query, page):
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedQuery.isEmpty,
                  normalizedQuery.count <= 100,
                  page > 0
            else {
                throw GuestApplicationError.invalidRequest
            }
            return .search(
                query: normalizedQuery,
                page: try await repository.searchVideos(
                    keyword: normalizedQuery,
                    page: page
                )
            )
        }
    }
}
