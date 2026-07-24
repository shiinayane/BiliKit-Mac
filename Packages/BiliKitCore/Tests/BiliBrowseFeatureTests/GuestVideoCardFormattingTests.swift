@testable import BiliBrowseFeature
import Foundation
import Testing

struct VideoMetadataFormattingTests {
    @Test
    func compactCountsUseOnlyDomesticUnits() {
        #expect(VideoMetadataFormatting.compactCount(-1) == "0")
        #expect(VideoMetadataFormatting.compactCount(9_999) == "9999")
        #expect(VideoMetadataFormatting.compactCount(10_000) == "1万")
        #expect(VideoMetadataFormatting.compactCount(12_345) == "1.2万")
        #expect(
            VideoMetadataFormatting.compactCount(99_999_999)
                == "9999.9万"
        )
        #expect(
            VideoMetadataFormatting.compactCount(100_000_000)
                == "1亿"
        )
        #expect(
            VideoMetadataFormatting.compactCount(123_456_789)
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
            VideoMetadataFormatting.publishedDate(
                now.addingTimeInterval(-30 * 60),
                relativeTo: now,
                calendar: calendar
            ) == "1小时前"
        )
        #expect(
            VideoMetadataFormatting.publishedDate(
                now.addingTimeInterval(-2 * 60 * 60),
                relativeTo: now,
                calendar: calendar
            ) == "2小时前"
        )
        #expect(
            VideoMetadataFormatting.publishedDate(
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
            VideoMetadataFormatting.publishedDate(
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
            VideoMetadataFormatting.publishedDate(
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

    @Test
    func fullPublicationDateIncludesSeconds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(
            TimeZone(identifier: "Asia/Tokyo")
        )
        let date = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 24,
                    hour: 22,
                    minute: 51,
                    second: 3
                )
            )
        )

        #expect(
            VideoMetadataFormatting.fullPublishedDate(
                date,
                calendar: calendar
            ) == "2026年07月24日 22:51:03"
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
