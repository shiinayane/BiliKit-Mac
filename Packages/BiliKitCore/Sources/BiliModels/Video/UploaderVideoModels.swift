import Foundation

/// UP 主空间投稿列表的排序。
public enum UploaderVideoOrder: Sendable, Hashable {
    case newest
    case mostPlayed
    case mostFavorited
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

/// 投稿列表的一页。
///
/// 只保存服务端给出的事实（页码、每页条数与总数）；总页数与是否越界由共用的翻页状态 `PageReplacementPaging` 按
/// `PageNumbering` 推导，不在这里另算一份。
public struct UploaderVideoPage: Sendable, Equatable {
    public let videos: [UploaderVideo]
    public let pageNumber: Int
    public let pageSize: Int
    public let totalCount: Int

    public init(
        videos: [UploaderVideo],
        pageNumber: Int,
        pageSize: Int,
        totalCount: Int
    ) {
        self.videos = videos
        self.pageNumber = pageNumber
        self.pageSize = pageSize
        self.totalCount = max(0, totalCount)
    }
}
