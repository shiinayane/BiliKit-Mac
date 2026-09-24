import Foundation
import Testing

@testable import BiliBrowseFeature

/// 东京时间 2026-08-11 12:00 为参照；显式 zh-Hans 区域与日历时区。
struct CommentTimeFormatterTests {
    @Test(arguments: [
        (secondsAgo: 59, expected: localized("刚刚")),
        (secondsAgo: 60, expected: localized("\(1)分钟前")),
        (secondsAgo: 3_599, expected: localized("\(59)分钟前")),
        (secondsAgo: 3_600, expected: localized("\(1)小时前")),
        (secondsAgo: 86_399, expected: localized("\(23)小时前")),
        (secondsAgo: 86_400, expected: localized("昨天\("12:00")"))
    ])
    func relativeBoundariesUseFixedReferenceDate(secondsAgo: Int, expected: String) throws {
        let reference = try date(2026, 8, 11, 12)

        #expect(format(reference.addingTimeInterval(-Double(secondsAgo)), reference) == expected)
    }

    @Test(arguments: [
        (year: 2026, month: 8, day: 10, hour: 9, minute: 5, expected: localized("昨天\("9:05")")),
        (year: 2026, month: 8, day: 9, hour: 12, minute: 0, expected: localized("\(2)天前")),
        (year: 2026, month: 8, day: 8, hour: 12, minute: 0, expected: localized("\(3)天前")),
        (year: 2026, month: 7, day: 1, hour: 12, minute: 0, expected: localized("\(7)月\(1)日")),
        (year: 2025, month: 12, day: 31, hour: 12, minute: 0, expected: "2025年12月31日")
    ])
    func calendarBoundariesDistinguishYesterdayRecentDaysAndYears(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        expected: String
    ) throws {
        let reference = try date(2026, 8, 11, 12)

        #expect(format(try date(year, month, day, hour, minute), reference) == expected)
    }

    private func format(_ date: Date, _ reference: Date) -> String {
        CommentTimeFormatter.string(
            for: date,
            relativeTo: reference,
            calendar: tokyoCalendar,
            locale: Locale(identifier: "zh-Hans")
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int = 0
    ) throws -> Date {
        try #require(
            tokyoCalendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
            )
        )
    }
}

private let tokyoCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
    return calendar
}()

private func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: BrowseFeatureStrings.bundle)
}
