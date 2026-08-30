import BiliModels

/// 把远端分页适配为可显示的历史页，并有界跳过映射后为空的页面。
///
/// 空页 continuation 必须前进；达到跳过上限时返回令牌供用户显式继续，避免后台无界扫描。
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
        guard (1...30).contains(pageSize) else {
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
            if let nextContinuation = page.continuation,
                nextContinuation == requestContinuation
            {
                throw WatchHistoryError.invalidResponse
            }
            guard page.items.isEmpty,
                let nextContinuation = page.continuation
            else {
                return page
            }
            guard skippedEmptyPages < maximumEmptyPagesToSkip else {
                return page
            }
            skippedEmptyPages += 1
            requestContinuation = nextContinuation
        }
    }
}
