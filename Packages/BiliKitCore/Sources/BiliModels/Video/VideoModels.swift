import Foundation

/// 视频的 UP 主：MID、昵称，以及可选的头像。
///
/// 由热门、推荐、详情、搜索、观看历史、稍后再看与收藏夹的映射产生，也由空间与评论作者入口按 MID 构造；来自接口的
/// `avatarURL` 已经 `WebImageURL` 升级为 HTTPS 并过公开 HTTPS 基线（见 SECURITY-MODEL §4）。签名只来自
/// 名片（`UploaderProfile`）。
public struct VideoOwner: Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let avatarURL: URL?

    public init(
        id: Int64,
        name: String,
        avatarURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
    }
}

/// 从 UP 主名片补充的公开资料。
///
/// 播放页用签名、大会员状态、粉丝数与投稿数；只凭 MID 打开的空间用名字与头像。计数是名片读到时的数，名片缺失或形状
/// 不对时为 nil。不含当前账户是否关注：名片按 UP 主沿用、不随账户重读，关注状态归播放页的互动状态。
public struct UploaderProfile: Sendable, Equatable {
    public let name: String?
    public let avatarURL: URL?
    public let signature: String?
    public let isVIP: Bool
    public let followerCount: Int64?
    public let videoCount: Int64?

    public init(
        name: String? = nil,
        avatarURL: URL? = nil,
        signature: String? = nil,
        isVIP: Bool = false,
        followerCount: Int64? = nil,
        videoCount: Int64? = nil
    ) {
        self.name = name
        self.avatarURL = avatarURL
        self.signature = signature
        self.isVIP = isVIP
        self.followerCount = followerCount
        self.videoCount = videoCount
    }
}

/// 视频的播放、弹幕与点赞计数；搜索结果没有点赞数时为 0。
public struct VideoStatistics: Sendable, Equatable {
    public let viewCount: Int64
    public let danmakuCount: Int64
    public let likeCount: Int64

    public init(viewCount: Int64, danmakuCount: Int64, likeCount: Int64) {
        self.viewCount = viewCount
        self.danmakuCount = danmakuCount
        self.likeCount = likeCount
    }
}

/// 热门列表（`/x/web-interface/popular`）里的一条视频，由 BiliAPI 的 `PopularVideoPayload`
/// 映射产生。
///
/// 映射时要求 `BV` 开头的 BVID、非空标题与非负时长；标题已解码 HTML 实体，封面已过公开 HTTPS 基线。
public struct PopularVideo: Identifiable, Sendable, Equatable {
    public var id: String { bvid }

    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let owner: VideoOwner
    public let statistics: VideoStatistics
    public let durationSeconds: Int
    public let publishedAt: Date

    public init(
        bvid: String,
        title: String,
        coverURL: URL?,
        owner: VideoOwner,
        statistics: VideoStatistics,
        durationSeconds: Int,
        publishedAt: Date
    ) {
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
        self.owner = owner
        self.statistics = statistics
        self.durationSeconds = durationSeconds
        self.publishedAt = publishedAt
    }
}

/// 热门列表的一页；`pageNumber` 与 `pageSize` 回填请求值，供浏览页确认响应属于当前请求，`hasMore`
/// 来自 `no_more`。
public struct PopularPage: Sendable, Equatable {
    public let videos: [PopularVideo]
    public let pageNumber: Int
    public let pageSize: Int
    public let hasMore: Bool

    public init(
        videos: [PopularVideo],
        pageNumber: Int,
        pageSize: Int,
        hasMore: Bool = false
    ) {
        self.videos = videos
        self.pageNumber = pageNumber
        self.pageSize = pageSize
        self.hasMore = hasMore
    }
}

/// 首页推荐的续传游标：App 端推荐接口的 `idx`，取上一批最后一条的值，下一批从它之后继续。
public struct RecommendationContinuation: Sendable, Equatable {
    public let index: Int64

    public init(index: Int64) {
        self.index = index
    }
}

