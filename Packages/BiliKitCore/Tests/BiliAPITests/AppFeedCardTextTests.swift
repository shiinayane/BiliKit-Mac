import Foundation
import Testing

@testable import BiliAPI

/// App 推荐卡片上的展示文字解析回数值：计数按后缀认播放与弹幕（不按位置），日期认得几种 B 站写法并按北京时间换算；
/// 认不出的一律为 nil，卡片不显示这一项。
struct AppFeedCardTextTests {
    @Test(
        arguments: [
            (["2:05", "25.4万观看", "13弹幕"], 254_000, 13),
            (["13弹幕", "1.2亿播放"], 120_000_000, 13),
            (["0:42", "987观看", "-弹幕"], 987, nil),
            (["暂无"], nil, nil),
            (["1.2.3万观看", "-5弹幕"], nil, nil)
        ] as [([String], Int64?, Int64?)]
    )
    func parsesCountsBySuffix(texts: [String], views: Int64?, danmaku: Int64?) {
        let counts = AppFeedCardText.counts(in: texts)
        #expect(counts.views == views)
        #expect(counts.danmaku == danmaku)
    }

    /// `now` 是北京时间 2026-11-05 12:00。
    @Test(
        arguments: [
            ("作者 · 5分钟前", "2026-11-05 11:55"),
            ("作者 · 3小时前", "2026-11-05 09:00"),
            ("作者 · 2天前", "2026-11-03 12:00"),
            ("作者 · 昨天", "2026-11-04 00:00"),
            ("作者 · 昨天 08:30", "2026-11-04 08:30"),
            ("作者 · 6月11日", "2026-06-11 00:00"),
            ("作者 · 12月31日", "2025-12-31 00:00"),
            ("作者 · 2024年2月29日", "2024-02-29 00:00"),
            ("作者 · 2023-7-1", "2023-07-01 00:00"),
            ("作者 · 7-1", "2026-07-01 00:00"),
            ("作 · 者 · 6月11日", "2026-06-11 00:00"),
            ("作者", nil),
            ("作者 · 2月30日", nil),
            ("作者 · 昨天 24:00", nil),
            ("作者 · 昨天08:30", nil),
            ("作者 · 很久以前", nil)
        ] as [(String, String?)]
    )
    func parsesPublishedDateAfterLastSeparator(description: String, expected: String?) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let now = try #require(formatter.date(from: "2026-11-05 12:00"))

        let date = AppFeedCardText.publishedDate(inDescription: description, now: now)

        #expect(date == expected.flatMap(formatter.date(from:)))
    }
}
