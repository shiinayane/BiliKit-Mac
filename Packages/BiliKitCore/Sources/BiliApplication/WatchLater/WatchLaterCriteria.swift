import Foundation

/// 稍后再看的排序：按加入时间从新到旧（默认）或从旧到新。
///
/// BiliAPI 把它映射为 `asc`。
public enum WatchLaterOrder: Sendable, Hashable, CaseIterable, Identifiable {
    case newestAdded
    case oldestAdded

    public var id: Self { self }
}

/// 稍后再看的观看进度筛选：全部（默认）或只看未看完的。
///
/// BiliAPI 把它映射为 `viewed`。
public enum WatchLaterProgressFilter: Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case unfinished

    public var id: Self { self }
}

/// 稍后再看的加入时间筛选选项；会话保存未解析的选项，由 `WatchLaterAddedTimeRangeResolver` 解析为区间后才进入 criteria。
public enum WatchLaterAddedTimeFilter: Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case today
    case yesterday
    case lastSevenDays
    case custom

    public var id: Self { self }
}

/// 已冻结的加入时间区间（Unix 秒，含开始、不含结束）。
///
/// 相对时间在每次开始新的分页会话（应用筛选、刷新、复核后重载）时由会话重新解析为该值，之后翻页沿用游标里的值。
public struct WatchLaterAddedTimeRange: Sendable, Hashable {
    public let startTimestamp: Int64
    public let endTimestamp: Int64

    public init(startTimestamp: Int64, endTimestamp: Int64) {
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
    }
}

/// 把加入时间选项按 `now` 与 `calendar`（含时区）解析为区间（含开始、不含结束）。
///
/// 今天是今天 0 点到明天 0 点；昨天是昨天 0 点到今天 0 点；近一周是现在往前 7 天到明天 0 点；自定义是开始日 0 点到
/// 结束日次日 0 点（含结束日当天）。“今天”与“近一周”的结束取明天 0 点而不是此刻：午夜那一刻区间不会为空，解析之后才
/// 加入的视频在刷新时也在区间内。与搜索的发布日期（`VideoPublicationRangeResolver`，整日闭区间、结束日不得晚于今天）
/// 语义不同，所以不共用解析；早于 1970 年与空区间的校验共用 `DateRangeFilterValidation`。无法给出区间时抛出
/// `DateRangeFilterError`。
public enum WatchLaterAddedTimeRangeResolver {
    public static func resolve(
        filter: WatchLaterAddedTimeFilter,
        customStart: Date,
        customEnd: Date,
        now: Date,
        calendar: Calendar
    ) throws -> WatchLaterAddedTimeRange? {
        let today = calendar.startOfDay(for: now)
        let start: Date
        let end: Date
        switch filter {
        case .all:
            return nil
        case .today:
            start = today
            end = try day(after: today, calendar: calendar)
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
                throw DateRangeFilterError.invalidCalendarRange
            }
            start = yesterday
            end = today
        case .lastSevenDays:
            start = now.addingTimeInterval(-7 * 24 * 60 * 60)
            end = try day(after: today, calendar: calendar)
        case .custom:
            let startDay = calendar.startOfDay(for: customStart)
            let endDay = calendar.startOfDay(for: customEnd)
            // `Date` 不用 `<=`／`>=`：Xcode 27.2 SDK 把它们编译成 macOS 27.2 才有的弱链接符号，
            // 见 ARCHITECTURE「平台与命名」。
            guard !(endDay < startDay) else {
                throw DateRangeFilterError.startAfterEnd
            }
            start = startDay
            end = try day(after: endDay, calendar: calendar)
        }
        let timestamps = try DateRangeFilterValidation.timestamps(start: start, endExclusive: end)
        return WatchLaterAddedTimeRange(
            startTimestamp: timestamps.start,
            endTimestamp: timestamps.endExclusive
        )
    }

    private static func day(after day: Date, calendar: Calendar) throws -> Date {
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else {
            throw DateRangeFilterError.invalidCalendarRange
        }
        return next
    }
}

/// 稍后再看一个列表的完整条件：排序、观看进度、加入时间、时长与关键词。
///
/// 关键词在初始化时按 `SearchText` 规范化，空串表示不按关键词过滤（由服务端匹配）。
public struct WatchLaterCriteria: Sendable, Hashable {
    public let order: WatchLaterOrder
    public let progress: WatchLaterProgressFilter
    public let addedTime: WatchLaterAddedTimeRange?
    public let duration: VideoDurationFilter
    public let keyword: String

    public init(
        order: WatchLaterOrder = .newestAdded,
        progress: WatchLaterProgressFilter = .all,
        addedTime: WatchLaterAddedTimeRange? = nil,
        duration: VideoDurationFilter = .all,
        keyword: String = ""
    ) {
        self.order = order
        self.progress = progress
        self.addedTime = addedTime
        self.duration = duration
        self.keyword = SearchText.normalized(keyword)
    }

    /// 关键词不超过 `SearchText` 的长度上限，加入时间区间不为负且开始早于结束。
    public var isValid: Bool {
        guard SearchText.isWithinLimit(keyword) else { return false }
        guard let addedTime else { return true }
        return addedTime.startTimestamp >= 0 && addedTime.startTimestamp < addedTime.endTimestamp
    }
}

/// 稍后再看的一次请求：完整条件加页码。
///
/// 也是分页游标，翻页只改变 `page`，旧条件的页因此不会并入新条件的列表。
public struct WatchLaterRequest: Sendable, Hashable {
    public let criteria: WatchLaterCriteria
    public let page: Int

    public init(criteria: WatchLaterCriteria = WatchLaterCriteria(), page: Int = 1) {
        self.criteria = criteria
        self.page = page
    }
}
