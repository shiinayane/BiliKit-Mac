import BiliModels

/// 读取 UP 主空间的一批投稿，或在空间内搜索投稿。
///
/// 只校验输入并转交 port；关键词按 `SearchText` 规范化。跨批的按 BVID 去重、到底与回环判断归调用方持有的
/// `PagedVideoList`。
public struct UploaderVideoUseCase: Sendable {
    private let repository: any UploaderVideoRepository

    public init(repository: any UploaderVideoRepository) {
        self.repository = repository
    }

    public func batch(
        ownerID: Int64,
        order: UploaderVideoOrder,
        after cursor: UploaderVideoCursor?
    ) async throws -> UploaderVideoBatch {
        guard ownerID > 0 else {
            throw ContentApplicationError.invalidRequest
        }
        let batch = try await repository.uploaderVideos(
            ownerID: ownerID,
            order: order,
            after: cursor
        )
        try Task.checkCancellation()
        return batch
    }

    /// 关键词规范化后为空或超过长度上限时不发请求。
    public func search(
        ownerID: Int64,
        keyword: String,
        after cursor: UploaderVideoCursor?
    ) async throws -> UploaderVideoBatch {
        let keyword = SearchText.normalized(keyword)
        guard ownerID > 0, !keyword.isEmpty, SearchText.isWithinLimit(keyword) else {
            throw ContentApplicationError.invalidRequest
        }
        let batch = try await repository.searchUploaderVideos(
            ownerID: ownerID,
            keyword: keyword,
            after: cursor
        )
        try Task.checkCancellation()
        return batch
    }
}
