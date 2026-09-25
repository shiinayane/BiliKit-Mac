import Foundation
import Testing

@testable import BiliBrowseFeature

struct VideoMetadataFormattingTests {
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
            -1, 999, 1000, 9999, 10_000, 12_345, 99_999_999, 100_000_000, 123_456_789
        ]
        #expect(counts.map { VideoMetadataFormatting.compactCount($0, locale: locale) } == expected)
    }

    /// 东京时间 2026-07-24 10:30 为 now；同日按小时、前一日为“昨天”、同年省略年份。
    @Test(arguments: [
        (year: 2026, month: 7, day: 24, hour: 10, minute: 0, expected: localized("\(1)小时前")),
        (year: 2026, month: 7, day: 24, hour: 8, minute: 30, expected: localized("\(2)小时前")),
        (year: 2026, month: 7, day: 24, hour: 0, minute: 5, expected: localized("\(10)小时前")),
        (year: 2026, month: 7, day: 23, hour: 23, minute: 59, expected: localized("昨天")),
        (year: 2026, month: 7, day: 1, hour: 12, minute: 0, expected: localized("\(7)月\(1)日")),
        (year: 2025, month: 12, day: 31, hour: 12, minute: 0, expected: "2025年12月31日")
    ])
    func publicationDateUsesCalendarDayBoundaries(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        expected: String
    ) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let now = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 24, hour: 10, minute: 30))
        )
        let published = try #require(
            calendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
            )
        )

        #expect(
            VideoMetadataFormatting.publishedDate(
                published,
                relativeTo: now,
                calendar: calendar,
                locale: Locale(identifier: "zh-Hans")
            ) == expected
        )
    }
}

private func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: BrowseFeatureStrings.bundle)
}
