import Foundation

public struct WatchHistoryItem: Identifiable, Sendable, Equatable {
    public var id: String { bvid }

    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let owner: VideoOwner
    public let progressSeconds: Int
    public let durationSeconds: Int
    public let viewedAt: Date

    public init(
        bvid: String,
        title: String,
        coverURL: URL?,
        owner: VideoOwner,
        progressSeconds: Int,
        durationSeconds: Int,
        viewedAt: Date
    ) {
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
        self.owner = owner
        self.progressSeconds = progressSeconds
        self.durationSeconds = durationSeconds
        self.viewedAt = viewedAt
    }
}
