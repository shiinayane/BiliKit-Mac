import Foundation

/// UP 主空间投稿列表的排序：App 端投稿接口只提供这两种。
public enum UploaderVideoOrder: Sendable, Equatable {
    case newest
    case mostPlayed
}

/// UP 主空间投稿列表中的一条视频。
public struct UploaderVideo: Identifiable, Sendable, Equatable {
    public var id: String { bvid }

    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let durationSeconds: Int?
    public let viewCount: Int64?
    public let danmakuCount: Int64?
    public let publishedAt: Date
    /// 联合投稿：出现在该 UP 主空间，但视频的 UP 主字段可能是另一位。
    public let isCollaboration: Bool

    public init(
        bvid: String,
        title: String,
        coverURL: URL?,
        durationSeconds: Int?,
        viewCount: Int64?,
        danmakuCount: Int64?,
        publishedAt: Date,
        isCollaboration: Bool
    ) {
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
        self.durationSeconds = durationSeconds
        self.viewCount = viewCount
        self.danmakuCount = danmakuCount
        self.publishedAt = publishedAt
        self.isCollaboration = isCollaboration
    }
}

/// 空间投稿的翻页游标：服务端给出的不透明值，只用来请求紧接着的下一批。
public struct UploaderVideoCursor: Hashable, Sendable {
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

/// 投稿列表的一批：本批视频、下一批的游标（nil 表示已到底）与服务端给出的投稿总数。
public struct UploaderVideoBatch: Sendable, Equatable {
    public let videos: [UploaderVideo]
    public let nextCursor: UploaderVideoCursor?
    public let totalCount: Int

    public init(videos: [UploaderVideo], nextCursor: UploaderVideoCursor?, totalCount: Int) {
        self.videos = videos
        self.nextCursor = nextCursor
        self.totalCount = max(0, totalCount)
    }
}
