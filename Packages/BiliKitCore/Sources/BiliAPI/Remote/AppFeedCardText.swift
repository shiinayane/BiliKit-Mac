import Foundation

/// 把 App 端推荐卡片上的展示文字解析回数值：封面角上的「25.4万观看」「13弹幕」，以及描述「UP名 · 6月11日」里的日期。
///
/// App 卡片不给原始计数与时间戳，只给按中文排好的文字；解析回数值后由各语言界面自己格式化。按文字的后缀判断是播放
/// 还是弹幕，不按位置：三个角标位置的含义随请求参数而变。认不出的文字一律按缺失处理（卡片不显示这一项），不猜。
/// 无状态。
enum AppFeedCardText {
    /// B 站以北京时间显示日期；「6月11日」「昨天」这类日期按这个时区换算成时刻。
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        return calendar
    }()

    private static let viewSuffixes = ["观看", "播放"]
    private static let danmakuSuffixes = ["弹幕"]

    /// 三个角标文字里的播放数与弹幕数；同一类出现多次时取第一次。
    static func counts(in texts: [String]) -> (views: Int64?, danmaku: Int64?) {
        var views: Int64?
        var danmaku: Int64?
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if views == nil, let value = count(trimmed, suffixes: viewSuffixes) {
                views = value
            } else if danmaku == nil, let value = count(trimmed, suffixes: danmakuSuffixes) {
                danmaku = value
            }
        }
        return (views, danmaku)
    }

    /// 「25.4万」「1.2亿」「13」去掉给定后缀后的近似整数；没有这个后缀或数字部分认不出时为 nil。
    private static func count(_ text: String, suffixes: [String]) -> Int64? {
        guard let suffix = suffixes.first(where: text.hasSuffix) else { return nil }
        var number = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        var multiplier: Double = 1
        if number.hasSuffix("万") {
            multiplier = 10_000
            number.removeLast()
        } else if number.hasSuffix("亿") {
            multiplier = 100_000_000
            number.removeLast()
        }
        // `Int64(exactly:)` 而不是 `Int64(_:)`：后者遇到超出范围的值（如「99999999999999999999观看」）会让进程崩溃。
        guard !number.isEmpty,
            number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
            let value = Double(number),
            value >= 0,
            let count = Int64(exactly: (value * multiplier).rounded())
        else {
            return nil
        }
        return count
    }

    /// 描述最后一个「 · 」之后的日期；没有分隔符或日期格式认不出时为 nil。
    ///
    /// 认得的格式：`N分钟前`、`N小时前`、`N天前`、`昨天`、`昨天 HH:MM`、`M月D日`（今年；若晚于 `now` 则是去年）、
    /// `YYYY年M月D日`、`YYYY-M-D` 与 `M-D`。没有时分的日期按北京时间当天零点。
    static func publishedDate(inDescription description: String, now: Date) -> Date? {
        guard let separator = description.range(of: " · ", options: .backwards) else {
            return nil
        }
        let text = description[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        if let minutes = leadingInteger(text, suffix: "分钟前") {
            return now.addingTimeInterval(-TimeInterval(minutes) * 60)
        }
        if let hours = leadingInteger(text, suffix: "小时前") {
            return now.addingTimeInterval(-TimeInterval(hours) * 3_600)
        }
        if let days = leadingInteger(text, suffix: "天前") {
            return now.addingTimeInterval(-TimeInterval(days) * 86_400)
        }
        if let yesterday = yesterday(text, now: now) {
            return yesterday
        }
        guard let (year, month, day) = dateComponents(text) else { return nil }
        let currentYear = calendar.component(.year, from: now)
        guard let date = date(year: year ?? currentYear, month: month, day: day) else {
            return nil
        }
        // 只写月日的日期总在过去：今年的这一天还没到，就是去年的。
        if year == nil, now < date {
            return self.date(year: currentYear - 1, month: month, day: day)
        }
        return date
    }

    /// `昨天` 为昨天零点，`昨天 HH:MM` 为昨天的这一时刻（北京时间）；其他形状为 nil。
    private static func yesterday(_ text: String, now: Date) -> Date? {
        guard text.hasPrefix("昨天"),
            let start = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        else {
            return nil
        }
        let time = text.dropFirst("昨天".count)
        if time.isEmpty { return start }
        let parts = time.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        guard time.first == " ", parts.count == 2,
            parts.allSatisfy({ part in
                (1...2).contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber }
            }),
            let hour = Int(parts[0]), let minute = Int(parts[1]),
            (0..<24).contains(hour), (0..<60).contains(minute)
        else {
            return nil
        }
        return start.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
    }

    private static func leadingInteger(_ text: String, suffix: String) -> Int? {
        guard text.hasSuffix(suffix) else { return nil }
        let number = text.dropLast(suffix.count)
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(number)
    }

    /// `YYYY年M月D日`、`M月D日`、`YYYY-M-D`、`M-D` 拆成（年，月，日），年可缺；其他形状为 nil。
    private static func dateComponents(_ text: String) -> (Int?, Int, Int)? {
        let parts: [Substring]
        if text.hasSuffix("日") {
            parts = text.dropLast().split(
                omittingEmptySubsequences: false,
                whereSeparator: { $0 == "年" || $0 == "月" }
            )
        } else {
            parts = text.split(separator: "-", omittingEmptySubsequences: false)
        }
        guard (2...3).contains(parts.count),
            parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else {
            return nil
        }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        if numbers.count == 3 {
            return (numbers[0], numbers[1], numbers[2])
        }
        return (nil, numbers[0], numbers[1])
    }

    /// 合法的公历日期（北京时间当天零点）；`2月30日` 这类不存在的日期为 nil，不让 Calendar 顺延。
    private static func date(year: Int, month: Int, day: Int) -> Date? {
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
            calendar.dateComponents([.year, .month, .day], from: date) == components
        else {
            return nil
        }
        return date
    }
}
