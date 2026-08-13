import BiliModels

public enum GuestApplicationError: Error, Sendable, Equatable {
    case invalidRequest
    case authenticationInvalid
    case authenticationUnavailable
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

/// 当前视频相关推荐所需的独立匿名只读 port。
public protocol RelatedVideoRepository: Sendable {
    func relatedVideos(to bvid: String) async throws -> [RelatedVideo]
}

/// 播放页只读 UP 主签名所需的独立 port；具体账户读取策略由 adapter 隐藏。
public protocol UploaderSignatureRepository: Sendable {
    func signature(for ownerID: Int64) async throws -> String?
}
