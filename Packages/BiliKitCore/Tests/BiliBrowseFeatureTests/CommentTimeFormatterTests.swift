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

        #expect(
            format(reference.addingTimeInterval(-59), reference)
                == String(localized: "刚刚", bundle: BrowseFeatureStrings.bundle)
        )
        #expect(
            format(reference.addingTimeInterval(-60), reference)
                == String(localized: "\(1)分钟前", bundle: BrowseFeatureStrings.bundle)
        )
        #expect(
            format(reference.addingTimeInterval(-3_599), reference)
                == String(localized: "\(59)分钟前", bundle: BrowseFeatureStrings.bundle)
        )
        #expect(
            format(reference.addingTimeInterval(-3_600), reference)
                == String(localized: "\(1)小时前", bundle: BrowseFeatureStrings.bundle)
        )
        #expect(
            format(reference.addingTimeInterval(-86_399), reference)
                == String(localized: "\(23)小时前", bundle: BrowseFeatureStrings.bundle)
        )
        #expect(
            format(reference.addingTimeInterval(-86_400), reference)
                == String(localized: "昨天\("12:00")", bundle: BrowseFeatureStrings.bundle)
        )
    }

    @Test
    func calendarBoundariesDistinguishYesterdayRecentDaysAndYears() throws {
        let reference = try date(2026, 8, 11, 12)

        #expect(
            format(try date(2026, 8, 10, 9, 5), reference)
                == String(localized: "昨天\("9:05")", bundle: BrowseFeatureStrings.bundle)
        )
        #expect(
            format(try date(2026, 8, 9, 12), reference)
                == String(localized: "\(2)天前", bundle: BrowseFeatureStrings.bundle)
        )
        #expect(
            format(try date(2026, 8, 8, 12), reference)
                == String(localized: "\(3)天前", bundle: BrowseFeatureStrings.bundle)
        )
        let sameYear = try date(2026, 7, 1, 12)
        #expect(
            format(sameYear, reference)
                == String(localized: "\(7)月\(1)日", bundle: BrowseFeatureStrings.bundle)
        )
        #expect(format(try date(2025, 12, 31, 12), reference).contains("2025"))
    }

    private func format(_ date: Date, _ reference: Date) -> String {
        CommentTimeFormatter.string(
            for: date,
            relativeTo: reference,
            calendar: calendar,
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
