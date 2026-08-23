import Foundation

public enum VideoSearchOrder: String, Sendable, Hashable, CaseIterable, Identifiable {
    case relevance
    case mostPlayed
    case newest
    case mostDanmaku
    case mostFavorited

    public var id: Self { self }
}

public enum VideoDurationFilter: Int, Sendable, Hashable, CaseIterable, Identifiable {
    case all = 0
    case underTenMinutes = 1
    case tenToThirtyMinutes = 2
    case thirtyToSixtyMinutes = 3
    case overSixtyMinutes = 4

    public var id: Self { self }
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

public enum VideoPublicationFilter: Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case today
    case lastSevenDays
    case last180Days
    case custom

    public var id: Self { self }
}

public enum VideoPublicationRangeError: Error, Sendable, Equatable {
    case startAfterEnd
    case futureDate
    case invalidCalendarRange
}

/// 将日期选择集中转换为 API 使用的整日 Unix 秒闭区间。
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
        guard endDay <= today else {
            throw VideoPublicationRangeError.futureDate
        }

        let beginDay: Date
        switch filter {
        case .all:
            return nil
        case .today:
            beginDay = today
        case .lastSevenDays:
            guard let value = calendar.date(byAdding: .day, value: -6, to: today) else {
                throw VideoPublicationRangeError.invalidCalendarRange
            }
            beginDay = value
        case .last180Days:
            guard let value = calendar.date(byAdding: .day, value: -179, to: today) else {
                throw VideoPublicationRangeError.invalidCalendarRange
            }
            beginDay = value
        case .custom:
            beginDay = calendar.startOfDay(for: customStart)
        }

        guard beginDay <= endDay else {
            throw VideoPublicationRangeError.startAfterEnd
        }
        guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: endDay) else {
            throw VideoPublicationRangeError.invalidCalendarRange
        }
        return VideoPublicationTimeRange(
            beginTimestamp: Int64(beginDay.timeIntervalSince1970),
            endTimestamp: Int64(endExclusive.timeIntervalSince1970) - 1
        )
    }
}

/// 一个搜索工作集的完整 identity。
///
/// `query` 在初始化时即完成空白规范化。
public struct VideoSearchCriteria: Sendable, Hashable {
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
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.order = order
        self.duration = duration
        self.publicationRange = publicationRange
        self.pageSize = Self.pageSize
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
