import Foundation
import Testing

@testable import BiliBrowseFeature

struct CommentTimeFormatterTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        return calendar
    }

    @Test
    func relativeBoundariesUseFixedReferenceDate() throws {
        let reference = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 11,
                    hour: 12
                )
            )
        )

        #expect(format(reference.addingTimeInterval(-59), reference) == "刚刚")
        #expect(format(reference.addingTimeInterval(-60), reference) == "1分钟前")
        #expect(format(reference.addingTimeInterval(-3_599), reference) == "59分钟前")
        #expect(format(reference.addingTimeInterval(-3_600), reference) == "1小时前")
        #expect(format(reference.addingTimeInterval(-86_399), reference) == "23小时前")
        #expect(format(reference.addingTimeInterval(-86_400), reference) == "昨天12:00")
    }

    @Test
    func calendarBoundariesDistinguishYesterdayRecentDaysAndYears() throws {
        let reference = try date(2026, 8, 11, 12)

        #expect(format(try date(2026, 8, 10, 9, 5), reference) == "昨天09:05")
        #expect(format(try date(2026, 8, 9, 12), reference) == "2天前")
        #expect(format(try date(2026, 8, 8, 12), reference) == "3天前")
        #expect(format(try date(2026, 7, 1, 12), reference) == "7月1日")
        #expect(format(try date(2025, 12, 31, 12), reference) == "2025年12月31日")
    }

    private func format(_ date: Date, _ reference: Date) -> String {
        CommentTimeFormatter.string(
            for: date,
            relativeTo: reference,
            calendar: calendar
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
            calendar.date(
                from: DateComponents(
                    year: year,
                    month: month,
                    day: day,
                    hour: hour,
                    minute: minute
                )
            )
        )
    }
}
