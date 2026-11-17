import BiliModels

/// 读取某个分 P 的分段章节。
///
/// 由播放页的 `VideoChapterModel` 调用，Task 与取消归它；空 BV 或无效 CID 按无效请求拒绝，不发请求。
public struct VideoChapterUseCase: Sendable {
    private let repository: any VideoChapterRepository

    public init(repository: any VideoChapterRepository) {
        self.repository = repository
    }

    public func chapters(for identity: PlaybackItemIdentity) async throws -> [VideoChapter] {
        guard !identity.bvid.isEmpty, identity.cid > 0 else {
            throw ContentApplicationError.invalidRequest
        }
        let chapters = try await repository.chapters(for: identity)
        try Task.checkCancellation()
        return chapters
    }
}
