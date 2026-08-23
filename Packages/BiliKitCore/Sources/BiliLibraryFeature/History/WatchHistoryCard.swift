import BiliModels
import BiliUI
import Foundation

/// History 拥有格式化和真实 AX 文案；平台 renderer 只消费这些已格式化 slot。
public struct WatchHistoryCardPresentation: Sendable, Equatable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let showsAvatar: Bool
    public let progressText: String
    public let footerLeadingText: String
    public let footerTrailingText: String
    public let accessibilityLabel: String

    public init(item: WatchHistoryItem, locale: Locale = .current) {
        let progress = WatchHistoryCardFormatting.progress(
            progressSeconds: item.progressSeconds,
            durationSeconds: item.durationSeconds,
            locale: locale
        )
        let viewedAt = WatchHistoryCardFormatting.viewedAt(item.viewedAt, locale: locale)
        bvid = item.bvid
        title = item.title
        coverURL = optimizedHistoryImageURL(
            item.coverURL,
            width: 640,
            height: 360
        )
        avatarURL = optimizedHistoryImageURL(
            item.owner.avatarURL,
            width: 96,
            height: 96
        )
        showsAvatar = item.owner.avatarURL != nil
        progressText = progress
        footerLeadingText = item.owner.name
        footerTrailingText = viewedAt
        accessibilityLabel = ListFormatter.localizedString(
            byJoining: [
                item.title,
                item.owner.name,
                LibraryFeatureStrings.localized("观看进度 \(progress)", locale: locale),
                viewedAt,
            ]
        )
    }
}

private func optimizedHistoryImageURL(
    _ url: URL?,
    width: Int,
    height: Int
) -> URL? {
    guard let url,
        let host = url.host?.lowercased(),
        host == "hdslb.com" || host.hasSuffix(".hdslb.com"),
        url.query == nil,
        url.fragment == nil,
        !url.path.contains("@")
    else {
        return url
    }
    var components = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false
    )
    components?.path += "@\(width)w_\(height)h_1c.webp"
    return components?.url ?? url
}

enum WatchHistoryCardFormatting {
    static func progress(
        progressSeconds: Int,
        durationSeconds: Int,
        locale: Locale = .current
    ) -> String {
        let duration = max(0, durationSeconds)
        let progress = min(max(0, progressSeconds), duration)
        if duration > 0, progress >= duration {
            return LibraryFeatureStrings.localized("已看完", locale: locale)
        }
        return "\(VideoDurationFormatting.string(seconds: progress))/"
            + VideoDurationFormatting.string(seconds: duration)
    }

    static func viewedAt(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = formatted(
            date,
            date: .omitted,
            time: .shortened,
            calendar: calendar,
            locale: locale
        )
        if calendar.isDate(date, inSameDayAs: now) {
            return LibraryFeatureStrings.localized("今天 \(time)", locale: locale)
        }
        if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: now
        ), calendar.isDate(date, inSameDayAs: yesterday) {
            return LibraryFeatureStrings.localized("昨天 \(time)", locale: locale)
        }

        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return LibraryFeatureStrings.localized(
            "\(month)月\(day)日 \(time)",
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
