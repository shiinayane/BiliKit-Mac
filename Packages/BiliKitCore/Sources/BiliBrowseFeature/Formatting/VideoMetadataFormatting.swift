import Foundation

enum VideoMetadataFormatting {
    static func compactCount(_ count: Int64, locale: Locale = .current) -> String {
        let normalizedCount = max(0, count)
        if locale.language.languageCode?.identifier == "en" {
            if normalizedCount >= 1_000_000_000 {
                return compactUnit(normalizedCount, divisor: 1_000_000_000, suffix: "B")
            }
            if normalizedCount >= 1_000_000 {
                return compactUnit(normalizedCount, divisor: 1_000_000, suffix: "M")
            }
            if normalizedCount >= 1_000 {
                return compactUnit(normalizedCount, divisor: 1_000, suffix: "K")
            }
            return normalizedCount.formatted(.number.locale(locale))
        }
        if normalizedCount >= 100_000_000 {
            return compactUnit(
                normalizedCount,
                divisor: 100_000_000,
                suffix: BrowseFeatureStrings.localized("亿", locale: locale)
            )
        }
        if normalizedCount >= 10_000 {
            return compactUnit(
                normalizedCount,
                divisor: 10_000,
                suffix: BrowseFeatureStrings.localized("万", locale: locale)
            )
        }
        return String(normalizedCount)
    }

    static func publishedDate(
        _ date: Date,
        relativeTo now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let elapsedHours =
                calendar.dateComponents(
                    [.hour],
                    from: date,
                    to: now
                ).hour ?? 0
            let hours = max(1, elapsedHours)
            return BrowseFeatureStrings.localized("\(hours)小时前", locale: locale)
        }

        if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: now
        ),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return BrowseFeatureStrings.localized("昨天", locale: locale)
        }

        let sameYear =
            calendar.component(.year, from: date)
            == calendar.component(.year, from: now)
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

    static func fullPublishedDate(
        _ date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        formatted(
            date,
            date: .long,
            time: .standard,
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

    private static func compactUnit(
        _ count: Int64,
        divisor: Int64,
        suffix: String
    ) -> String {
        let whole = count / divisor
        let fraction = count % divisor * 10 / divisor
        if fraction == 0 {
            return "\(whole)\(suffix)"
        }
        return "\(whole).\(fraction)\(suffix)"
    }
}
