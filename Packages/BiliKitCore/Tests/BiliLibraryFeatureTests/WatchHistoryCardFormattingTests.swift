import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliLibraryFeature
@testable import BiliUI

struct WatchHistoryCardFormattingTests {
    /// 固定的观看时刻 2023-11-14 22:13:20 UTC，与执行日期相隔多年。
    ///
    /// 比较两份展示的读屏文字时，两份各自按构造时的 now 格式化时间；这个时刻在任何 now 下都落在「更早、跨年」
    /// 分支，两份相同。用 `.now` 时两次构造若跨过本地午夜，「今天」与「昨天」不同，比较就会失败。
    private static let fixedViewedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// 日期前按观看设备显示图标，读屏在最后读出设备；设备未知时都不显示。
    @Test(arguments: [
        (WatchHistoryDevice?.some(.phone), "smartphone" as String?),
        (.pad, "ipad"),
        (.web, "desktopcomputer"),
        (.tv, "tv"),
        (nil, nil)
    ])
    func deviceShowsAnIconBeforeTheDateAndInTheAccessibilityLabel(
        device: WatchHistoryDevice?,
        symbolName: String?
    ) {
        let locale = Locale(identifier: "zh-Hans")
        let item = WatchHistoryItem(
            bvid: "BV1HistoryDevice",
            title: "历史卡片",
            coverURL: nil,
            owner: VideoOwner(id: 7, name: "历史作者"),
            progressSeconds: 65,
            durationSeconds: 600,
            viewedAt: Self.fixedViewedAt,
            device: device
        )
        let presentation = WatchHistoryCardPresentation(item: item, locale: locale)
        let withoutDevice = WatchHistoryCardPresentation(
            item: WatchHistoryItem(
                bvid: item.bvid,
                title: item.title,
                coverURL: nil,
                owner: item.owner,
                progressSeconds: item.progressSeconds,
                durationSeconds: item.durationSeconds,
                viewedAt: item.viewedAt
            ),
            locale: locale
        )

        #expect(presentation.footerTrailingSymbolName == symbolName)
        if let device {
            let spoken = WatchHistoryCardFormatting.deviceLabel(device, locale: locale)
            #expect(presentation.accessibilityLabel.hasSuffix(spoken))
        } else {
            #expect(presentation.accessibilityLabel == withoutDevice.accessibilityLabel)
        }
    }

    @Test
    func loadedAndLoadingMoreProjectToTheSameStableSurface() {
        let item = WatchHistoryItem(
            bvid: "BV1HistorySurface",
            title: "历史卡片",
            coverURL: nil,
            owner: VideoOwner(id: 7, name: "历史作者"),
            progressSeconds: 65,
            durationSeconds: 600,
            viewedAt: .now
        )
        let continuation = WatchHistoryContinuation(rawValue: "opaque")
        let loaded = LibraryVideoListLoadedSurface<WatchHistoryItem, WatchHistoryContinuation>(
            state: .loaded(
                items: [item],
                continuation: continuation,
                loadMoreError: nil
            ),
            requiresManualLoadMore: false
        )
        let loadingMore = LibraryVideoListLoadedSurface<WatchHistoryItem, WatchHistoryContinuation>(
            state: .loadingMore(items: [item], continuation: continuation),
            requiresManualLoadMore: false
        )
        let retry = LibraryVideoListLoadedSurface<WatchHistoryItem, WatchHistoryContinuation>(
            state: .loaded(
                items: [item],
                continuation: continuation,
                loadMoreError: .transportFailure
            ),
            requiresManualLoadMore: false
        )

        #expect(loaded?.items == loadingMore?.items)
        #expect(loaded?.canLoadMore == true)
        #expect(loadingMore?.canLoadMore == true)
        #expect(loaded?.isLoadingMore == false)
        #expect(loadingMore?.isLoadingMore == true)
        #expect(retry?.loadMoreError == .transportFailure)
    }

    @Test(arguments: [
        (progress: 65, duration: 600, expected: "1:05/10:00"),
        (progress: 3_661, duration: 7_322, expected: "1:01:01/2:02:02"),
        (progress: 0, duration: 0, expected: "0:00/0:00"),
        (progress: 600, duration: 600, expected: completedText)
    ])
    func progressShowsElapsedDurationOrCompletedState(
        progress: Int,
        duration: Int,
        expected: String
    ) {
        #expect(
            LibraryCardFormatting.progress(
                progressSeconds: progress,
                durationSeconds: duration
            ) == expected
        )
    }

    /// 今天、昨天的写法来自 `DateFormatter` 的相对日期，它只认设备当前的日期，所以这里以真实的今天为基准、时刻固定；
    /// 时区固定为东京，东京 8:00 在 UTC 仍是前一天，必须按日历时区归入今天。
    @Test(arguments: [
        (dayOffset: 0, hour: 9, minute: 5, expected: "今天 09:05"),
        (dayOffset: 0, hour: 8, minute: 0, expected: "今天 08:00"),
        (dayOffset: -1, hour: 23, minute: 59, expected: "昨天 23:59"),
        (dayOffset: -1, hour: 22, minute: 7, expected: "昨天 22:07")
    ])
    func todayAndYesterdayUseSystemRelativeDays(
        dayOffset: Int,
        hour: Int,
        minute: Int,
        expected: String
    ) throws {
        let today = tokyoCalendar.startOfDay(for: .now)
        let now = try #require(tokyoCalendar.date(byAdding: .hour, value: 23, to: today))
        let viewedAt = try #require(
            tokyoCalendar.date(
                byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute),
                to: today
            )
        )

        #expect(timestamp(viewedAt, now: now) == expected)
    }

    /// 更早的日期带时刻：同年只有月日，跨年带年份；年界按日历时区判定。
    @Test(arguments: [
        (date: (2026, 7, 20, 8, 3), now: (2026, 7, 24, 13), expected: "7月20日 08:03"),
        (date: (2025, 12, 30, 8, 0), now: (2026, 1, 1, 10), expected: "2025年12月30日 08:00"),
        (date: (2026, 1, 1, 9, 0), now: (2026, 12, 31, 20), expected: "1月1日 09:00")
    ])
    func earlierDatesShowMonthDayAndYearAcrossYears(
        date: (Int, Int, Int, Int, Int),
        now: (Int, Int, Int, Int),
        expected: String
    ) throws {
        let viewedAt = try #require(
            tokyoCalendar.date(
                from: DateComponents(
                    year: date.0,
                    month: date.1,
                    day: date.2,
                    hour: date.3,
                    minute: date.4
                )
            )
        )
        let now = try #require(
            tokyoCalendar.date(
                from: DateComponents(year: now.0, month: now.1, day: now.2, hour: now.3)
            )
        )

        #expect(timestamp(viewedAt, now: now) == expected)
    }

    private func timestamp(_ date: Date, now: Date) -> String {
        LibraryCardFormatting.timestamp(
            date,
            now: now,
            calendar: tokyoCalendar,
            locale: Locale(identifier: "zh-Hans")
        )
    }
}

private let tokyoCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
    return calendar
}()

private let completedText = localized("已看完")

private func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: LibraryFeatureStrings.bundle)
}
