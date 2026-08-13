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

    public init(item: WatchHistoryItem) {
        let progress = WatchHistoryCardFormatting.progress(
            progressSeconds: item.progressSeconds,
            durationSeconds: item.durationSeconds
        )
        let viewedAt = WatchHistoryCardFormatting.viewedAt(item.viewedAt)
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
        accessibilityLabel = [
            item.title,
            item.owner.name,
            "观看进度 \(progress)",
            viewedAt,
        ].joined(separator: "，")
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
        durationSeconds: Int
    ) -> String {
        let duration = max(0, durationSeconds)
        let progress = min(max(0, progressSeconds), duration)
        if duration > 0, progress >= duration {
            return "已看完"
        }
        return "\(VideoDurationFormatting.string(seconds: progress))/"
            + VideoDurationFormatting.string(seconds: duration)
    }

    static func viewedAt(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(format: "今天 %02d:%02d", hour, minute)
        }
        if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: now
        ), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(format: "昨天 %02d:%02d", hour, minute)
        }

        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return String(
            format: "%d月%d日 %02d:%02d",
            month,
            day,
            hour,
            minute
        )
    }
}
