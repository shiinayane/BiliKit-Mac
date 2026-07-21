import BiliModels
import Foundation

public struct VideoOwner: Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let avatarURL: URL?

    public init(id: Int64, name: String, avatarURL: URL? = nil) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
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

    public init(videos: [PopularVideo], pageNumber: Int, pageSize: Int) {
        self.videos = videos
        self.pageNumber = pageNumber
        self.pageSize = pageSize
    }
}

public struct VideoDetail: Identifiable, Sendable, Equatable {
    public var id: String { bvid }

    public let bvid: String
    public let title: String
    public let summary: String
    public let coverURL: URL?
    public let owner: VideoOwner
    public let statistics: VideoStatistics
    public let durationSeconds: Int
    public let publishedAt: Date
    public let dimension: VideoDimension?

    public init(
        bvid: String,
        title: String,
        summary: String,
        coverURL: URL?,
        owner: VideoOwner,
        statistics: VideoStatistics,
        durationSeconds: Int,
        publishedAt: Date,
        dimension: VideoDimension? = nil
    ) {
        self.bvid = bvid
        self.title = title
        self.summary = summary
        self.coverURL = coverURL
        self.owner = owner
        self.statistics = statistics
        self.durationSeconds = durationSeconds
        self.publishedAt = publishedAt
        self.dimension = dimension
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

public struct VideoPlayback: Sendable, Equatable {
    public let manifest: PlaybackManifest
    public let mediaHeaders: [String: String]

    public init(
        manifest: PlaybackManifest,
        mediaHeaders: [String: String]
    ) {
        self.manifest = manifest
        self.mediaHeaders = mediaHeaders
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