/// 首页推荐（App 端 `/x/v2/feed/index`）里的一条视频，由 BiliAPI 的 `AppFeedItemPayload` 映射产生。
///
/// 只保留普通视频且不带商业推广。App 卡片只给展示用的文字，所以播放数、弹幕数是从「25.4万观看」这类文字解析回的
/// 近似值，发布时间是从卡片描述里的日期解析回的时刻；解析不出时为 nil，卡片不显示这一项。`recommendationReason`
/// 去掉首尾空白后为空时是 nil。
public struct RecommendedVideo: Identifiable, Sendable, Equatable {
    public var id: String { bvid }

    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let owner: VideoOwner
    public let viewCount: Int64?
    public let danmakuCount: Int64?
    public let durationSeconds: Int
    public let publishedAt: Date?
    public let recommendationReason: String?
    /// 卡片给出的「不感兴趣」原因，按卡片顺序；为空时这一条不提供反馈。
    public let dislikeReasons: [RecommendationDislikeReason]

    public init(
        bvid: String,
        title: String,
        coverURL: URL?,
        owner: VideoOwner,
        viewCount: Int64?,
        danmakuCount: Int64?,
        durationSeconds: Int,
        publishedAt: Date?,
        recommendationReason: String?,
        dislikeReasons: [RecommendationDislikeReason] = []
    ) {
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
        self.owner = owner
        self.viewCount = viewCount
        self.danmakuCount = danmakuCount
        self.durationSeconds = durationSeconds
        self.publishedAt = publishedAt
        self.recommendationReason = recommendationReason
        self.dislikeReasons = dislikeReasons
    }
}

/// 首页推荐卡片给出的一个「不感兴趣」原因：反馈接口的 `reason_id` 与卡片上的名字（如「UP主:某某」「此类内容过多」）。
///
/// 名字是服务端给的中文，原样显示、不本地化；id 与名字都由卡片给出，客户端不认识也不假设具体取值。id 不是正数或名字
/// 为空时为 nil。
public struct RecommendationDislikeReason: Sendable, Hashable {
    public let id: Int64
    public let name: String

    public init?(id: Int64, name: String) {
        guard id > 0, !name.isEmpty else { return nil }
        self.id = id
        self.name = name
    }
}

/// 首页推荐的一批：`continuation` 回填请求所用的游标（第一批为 nil），本批没有条目时 `nextContinuation` 为 nil，
/// 不再加载更多。
public struct RecommendationPage: Sendable, Equatable {
    public let videos: [RecommendedVideo]
    public let continuation: RecommendationContinuation?
    public let nextContinuation: RecommendationContinuation?

    public init(
        videos: [RecommendedVideo],
        continuation: RecommendationContinuation?,
        nextContinuation: RecommendationContinuation?
    ) {
        self.videos = videos
        self.continuation = continuation
        self.nextContinuation = nextContinuation
    }
}

/// 播放页相关推荐（`/x/web-interface/archive/related`）里的一条视频，由 BiliAPI 的
/// `RelatedVideoPayload` 映射产生。
///
/// 映射时要求 12 位 `BV` 开头的 BVID、非空标题与 UP 主名、非负计数；时长缺失时为 nil。
public struct RelatedVideo: Identifiable, Sendable, Equatable {
    public var id: String { bvid }

    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let ownerName: String
    public let viewCount: Int64
    public let danmakuCount: Int64
    public let durationSeconds: Int?

    public init(
        bvid: String,
        title: String,
        coverURL: URL?,
        ownerName: String,
        viewCount: Int64,
        danmakuCount: Int64,
        durationSeconds: Int?
    ) {
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
        self.ownerName = ownerName
        self.viewCount = viewCount
        self.danmakuCount = danmakuCount
        self.durationSeconds = durationSeconds
    }
}

/// 视频详情（`/x/web-interface/wbi/view`），由 BiliAPI 的 `VideoDetailPayload` 映射产生，
/// 播放页消费。
///
/// 映射时拒绝非正 `aid`、非 `BV` 开头的 BVID、空标题与负时长；分 P 的 CID 与序号必须各自唯一，
/// 并按序号排序。
public struct VideoDetail: Identifiable, Sendable, Equatable {
    public var id: String { bvid }

