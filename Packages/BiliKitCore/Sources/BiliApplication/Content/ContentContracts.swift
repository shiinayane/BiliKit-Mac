import BiliModels

/// 内容类读取（Feed、视频、UP 主空间、观看历史、稍后再看、收藏夹）共用的应用级错误。
///
/// 认证相关分四态：本地无凭据（`authenticationRequired`）、凭据失效（`authenticationInvalid`，
/// 唯一触发账户复核的一种）、本地凭据读不到（`authenticationUnavailable`，如 Keychain 不可用），
/// 以及风控（`requestRestricted`）。
///
/// 由 BiliAPI 的 adapter 经 `BiliAPIError.contentApplicationError(for:)` 映射；
/// `fullViewingEntitlementRequired` 只由 `VideoUseCase` 收窄得出。是否复核账户、是否给重试只读
/// `requiresAccountRevalidation` 与 `isRetryable`，Feature 不各自判断，见
/// docs/ARCHITECTURE.md「模块与依赖方向」。
public enum ContentApplicationError: Error, Sendable, Equatable {
    case invalidRequest
    /// 本地没有登录凭据，而该内容只按账户读取。与凭据失效不同，不应触发账户复核。
    case authenticationRequired
    case authenticationInvalid
    case authenticationUnavailable
    case requestRestricted
    /// 内容不存在、已删除或对当前身份不可见；重试不会改变结果。
    case contentUnavailable
    case serviceRejected(code: Int)
    case transportFailure
    /// 播放清单里没有本应用能播放的编码（AVC／HEVC 视频或 AAC 音频）；重试不会改变结果。
    case unsupportedMedia
    /// 播放地址响应没有给出可播放的媒体；可以重试。
    case playbackUnavailable
    /// 充电专属稿件没有完整观看权益，也没有试看片段。
    case fullViewingEntitlementRequired
    case invalidResponse
    case unavailable
}

extension ContentApplicationError {
    /// 只有凭据失效需要窗口复核账户会话；无凭据、本地凭据读不到与风控都不复核。
    public var requiresAccountRevalidation: Bool {
        self == .authenticationInvalid
    }

    /// 用户重试可能得到不同结果才提供重试。
    ///
    /// 需要登录、内容不存在或不可见、客户端无法发出的请求、没有可用轨道与没有完整观看权益时，
    /// 重试只会得到同样的结果。
    public var isRetryable: Bool {
        switch self {
        case .authenticationRequired, .contentUnavailable, .invalidRequest, .unsupportedMedia,
            .fullViewingEntitlementRequired:
            false
        case .authenticationInvalid, .authenticationUnavailable, .requestRestricted,
            .serviceRejected, .transportFailure, .playbackUnavailable, .invalidResponse,
            .unavailable:
            true
        }
    }
}

/// 推荐、热门与搜索列表的 port：有凭据时按账户读取，本地无凭据时匿名请求同一 endpoint；不暴露
/// endpoint DTO 或具体网络 client。
///
/// 本文件的内容类 port 都由 BiliAPI 的 `BiliContentRepository` 实现，只经对应 Use Case 调用；
/// 失败抛出 `ContentApplicationError`，取消原样传播为 `CancellationError`。
public protocol FeedRepository: Sendable {
    func recommendations(
        after continuation: RecommendationContinuation?
    ) async throws -> RecommendationPage
    func popular(page: Int, pageSize: Int) async throws -> PopularPage
    func searchVideos(request: VideoSearchRequest) async throws -> SearchPage
}

/// 视频详情、分 P 与播放地址的 port：有凭据时按账户读取；本地无凭据时详情匿名请求同一 endpoint，
/// 播放地址改用带游客参数的匿名请求，见 SECURITY-MODEL §3。
public protocol VideoRepository: Sendable {
    func videoDetail(for bvid: String) async throws -> VideoDetail
    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback
}

/// 当前视频相关推荐的只读 port：有凭据时按账户读取，本地无凭据时匿名请求同一 endpoint。
public protocol RelatedVideoRepository: Sendable {
    func relatedVideos(to bvid: String) async throws -> [RelatedVideo]
}

/// 搜索页 B 站热搜所需的独立匿名只读 port；结果不因登录账号而变化。
public protocol TrendingSearchRepository: Sendable {
    func trendingSearchKeywords(limit: Int) async throws -> [TrendingSearchKeyword]
}

/// 搜索框联想所需的独立匿名只读 port；输入尚未提交，结果不因登录账号而变化。
public protocol SearchSuggestionRepository: Sendable {
    func searchSuggestions(for term: String) async throws -> [String]
}

/// UP 主空间投稿列表的只读 port：未登录也可读取，登录时由实现带上账户凭据。
///
/// 按游标翻页：`cursor` 为 nil 时读第一批，之后传上一批给出的 `nextCursor`。
public protocol UploaderVideoRepository: Sendable {
    func uploaderVideos(
        ownerID: Int64,
        order: UploaderVideoOrder,
        after cursor: UploaderVideoCursor?
    ) async throws -> UploaderVideoBatch
}

/// 播放页只读 UP 主名片（签名与大会员状态）所需的独立 port；具体账户读取策略由 adapter 隐藏。
public protocol UploaderProfileRepository: Sendable {
    func uploaderProfile(for ownerID: Int64) async throws -> UploaderProfile
}
