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

public protocol GuestContentRepository: Sendable {
    func popular(page: Int, pageSize: Int) async throws -> PopularPage
    func searchVideos(keyword: String, page: Int) async throws -> SearchPage
    func videoDetail(for bvid: String) async throws -> VideoDetail
    func pages(for bvid: String) async throws -> [VideoPage]
    func playback(for bvid: String, cid: Int64, quality: Int) async throws -> VideoPlayback
}

@MainActor
public protocol PlaybackControlling: AnyObject {
    func load(_ playback: VideoPlayback) async throws
    func pause()
}
