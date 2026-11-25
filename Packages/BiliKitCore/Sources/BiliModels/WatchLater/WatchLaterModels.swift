import Foundation

/// 稍后再看条目的观看进度。
public enum WatchLaterProgress: Sendable, Equatable {
    case notStarted
    /// 已看到的秒数：大于 0，时长已知时不超过时长。
    case watched(seconds: Int)
    /// 接口用 `progress == -1` 表示已看完。
    case finished
}

/// 稍后再看（`/x/v2/history/toview/web`）里的一条视频，由 BiliAPI 的 `WatchLaterItemPayload` 映射产生。
///
/// 没有可用 BVID 的分组占位行在映射时丢弃，不会成为条目。可以播放的条目标题、作者、时长与加入时间都齐全；
/// 只有不可用条目（`unavailability` 非 nil）可能缺这些字段，缺失时为 nil，由界面省略或给占位。
public struct WatchLaterItem: Identifiable, Sendable, Equatable {
    public var id: String { bvid }

    public let bvid: String
    public let title: String?
    public let coverURL: URL?
    public let owner: VideoOwner?
    public let durationSeconds: Int?
    public let progress: WatchLaterProgress
    /// 加入稍后再看的时间。
    public let addedAt: Date?
    /// nil 表示可以进入播放。
    public let unavailability: LibraryItemUnavailability?
    /// 列表给出的第一个分 P 的 CID，只作提前请求播放清单的提示（见 docs/ARCHITECTURE.md「播放页布局」）。
    public let firstPageCID: Int64?

    public init(
        bvid: String,
        title: String?,
        coverURL: URL?,
        owner: VideoOwner?,
        durationSeconds: Int?,
        progress: WatchLaterProgress,
        addedAt: Date?,
        unavailability: LibraryItemUnavailability? = nil,
        firstPageCID: Int64? = nil
    ) {
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
        self.owner = owner
        self.durationSeconds = durationSeconds
        self.progress = progress
        self.addedAt = addedAt
        self.unavailability = unavailability
        self.firstPageCID = firstPageCID
    }
}
