import BiliApplication
import BiliModels

/// 内容类 port（推荐、热门、搜索、视频详情与播放地址、相关推荐、热搜、搜索联想、UP 主名片与投稿）
/// 的 B 站实现。
///
/// 只转调 `BiliAPIClient` 的 endpoint 方法，授权方式由 endpoint 决定；错误统一经
/// `BiliAPIError.contentApplicationError(for:)` 映射。无状态，每个窗口一个，同一实例服务上述全部
/// port。
public struct BiliContentRepository: FeedRepository, VideoRepository,
    RelatedVideoRepository, TrendingSearchRepository, SearchSuggestionRepository,
    UploaderProfileRepository, UploaderVideoRepository
{
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func recommendations(
        after continuation: RecommendationContinuation?
    ) async throws -> RecommendationPage {
        try await mapError {
            try await client.recommendations(after: continuation)
        }
    }

    public func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        try await mapError {
            try await client.popular(page: page, pageSize: pageSize)
        }
    }

    public func searchVideos(request: VideoSearchRequest) async throws -> SearchPage {
        try await mapError {
            try await client.searchVideos(request: request)
        }
    }

    public func videoDetail(for bvid: String) async throws -> VideoDetail {
        try await mapError {
            try await client.videoDetail(for: bvid)
        }
    }

    public func relatedVideos(to bvid: String) async throws -> [RelatedVideo] {
        try await mapError {
            try await client.relatedVideos(to: bvid)
        }
    }

    public func trendingSearchKeywords(limit: Int) async throws -> [TrendingSearchKeyword] {
        try await mapError {
            try await client.trendingSearchKeywords(limit: limit)
        }
    }

    public func searchSuggestions(for term: String) async throws -> [String] {
        try await mapError {
            try await client.searchSuggestions(for: term)
        }
    }

    public func uploaderProfile(for ownerID: Int64) async throws -> UploaderProfile {
        try await mapError {
            try await client.uploaderProfile(for: ownerID)
        }
    }

    public func uploaderVideos(
        ownerID: Int64,
        order: UploaderVideoOrder,
        after cursor: UploaderVideoCursor?
    ) async throws -> UploaderVideoBatch {
        try await mapError {
            try await client.uploaderVideos(ownerID: ownerID, order: order, after: cursor)
        }
    }

    public func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        try await mapError {
            try await client.playback(for: bvid, cid: cid)
        }
    }

    private func mapError<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch {
            throw BiliAPIError.contentApplicationError(for: error)
        }
    }
}
