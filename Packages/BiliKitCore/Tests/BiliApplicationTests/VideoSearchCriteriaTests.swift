import BiliApplication
import Foundation
import Testing

struct VideoSearchCriteriaTests {
    private var tokyoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        return calendar
    }

    @Test
    func criteriaNormalizesQueryAndDefaults() {
        let criteria = VideoSearchCriteria(query: "  macOS\n")

        #expect(criteria.query == "macOS")
        #expect(criteria.order == .relevance)
        #expect(criteria.duration == .all)
        #expect(criteria.publicationRange == nil)
        #expect(criteria.pageSize == 20)
    }

    @Test(arguments: [
        (VideoPublicationFilter.today, 0),
        (.lastSevenDays, -6),
        (.last180Days, -179),
    ])
    func relativeRangesFreezeToLocalNaturalDays(
        filter: VideoPublicationFilter,
        beginDayOffset: Int
    ) throws {
        let calendar = tokyoCalendar
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 23,
                    hour: 14
                )
            )
        )
        let today = calendar.startOfDay(for: now)
        let expectedBegin = try #require(
            calendar.date(byAdding: .day, value: beginDayOffset, to: today)
        )
        let range = try #require(
            try VideoPublicationRangeResolver.resolve(
                filter: filter,
                customStart: now,
                customEnd: now,
                now: now,
                calendar: calendar
            )
        )

        #expect(range.beginTimestamp == Int64(expectedBegin.timeIntervalSince1970))
        let expectedEndExclusive = try #require(
            calendar.date(byAdding: .day, value: 1, to: today)
        )
        #expect(
            range.endTimestamp
                == Int64(expectedEndExclusive.timeIntervalSince1970) - 1
        )
    }

    @Test
    func customRangeIncludesSingleAndMultipleCompleteDays() throws {
        let calendar = tokyoCalendar
        let now = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 23))
        )
        let start = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 20))
        )
        let single = try #require(
            try VideoPublicationRangeResolver.resolve(
                filter: .custom,
                customStart: start,
                customEnd: start,
                now: now,
                calendar: calendar
            )
        )
        let multiple = try #require(
            try VideoPublicationRangeResolver.resolve(
                filter: .custom,
                customStart: start,
                customEnd: now,
                now: now,
                calendar: calendar
            )
        )

        let singleEndExclusive = try #require(
            calendar.date(byAdding: .day, value: 1, to: start)
        )
        let multipleEndExclusive = try #require(
            calendar.date(byAdding: .day, value: 1, to: now)
        )
        #expect(
            single.endTimestamp
                == Int64(singleEndExclusive.timeIntervalSince1970) - 1
        )
        #expect(
            multiple.endTimestamp
                == Int64(multipleEndExclusive.timeIntervalSince1970) - 1
        )
    }

    @Test
    func naturalDayRangeFollowsCalendarAcrossDaylightSavingChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))

        for (month, day, expectedHours) in [(3, 8, 23), (11, 1, 25)] {
            let now = try #require(
                calendar.date(
                    from: DateComponents(
                        year: 2026,
                        month: month,
                        day: day,
                        hour: 12
                    )
                )
            )
            let begin = calendar.startOfDay(for: now)
            let endExclusive = try #require(
                calendar.date(byAdding: .day, value: 1, to: begin)
            )
            let range = try #require(
                try VideoPublicationRangeResolver.resolve(
                    filter: .today,
                    customStart: now,
                    customEnd: now,
                    now: now,
                    calendar: calendar
                )
            )

            #expect(range.beginTimestamp == Int64(begin.timeIntervalSince1970))
            #expect(
                range.endTimestamp
                    == Int64(endExclusive.timeIntervalSince1970) - 1
            )
            #expect(
                range.endTimestamp - range.beginTimestamp
                    == Int64(expectedHours * 60 * 60 - 1)
            )
        }
    }

    @Test
    func customRangeRejectsReverseAndFutureDates() throws {
        let calendar = tokyoCalendar
        let today = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 23))
        )
        let yesterday = try #require(
            calendar.date(byAdding: .day, value: -1, to: today)
        )
        let tomorrow = try #require(
            calendar.date(byAdding: .day, value: 1, to: today)
        )

        #expect(throws: VideoPublicationRangeError.startAfterEnd) {
            try VideoPublicationRangeResolver.resolve(
                filter: .custom,
                customStart: today,
                customEnd: yesterday,
                now: today,
                calendar: calendar
            )
        }
        #expect(throws: VideoPublicationRangeError.futureDate) {
            try VideoPublicationRangeResolver.resolve(
                filter: .custom,
                customStart: today,
                customEnd: tomorrow,
                now: today,
                calendar: calendar
            )
        }
    }
}
