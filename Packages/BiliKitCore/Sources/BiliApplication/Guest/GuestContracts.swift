import BiliModels

public enum GuestApplicationError: Error, Sendable, Equatable {
    case invalidRequest
    case requestRestricted
    case serviceRejected(code: Int)
    case transportFailure
    case unsupportedMedia
    case invalidResponse
    case unavailable
}

/// 游客浏览用例所需的远端内容 port，不暴露 endpoint DTO 或具体网络 client。
public protocol GuestContentRepository: Sendable {
    func popular(page: Int, pageSize: Int) async throws -> PopularPage
    func searchVideos(keyword: String, page: Int) async throws -> SearchPage
    func videoDetail(for bvid: String) async throws -> VideoDetail
    func pages(for bvid: String) async throws -> [VideoPage]
    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback
}
