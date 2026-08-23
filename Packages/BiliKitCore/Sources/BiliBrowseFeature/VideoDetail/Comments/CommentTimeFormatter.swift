import Foundation

public enum CommentTimeFormatter {
    public static func string(
        for date: Date,
        relativeTo referenceDate: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let elapsed = max(0, referenceDate.timeIntervalSince(date))
        if elapsed < 60 {
            return BrowseFeatureStrings.localized("刚刚", locale: locale)
        }
        if elapsed < 3_600 {
            let minutes = Int(elapsed / 60)
            return BrowseFeatureStrings.localized("\(minutes)分钟前", locale: locale)
        }
        if elapsed < 86_400 {
            let hours = Int(elapsed / 3_600)
            return BrowseFeatureStrings.localized("\(hours)小时前", locale: locale)
        }

        let referenceDay = calendar.startOfDay(for: referenceDate)
        let commentDay = calendar.startOfDay(for: date)
        let dayDifference =
            calendar.dateComponents(
                [.day],
                from: commentDay,
                to: referenceDay
            ).day ?? 0
        if dayDifference == 1 {
            let time = formatted(
                date,
                date: .omitted,
                time: .shortened,
                calendar: calendar,
                locale: locale
            )
            return BrowseFeatureStrings.localized("昨天\(time)", locale: locale)
        }
        if dayDifference == 2 || dayDifference == 3 {
            return BrowseFeatureStrings.localized("\(dayDifference)天前", locale: locale)
        }
        let sameYear =
            calendar.component(.year, from: date)
            == calendar.component(.year, from: referenceDate)
        if sameYear {
            let month = calendar.component(.month, from: date)
            let day = calendar.component(.day, from: date)
            return BrowseFeatureStrings.localized("\(month)月\(day)日", locale: locale)
        }
        return formatted(
            date,
            date: .long,
            time: .omitted,
            calendar: calendar,
            locale: locale
        )
    }

    private static func formatted(
        _ dateValue: Date,
        date dateStyle: Date.FormatStyle.DateStyle,
        time timeStyle: Date.FormatStyle.TimeStyle,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        var style = Date.FormatStyle(date: dateStyle, time: timeStyle)
            .locale(locale)
        style.timeZone = calendar.timeZone
        return dateValue.formatted(style)
    }
}
