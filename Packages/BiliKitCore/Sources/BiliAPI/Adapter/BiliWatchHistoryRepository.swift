import BiliApplication
import BiliModels

public struct BiliWatchHistoryRepository: WatchHistoryRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage {
        do {
            return try await client.watchHistory(
                after: continuation,
                pageSize: pageSize
            )
        } catch {
            throw BiliAPIError.domainError(
                for: error,
                fallback: WatchHistoryError.transportFailure,
                Self.map
            )
        }
    }

    /// 历史读取请求不在 client 内把业务 -101 映射为认证失效，因此在这里视为需要重新登录。
    private static func map(_ failure: BiliAPIError.Failure) -> WatchHistoryError {
        switch failure {
        case .authorizationRequired, .authenticationInvalid,
            .authorizationUnavailable, .rejected(code: -101):
            .authenticationRequired
        case .restricted:
            .requestRestricted
        case .rejected(let code):
            .serviceRejected(code: code)
        case .transport, .unexpectedHTTPStatus:
            .transportFailure
        case .invalidRequest, .unsupportedMedia, .noPlayableMedia,
            .invalidResponse:
            .invalidResponse
        }
    }
}
