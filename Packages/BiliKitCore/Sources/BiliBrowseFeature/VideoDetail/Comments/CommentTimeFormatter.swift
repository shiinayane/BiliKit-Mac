import Foundation

public enum CommentTimeFormatter {
    public static func string(
        for date: Date,
        relativeTo referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let elapsed = max(0, referenceDate.timeIntervalSince(date))
        if elapsed < 60 {
            return "刚刚"
        }
        if elapsed < 3_600 {
            return "\(Int(elapsed / 60))分钟前"
        }
        if elapsed < 86_400 {
            return "\(Int(elapsed / 3_600))小时前"
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
            return "昨天\(formatted(date, format: "HH:mm", calendar: calendar))"
        }
        if dayDifference == 2 || dayDifference == 3 {
            return "\(dayDifference)天前"
        }
        let sameYear =
            calendar.component(.year, from: date)
            == calendar.component(.year, from: referenceDate)
        return formatted(
            date,
            format: sameYear ? "M月d日" : "yyyy年M月d日",
            calendar: calendar
        )
    }

    private static func formatted(
        _ date: Date,
        format: String,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
