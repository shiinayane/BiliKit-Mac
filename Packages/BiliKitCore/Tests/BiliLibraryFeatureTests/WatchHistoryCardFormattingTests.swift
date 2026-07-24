@testable import BiliLibraryFeature
import Foundation
import Testing

struct WatchHistoryCardFormattingTests {
    @Test
    func progressShowsElapsedDurationOrCompletedState() {
        #expect(
            WatchHistoryCardFormatting.progress(
                progressSeconds: 65,
                durationSeconds: 600
            ) == "1:05/10:00"
        )
        #expect(
            WatchHistoryCardFormatting.progress(
                progressSeconds: 3_661,
                durationSeconds: 7_322
            ) == "1:01:01/2:02:02"
        )
        #expect(
            WatchHistoryCardFormatting.progress(
                progressSeconds: 600,
                durationSeconds: 600
            ) == "已看完"
        )
        #expect(
            WatchHistoryCardFormatting.progress(
                progressSeconds: 0,
                durationSeconds: 0
            ) == "0:00/0:00"
        )
    }

    @Test
    func viewedAtUsesRelativeDaysAndDomesticMonthDayTime() throws {
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
                    hour: 13
                )
            )
        )
        let today = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 24,
                    hour: 9,
                    minute: 5
                )
            )
        )
        let yesterday = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 23,
                    hour: 22,
                    minute: 7
                )
            )
        )
        let older = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 20,
                    hour: 8,
                    minute: 3
                )
            )
        )

        #expect(
            WatchHistoryCardFormatting.viewedAt(
                today,
                now: now,
                calendar: calendar
            ) == "今天 09:05"
        )
        #expect(
            WatchHistoryCardFormatting.viewedAt(
                yesterday,
                now: now,
                calendar: calendar
            ) == "昨天 22:07"
        )
        #expect(
            WatchHistoryCardFormatting.viewedAt(
                older,
                now: now,
                calendar: calendar
            ) == "7月20日 08:03"
        )
    }
}
