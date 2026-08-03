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

/// 在进入 adapter 前验证并规范化 Feed 意图的一次性用例。
public struct GuestFeedUseCase: Sendable {
    private let repository: any GuestContentRepository

    public init(repository: any GuestContentRepository) {
        self.repository = repository
    }

    /// 执行一个独立请求；取消和“哪次意图仍可写回 UI”由上层 ViewModel 保留。
    public func execute(_ request: GuestFeedRequest) async throws -> GuestFeedContent {
        switch request {
        case .popular(let page, let pageSize):
            guard page > 0, (1...50).contains(pageSize) else {
                throw GuestApplicationError.invalidRequest
            }
            return .popular(
                try await repository.popular(page: page, pageSize: pageSize)
            )
        case .search(let query, let page):
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
