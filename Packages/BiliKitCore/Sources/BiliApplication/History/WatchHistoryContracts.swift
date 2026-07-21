import BiliModels

public enum WatchHistoryError: Error, Sendable, Equatable {
    case authenticationRequired
    case requestRestricted
    case serviceRejected(code: Int)
    case transportFailure
    case invalidResponse
}

/// API adapter 生成并消费的不透明分页令牌。Presentation 与 Use Case 只能保存和回传，
/// 不知道远端 cursor 的字段或编码。
public struct WatchHistoryContinuation: Sendable, Equatable {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct WatchHistoryPage: Sendable, Equatable {
    public let items: [WatchHistoryItem]
    public let continuation: WatchHistoryContinuation?

    public init(
        items: [WatchHistoryItem],
        continuation: WatchHistoryContinuation?
    ) {
        self.items = items
        self.continuation = continuation
    }
}

public protocol WatchHistoryRepository: Sendable {
    func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage
}