    public let aid: Int64?
    public let bvid: String
    public let title: String
    public let summary: String
    /// 简介里的链接：@ 用户、网址、短链、BV/av 号与时间戳，与评论正文共用同一套目标。
    public let summaryLinks: [CommentLink]
    public let coverURL: URL?
    public let owner: VideoOwner
    public let statistics: VideoStatistics
    public let durationSeconds: Int
    public let publishedAt: Date
    public let dimension: VideoDimension?
    /// 当前 BVID 自身的分 P；与所属合集同时存在，不表达合集 episode。
    public let pages: [VideoPage]
    public let collection: VideoCollection?
    public let access: VideoAccess
    /// 播放页点赞、投币、收藏按钮旁的计数与投币上限需要的事实；接口没给时计数为 nil。
    public let engagementSummary: VideoEngagementSummary

    public init(
        bvid: String,
        title: String,
        summary: String,
        summaryLinks: [CommentLink] = [],
        coverURL: URL?,
        owner: VideoOwner,
        statistics: VideoStatistics,
        durationSeconds: Int,
        publishedAt: Date,
        dimension: VideoDimension? = nil,
        aid: Int64? = nil,
        pages: [VideoPage] = [],
        collection: VideoCollection? = nil,
        access: VideoAccess = VideoAccess(),
        engagementSummary: VideoEngagementSummary = VideoEngagementSummary()
    ) {
        self.aid = aid
        self.bvid = bvid
        self.title = title
        self.summary = summary
        self.summaryLinks = summaryLinks
        self.coverURL = coverURL
        self.owner = owner
        self.statistics = statistics
        self.durationSeconds = durationSeconds
        self.publishedAt = publishedAt
        self.dimension = dimension
        self.pages = pages
        self.collection = collection
        self.access = access
        self.engagementSummary = engagementSummary
    }
}

/// 视频详情里与点赞、投币、收藏有关的部分：投币数与收藏数（点赞数在 `VideoStatistics`），以及是否为转载。
public struct VideoEngagementSummary: Sendable, Equatable {
    public let coinCount: Int64?
    public let favoriteCount: Int64?
    /// 转载稿件（接口 `copyright` 为 2）最多投 1 枚币；1（自制）与 3（未填写）按自制处理。
    public let isReposted: Bool

    public init(coinCount: Int64? = nil, favoriteCount: Int64? = nil, isReposted: Bool = false) {
        self.coinCount = coinCount
        self.favoriteCount = favoriteCount
        self.isReposted = isReposted
    }
}

/// `nil` 表示 endpoint 未提供该事实；不能把未知折叠成明确 false。
public struct VideoAccess: Sendable, Equatable {
    public let isUPowerExclusive: Bool?
    public let isUPowerPreviewAvailable: Bool?
    public let isUPowerPlayable: Bool?

    public init(
        isUPowerExclusive: Bool? = nil,
        isUPowerPreviewAvailable: Bool? = nil,
        isUPowerPlayable: Bool? = nil
    ) {
        self.isUPowerExclusive = isUPowerExclusive
        self.isUPowerPreviewAvailable = isUPowerPreviewAvailable
        self.isUPowerPlayable = isUPowerPlayable
    }
}

/// 视频的原始宽高与旋转（接口 `dimension.rotate`），来自详情与分 P。
public struct VideoDimension: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rotation: Int

    public init(width: Int, height: Int, rotation: Int) {
        self.width = width
        self.height = height
        self.rotation = rotation
    }
}

/// 当前 BVID 的一个分 P：`cid` 是它的身份，`index` 是从 1 开始的分 P 序号。
///
/// 映射时拒绝非正 CID 与序号、负时长。
public struct VideoPage: Identifiable, Sendable, Equatable {
    public var id: Int64 { cid }

    public let cid: Int64
    public let index: Int
    /// 分 P 标题；较早的单 P 视频可能为空字符串。
    public let title: String
    public let durationSeconds: Int
    public let dimension: VideoDimension?

    public init(
        cid: Int64,
        index: Int,
        title: String,
        durationSeconds: Int,
        dimension: VideoDimension? = nil
    ) {
        self.cid = cid
        self.index = index
        self.title = title
        self.durationSeconds = durationSeconds
        self.dimension = dimension
    }
}

