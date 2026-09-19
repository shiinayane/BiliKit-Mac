import Foundation
import Testing

@testable import BiliBrowseFeature

struct VideoMetadataFormattingTests {
    @Test
    func simplifiedChineseResourcesPreserveUnitsAndRelativeTime() throws {
        let url = try #require(
            BrowseFeatureStrings.bundle.url(forResource: "zh-Hans", withExtension: "lproj")
        )
        let chinese = try #require(Bundle(url: url))
        #expect(String(localized: "万", bundle: chinese) == "万")
        #expect(String(localized: "亿", bundle: chinese) == "亿")
        #expect(String(localized: "\(59)分钟前", bundle: chinese) == "59分钟前")
        #expect(String(localized: "\(23)小时前", bundle: chinese) == "23小时前")
        #expect(String(localized: "昨天", bundle: chinese) == "昨天")
    }

    @Test
    func compactCountsMatchResourceLanguage() throws {
        let language = try #require(BrowseFeatureStrings.bundle.preferredLocalizations.first)
        let locale = Locale(identifier: language)
        let expected: [String]
        switch language {
        case "en": expected = ["0", "999", "1K", "9.9K", "10K", "12.3K", "99.9M", "100M", "123.4M"]
        case "ja": expected = ["0", "999", "1000", "9999", "1万", "1.2万", "9999.9万", "1億", "1.2億"]
        case "zh-Hans":
            expected = ["0", "999", "1000", "9999", "1万", "1.2万", "9999.9万", "1亿", "1.2亿"]
        case "zh-Hant":
            expected = ["0", "999", "1000", "9999", "1萬", "1.2萬", "9999.9萬", "1億", "1.2億"]
        default:
            Issue.record("Missing compact-count expectations for supported language: \(language)")
            return
        }
        let counts: [Int64] = [
            -1, 999, 1000, 9999, 10_000, 12_345, 99_999_999, 100_000_000, 123_456_789,
        ]
        #expect(counts.map { VideoMetadataFormatting.compactCount($0, locale: locale) } == expected)
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
                calendar: calendar,
                locale: Locale(identifier: "zh-Hans")
            ) == String(localized: "\(1)小时前", bundle: BrowseFeatureStrings.bundle)
        )
        #expect(
            VideoMetadataFormatting.publishedDate(
                now.addingTimeInterval(-2 * 60 * 60),
                relativeTo: now,
                calendar: calendar,
                locale: Locale(identifier: "zh-Hans")
            ) == String(localized: "\(2)小时前", bundle: BrowseFeatureStrings.bundle)
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
                calendar: calendar,
                locale: Locale(identifier: "zh-Hans")
            ) == String(localized: "昨天", bundle: BrowseFeatureStrings.bundle)
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
                calendar: calendar,
                locale: Locale(identifier: "zh-Hans")
            ) == String(localized: "\(7)月\(1)日", bundle: BrowseFeatureStrings.bundle)
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
                calendar: calendar,
                locale: Locale(identifier: "zh-Hans")
            ).contains("2025")
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
                calendar: calendar,
                locale: Locale(identifier: "zh-Hans")
            ).contains("22:51:03")
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
