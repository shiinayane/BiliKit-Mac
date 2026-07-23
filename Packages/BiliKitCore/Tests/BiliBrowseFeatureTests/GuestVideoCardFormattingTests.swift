@testable import BiliBrowseFeature
import Foundation
import Testing

struct GuestVideoCardFormattingTests {
    @Test
    func compactCountsUseOnlyDomesticUnits() {
        #expect(GuestVideoCardFormatting.compactCount(-1) == "0")
        #expect(GuestVideoCardFormatting.compactCount(9_999) == "9999")
        #expect(GuestVideoCardFormatting.compactCount(10_000) == "1万")
        #expect(GuestVideoCardFormatting.compactCount(12_345) == "1.2万")
        #expect(
            GuestVideoCardFormatting.compactCount(99_999_999)
                == "9999.9万"
        )
        #expect(
            GuestVideoCardFormatting.compactCount(100_000_000)
                == "1亿"
        )
        #expect(
            GuestVideoCardFormatting.compactCount(123_456_789)
                == "1.2亿"
        )
    }

    @Test
    func publicationDateUsesHoursForTodayAndDatesForOlderItems() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(
            TimeZone(identifier: "Asia/Tokyo")
        )
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 24,
                    hour: 10,
                    minute: 30
                )
            )
        )

        #expect(
            GuestVideoCardFormatting.publishedDate(
                now.addingTimeInterval(-30 * 60),
                relativeTo: now,
                calendar: calendar
            ) == "1小时前"
        )
        #expect(
            GuestVideoCardFormatting.publishedDate(
                now.addingTimeInterval(-2 * 60 * 60),
                relativeTo: now,
                calendar: calendar
            ) == "2小时前"
        )
        #expect(
            GuestVideoCardFormatting.publishedDate(
                try date(
                    year: 2026,
                    month: 7,
                    day: 23,
                    calendar: calendar
                ),
                relativeTo: now,
                calendar: calendar
            ) == "昨天"
        )
        #expect(
            GuestVideoCardFormatting.publishedDate(
                try date(
                    year: 2026,
                    month: 7,
                    day: 1,
                    calendar: calendar
                ),
                relativeTo: now,
                calendar: calendar
            ) == "7月1日"
        )
        #expect(
            GuestVideoCardFormatting.publishedDate(
                try date(
                    year: 2025,
                    month: 12,
                    day: 31,
                    calendar: calendar
                ),
                relativeTo: now,
                calendar: calendar
            ) == "2025年12月31日"
        )
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        calendar: Calendar
    ) throws -> Date {
        try #require(
            calendar.date(
                from: DateComponents(
                    year: year,
                    month: month,
                    day: day,
                    hour: 12
                )
            )
        )
    }
}
