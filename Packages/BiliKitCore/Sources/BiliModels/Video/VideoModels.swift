import Foundation

public struct VideoOwner: Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let avatarURL: URL?
    public let signature: String?

    public init(
        id: Int64,
        name: String,
        avatarURL: URL? = nil,
        signature: String? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.signature = signature
    }
}

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

public struct VideoDetail: Identifiable, Sendable, Equatable {
    public var id: String { bvid }

    public let aid: Int64?
    public let bvid: String
    public let title: String
    public let summary: String
    public let coverURL: URL?
    public let owner: VideoOwner
    public let statistics: VideoStatistics
    public let durationSeconds: Int
    public let publishedAt: Date
    public let dimension: VideoDimension?
    /// 当前 BVID 自身的分 P；与所属合集同时存在，不表达合集 episode。
    public let pages: [VideoPage]
    public let collection: VideoCollection?

    public init(
        bvid: String,
        title: String,
        summary: String,
        coverURL: URL?,
        owner: VideoOwner,
        statistics: VideoStatistics,
        durationSeconds: Int,
        publishedAt: Date,
        dimension: VideoDimension? = nil,
        aid: Int64? = nil,
        pages: [VideoPage] = [],
        collection: VideoCollection? = nil
    ) {
        self.aid = aid
        self.bvid = bvid
        self.title = title
        self.summary = summary
        self.coverURL = coverURL
        self.owner = owner
        self.statistics = statistics
        self.durationSeconds = durationSeconds
        self.publishedAt = publishedAt
        self.dimension = dimension
        self.pages = pages
        self.collection = collection
    }
}

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

public struct VideoPage: Identifiable, Sendable, Equatable {
    public var id: Int64 { cid }

    public let cid: Int64
    public let index: Int
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

/// 仅表示 `/x/web-interface/view` 的 `ugc_season`；不表示 series、投稿列表或 PGC season。
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

public struct VideoCollectionEpisode: Identifiable, Sendable, Equatable {
    public let id: VideoCollectionEpisodeIdentity
    public let ordinal: Int
    public let aid: Int64?
    public let bvid: String?
    public let title: String
    public let coverURL: URL?
    public let durationSeconds: Int?
    public let defaultCID: Int64?
    /// `nil` 表示详情摘要没有给出分 P；空数组表示远端明确给出空列表。
    public let knownPages: [VideoPage]?
    /// 重复身份字段冲突或缺少标题时为 false；仍保留 occurrence 供 UI 解释不可用状态。
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

public struct VideoPlayback: Sendable, Equatable {
    public let manifest: PlaybackManifest
    public let mediaHeaders: [String: String]
    /// 已认证 playurl 返回的账户级断点；匿名响应与异常字段保持为 nil。
    public let resumeMetadata: PlaybackResumeMetadata?

    public init(
        manifest: PlaybackManifest,
        mediaHeaders: [String: String],
        resumeMetadata: PlaybackResumeMetadata? = nil
    ) {
        self.manifest = manifest
        self.mediaHeaders = mediaHeaders
        self.resumeMetadata = resumeMetadata
    }
}

/// 账户对同一 BVID 最近播放分 P 的服务器记录；位置单位固定为毫秒。
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
