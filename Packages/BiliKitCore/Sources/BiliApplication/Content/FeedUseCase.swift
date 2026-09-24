import BiliModels
import Foundation

public enum FeedRequest: Sendable, Equatable {
    case recommendation(continuation: RecommendationContinuation?)
    case popular(page: Int, pageSize: Int)
    case search(VideoSearchRequest)

    public static func search(query: String, page: Int) -> Self {
        .search(
            VideoSearchRequest(
                criteria: VideoSearchCriteria(query: query),
                page: page
            )
        )
    }
}

public enum FeedContent: Sendable, Equatable {
    case recommendation(RecommendationPage)
    case popular(PopularPage)
    case search(query: String, page: SearchPage)
}

/// 在进入 adapter 前验证并规范化 Feed 意图的一次性用例。
public struct FeedUseCase: Sendable {
    private let repository: any FeedRepository

    public init(repository: any FeedRepository) {
        self.repository = repository
    }

    /// 执行一个独立请求；取消和“哪次意图仍可写回 UI”由上层 ViewModel 保留。
    public func execute(_ request: FeedRequest) async throws -> FeedContent {
        switch request {
        case .recommendation(let continuation):
            guard continuation.map({ $0.freshIndex > 0 }) ?? true else {
                throw ContentApplicationError.invalidRequest
            }
            return .recommendation(
                try await repository.recommendations(after: continuation)
            )
        case .popular(let page, let pageSize):
            guard page > 0, (1...50).contains(pageSize) else {
                throw ContentApplicationError.invalidRequest
            }
            return .popular(
                try await repository.popular(page: page, pageSize: pageSize)
            )
        case .search(let request):
            let criteria = request.criteria
            guard criteria.isValid, request.page > 0 else {
                throw ContentApplicationError.invalidRequest
            }
            return .search(
                query: criteria.query,
                page: try await repository.searchVideos(request: request)
            )
        }
    }
}
