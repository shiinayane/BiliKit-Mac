import BiliModels

/// 读取 UP 主空间的一批投稿。
///
/// 只校验输入并转交 port；跨批的按 BVID 去重、到底与回环判断归调用方持有的 `PagedVideoList`。
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
}
