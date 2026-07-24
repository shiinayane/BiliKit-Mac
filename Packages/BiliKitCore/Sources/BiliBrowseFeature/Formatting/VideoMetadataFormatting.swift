import Foundation

enum VideoMetadataFormatting {
    static func compactCount(_ count: Int64) -> String {
        let normalizedCount = max(0, count)
        if normalizedCount >= 100_000_000 {
            return compactUnit(
                normalizedCount,
                divisor: 100_000_000,
                suffix: "亿"
            )
        }
        if normalizedCount >= 10_000 {
            return compactUnit(
                normalizedCount,
                divisor: 10_000,
                suffix: "万"
            )
        }
        return String(normalizedCount)
    }

    static func publishedDate(
        _ date: Date,
        relativeTo now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let elapsedHours = calendar.dateComponents(
                [.hour],
                from: date,
                to: now
            ).hour ?? 0
            return "\(max(1, elapsedHours))小时前"
        }

        if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: now
        ),
           calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "昨天"
        }

        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        if year == calendar.component(.year, from: now) {
            return "\(month)月\(day)日"
        }
        return "\(year)年\(month)月\(day)日"
    }

    static func fullPublishedDate(
        _ date: Date,
        calendar: Calendar = .current
    ) -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "%04d年%02d月%02d日 %02d:%02d:%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
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