/// 仅表示视频详情（`/x/web-interface/wbi/view`）的 `ugc_season`；不表示 series、投稿列表或 PGC season。
public struct VideoCollection: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let title: String
    public let reportedEpisodeCount: Int?
    public let sections: [VideoCollectionSection]

    public var embeddedEpisodeCount: Int {
        sections.reduce(into: 0) { $0 += $1.episodes.count }
    }

    /// 只表达计数是否相等；非公开接口没有承诺相等即代表 section 树完整。
    public var embeddedCountMatchesReportedCount: Bool? {
        guard let reportedEpisodeCount else { return nil }
        return reportedEpisodeCount == embeddedEpisodeCount
    }

    public init(
        id: Int64,
        title: String,
        reportedEpisodeCount: Int?,
        sections: [VideoCollectionSection]
    ) {
        self.id = id
        self.title = title
        self.reportedEpisodeCount = reportedEpisodeCount
        self.sections = sections
    }
}

/// 合集 section 的身份：合集 ID 与 section ID，远端 section ID 重复时再加出现序号。
public struct VideoCollectionSectionIdentity: Sendable, Hashable {
    public let seasonID: Int64
    public let sectionID: Int64
    /// 仅在远端 section ID 重复时区分同一响应中的 occurrence。
    public let occurrenceOrdinal: Int?

    public init(
        seasonID: Int64,
        sectionID: Int64,
        occurrenceOrdinal: Int? = nil
    ) {
        self.seasonID = seasonID
        self.sectionID = sectionID
        self.occurrenceOrdinal = occurrenceOrdinal
    }
}

/// 合集里的一个 section 及其 episode，`ordinal` 是它在响应里的位置。
///
/// `isIdentityConsistent` 在 section ID 缺失或非正、两个 ID 字段冲突或所属合集不符时为 false，其下
/// episode 一并视为不一致。
public struct VideoCollectionSection: Identifiable, Sendable, Equatable {
    public let id: VideoCollectionSectionIdentity
    public let ordinal: Int
    public let title: String
    public let episodes: [VideoCollectionEpisode]
    public let isIdentityConsistent: Bool

    public init(
        id: VideoCollectionSectionIdentity,
        ordinal: Int,
        title: String,
        episodes: [VideoCollectionEpisode],
        isIdentityConsistent: Bool = true
    ) {
        self.id = id
        self.ordinal = ordinal
        self.title = title
        self.episodes = episodes
        self.isIdentityConsistent = isIdentityConsistent
    }
}

/// 合集 episode 的身份：合集、section（含其出现序号）与 episode ID，ID 缺失或重复时再加出现序号。
public struct VideoCollectionEpisodeIdentity: Sendable, Hashable {
    public let seasonID: Int64
    public let sectionID: Int64
    /// 父 section ID 重复时继承其 occurrence，避免跨 section 的 episode identity 碰撞。
    public let sectionOccurrenceOrdinal: Int?
    public let episodeID: Int64?
    /// 远端 ID 缺失或重复时才用于区分当前响应中的 occurrence。
    public let occurrenceOrdinal: Int?

    public init(
        seasonID: Int64,
        sectionID: Int64,
        sectionOccurrenceOrdinal: Int? = nil,
        episodeID: Int64?,
        occurrenceOrdinal: Int? = nil
    ) {
        self.seasonID = seasonID
        self.sectionID = sectionID
        self.sectionOccurrenceOrdinal = sectionOccurrenceOrdinal
        self.episodeID = episodeID
        self.occurrenceOrdinal = occurrenceOrdinal
    }
}

/// 合集里的一集，由 BiliAPI 的 `UGCSeasonEpisodePayload` 映射产生；身份不一致的 episode 也保留，
/// 只标记出来。
public struct VideoCollectionEpisode: Identifiable, Sendable, Equatable {
    public let id: VideoCollectionEpisodeIdentity
    public let ordinal: Int
    public let aid: Int64?
    public let bvid: String?
    public let title: String
    public let coverURL: URL?
    public let durationSeconds: Int?
    /// 默认播放的 CID；与分 P 数据冲突时为 nil。
    public let defaultCID: Int64?
    /// `nil` 表示详情摘要没有给出分 P；空数组表示远端明确给出空列表。
    public let knownPages: [VideoPage]?
    /// 所属 section 不一致、身份字段互相冲突或越界、分 P 数据不合法或缺少标题时为 false；仍保留
    /// occurrence 供 UI 解释不可用状态。
    public let isIdentityConsistent: Bool

