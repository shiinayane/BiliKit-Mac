import Foundation

/// 搜索结果的排序方式；BiliAPI 把它映射为接口的 `order` 参数，rawValue 不进入请求。
public enum VideoSearchOrder: String, Sendable, Hashable, CaseIterable, Identifiable {
    case relevance
    case mostPlayed
    case newest
    case mostDanmaku
    case mostFavorited

    public var id: Self { self }
}

/// 视频时长的四档筛选，搜索与稍后再看共用；每档的秒数边界只在 `secondsRange`。
///
/// 搜索把 rawValue 原样作为接口的 `duration` 参数（1–4 正是这四档），稍后再看把 `secondsRange` 映射为
/// `arc_min_duration`／`arc_max_duration`；改动 rawValue 或边界会改变请求含义。
public enum VideoDurationFilter: Int, Sendable, Hashable, CaseIterable, Identifiable {
    case all = 0
    case underTenMinutes = 1
    case tenToThirtyMinutes = 2
    case thirtyToSixtyMinutes = 3
    case overSixtyMinutes = 4

    public var id: Self { self }

    /// 这一档的时长下限与上限（秒）；nil 表示该侧不限，`all` 两侧都不限。
    package var secondsRange: (minimum: Int?, maximum: Int?) {
        switch self {
        case .all: (nil, nil)
        case .underTenMinutes: (nil, 600)
        case .tenToThirtyMinutes: (600, 1_800)
        case .thirtyToSixtyMinutes: (1_800, 3_600)
        case .overSixtyMinutes: (3_600, nil)
        }
    }
}

/// 已冻结的闭区间；相对日期在进入搜索 criteria 前解析为该值，避免跨午夜改变请求含义。
public struct VideoPublicationTimeRange: Sendable, Hashable {
    public let beginTimestamp: Int64
    public let endTimestamp: Int64

    public init(beginTimestamp: Int64, endTimestamp: Int64) {
        self.beginTimestamp = beginTimestamp
        self.endTimestamp = endTimestamp
    }
}

/// 搜索页的发布时间筛选选项；由 `VideoPublicationRangeResolver` 解析为冻结的闭区间后才进入
/// criteria。
public enum VideoPublicationFilter: Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case today
    case lastSevenDays
    case last180Days
    case custom

    public var id: Self { self }
}

/// 将日期选择集中转换为 API 使用的整日 Unix 秒闭区间。
///
/// 无法给出区间时抛出 `DateRangeFilterError`；早于 1970 年与空区间的规则与稍后再看共用 `DateRangeFilterValidation`。
public enum VideoPublicationRangeResolver {
    public static func resolve(
        filter: VideoPublicationFilter,
        customStart: Date,
        customEnd: Date,
        now: Date,
        calendar: Calendar
    ) throws -> VideoPublicationTimeRange? {
        guard filter != .all else { return nil }

        let today = calendar.startOfDay(for: now)
        let endDay = filter == .custom ? calendar.startOfDay(for: customEnd) : today
        // `Date` 不用 `<=`／`>=`：Xcode 27.2 SDK 把它们编译成 macOS 27.2 才有的弱链接符号，
        // 见 ARCHITECTURE「平台与命名」。
        guard !(today < endDay) else {
            throw DateRangeFilterError.futureDate
        }

        let beginDay: Date
        switch filter {
        case .all:
            return nil
        case .today:
            beginDay = today
        case .lastSevenDays:
            guard let value = calendar.date(byAdding: .day, value: -6, to: today) else {
                throw DateRangeFilterError.invalidCalendarRange
            }
            beginDay = value
        case .last180Days:
            guard let value = calendar.date(byAdding: .day, value: -179, to: today) else {
                throw DateRangeFilterError.invalidCalendarRange
            }
            beginDay = value
        case .custom:
            beginDay = calendar.startOfDay(for: customStart)
        }

        guard !(endDay < beginDay) else {
            throw DateRangeFilterError.startAfterEnd
        }
        guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDay) else {
            throw DateRangeFilterError.invalidCalendarRange
        }
        let timestamps = try DateRangeFilterValidation.timestamps(
            start: beginDay,
            endExclusive: endExclusive
        )
        return VideoPublicationTimeRange(
            beginTimestamp: timestamps.start,
            endTimestamp: timestamps.endExclusive - 1
        )
    }
}

/// 一个搜索工作集的完整 identity。
///
/// `query` 在初始化时即完成空白规范化。
public struct VideoSearchCriteria: Sendable, Hashable {
    /// 搜索每页条数；`isValid` 要求请求使用这一固定值，调整会改变每次加载更多的条数，
    /// 以及达到列表条目上限所需的页数。
    public static let pageSize = 20

    public let query: String
    public let order: VideoSearchOrder
    public let duration: VideoDurationFilter
    public let publicationRange: VideoPublicationTimeRange?
    public let pageSize: Int

    public init(
        query: String,
        order: VideoSearchOrder = .relevance,
        duration: VideoDurationFilter = .all,
        publicationRange: VideoPublicationTimeRange? = nil
    ) {
        self.query = SearchText.normalized(query)
        self.order = order
        self.duration = duration
        self.publicationRange = publicationRange
        self.pageSize = Self.pageSize
    }

    /// 查询非空且不超过 `SearchText` 的长度上限、使用固定页大小、发布时间范围不为负且不倒置。
    public var isValid: Bool {
        guard !query.isEmpty,
            SearchText.isWithinLimit(query),
            pageSize == Self.pageSize
        else { return false }
        guard let range = publicationRange else { return true }
        return range.beginTimestamp >= 0 && range.beginTimestamp <= range.endTimestamp
    }
}

extension VideoSearchCriteria {
    /// 按搜索规则规范化一组候选词：丢弃不能搜索的词与规范化后重复的词，保持原顺序，最多 `limit` 个。
    public static func uniqueQueries(from candidates: [String], limit: Int) -> [String] {
        var queries: [String] = []
        for candidate in candidates {
            guard queries.count < limit else { break }
            let criteria = VideoSearchCriteria(query: candidate)
            guard criteria.isValid, !queries.contains(criteria.query) else { continue }
            queries.append(criteria.query)
        }
        return queries
    }
}

/// 单次网络请求 identity；分页只改变 `page`，其余条件完整保留。
public struct VideoSearchRequest: Sendable, Hashable {
    public let criteria: VideoSearchCriteria
    public let page: Int

    public init(criteria: VideoSearchCriteria, page: Int) {
        self.criteria = criteria
        self.page = page
    }
}