    public init(
        id: VideoCollectionEpisodeIdentity,
        ordinal: Int,
        aid: Int64?,
        bvid: String?,
        title: String,
        coverURL: URL?,
        durationSeconds: Int?,
        defaultCID: Int64?,
        knownPages: [VideoPage]?,
        isIdentityConsistent: Bool = true
    ) {
        self.id = id
        self.ordinal = ordinal
        self.aid = aid
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
        self.durationSeconds = durationSeconds
        self.defaultCID = defaultCID
        self.knownPages = knownPages
        self.isIdentityConsistent = isIdentityConsistent
    }
}

/// 一次 playurl 的结果：DASH 或单文件媒体、请求媒体时附带的 header 与可选的账户断点。
///
/// 由 `BiliAPIClient` 映射产生，播放引擎消费；`mediaHeaders` 只有 Referer 与 User-Agent，不含凭据，
/// Range 请求构造时还会去掉 `Cookie`／`Authorization`（见 SECURITY-MODEL §4）。
public struct VideoPlayback: Sendable, Equatable {
    public let media: PlaybackMedia
    public let mediaHeaders: [String: String]
    /// 已认证 playurl 返回的账户级断点；匿名响应与异常字段保持为 nil。
    public let resumeMetadata: PlaybackResumeMetadata?

    public init(
        media: PlaybackMedia,
        mediaHeaders: [String: String],
        resumeMetadata: PlaybackResumeMetadata? = nil
    ) {
        self.media = media
        self.mediaHeaders = mediaHeaders
        self.resumeMetadata = resumeMetadata
    }
}

/// 账户对同一 BVID 最近播放分 P 的服务器记录；位置单位固定为毫秒。
///
/// 构造时拒绝非正 CID 与负位置；BiliAPI 只在已认证的 playurl 响应里给出它。
public struct PlaybackResumeMetadata: Sendable, Equatable {
    public let lastPlayedCID: Int64
    public let positionMilliseconds: Int64

    public init?(
        lastPlayedCID: Int64,
        positionMilliseconds: Int64
    ) {
        guard lastPlayedCID > 0, positionMilliseconds >= 0 else { return nil }
        self.lastPlayedCID = lastPlayedCID
        self.positionMilliseconds = positionMilliseconds
    }
}

/// 视频搜索（`/x/web-interface/wbi/search/type`）里的一条结果，由 BiliAPI 的 `SearchVideoPayload`
/// 映射产生。
///
/// 只保留 `BV` 开头、其余只含 ASCII 字母数字的 BVID；标题去掉高亮标签并解码 HTML 实体，
/// 时长文本无法解析时为 nil。
public struct SearchVideo: Identifiable, Sendable, Equatable {
    public var id: String { bvid }

    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let owner: VideoOwner
    public let statistics: VideoStatistics
    public let durationSeconds: Int?
    public let publishedAt: Date

    public init(
        bvid: String,
        title: String,
        coverURL: URL?,
        owner: VideoOwner,
        statistics: VideoStatistics,
        durationSeconds: Int?,
        publishedAt: Date
    ) {
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
        self.owner = owner
        self.statistics = statistics
        self.durationSeconds = durationSeconds
        self.publishedAt = publishedAt
    }
}

/// 视频搜索的一页；页码、页大小与总数都来自接口，映射时拒绝非正页码与页大小、负总数。
public struct SearchPage: Sendable, Equatable {
    public let videos: [SearchVideo]
    public let pageNumber: Int
    public let pageSize: Int
    public let totalResults: Int
    public let totalPages: Int

    public init(
        videos: [SearchVideo],
        pageNumber: Int,
        pageSize: Int,
        totalResults: Int,
        totalPages: Int
    ) {
        self.videos = videos
        self.pageNumber = pageNumber
        self.pageSize = pageSize
        self.totalResults = totalResults
        self.totalPages = totalPages
    }
}
