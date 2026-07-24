import BiliModels
import BiliUI
import Foundation
import SwiftUI

struct GuestVideoCard: View {
    private let title: String
    private let coverURL: URL?
    private let ownerName: String
    private let ownerAvatarURL: URL?
    private let viewCount: Int64
    private let danmakuCount: Int64
    private let durationSeconds: Int?
    private let publishedAt: Date
    private let isSelected: Bool

    init(video: PopularVideo, isSelected: Bool) {
        title = video.title
        coverURL = Self.optimizedBiliImageURL(
            video.coverURL,
            width: 640,
            height: 360
        )
        ownerName = video.owner.name
        ownerAvatarURL = Self.optimizedBiliImageURL(
            video.owner.avatarURL,
            width: 96,
            height: 96
        )
        viewCount = video.statistics.viewCount
        danmakuCount = video.statistics.danmakuCount
        durationSeconds = video.durationSeconds
        publishedAt = video.publishedAt
        self.isSelected = isSelected
    }

    init(video: SearchVideo, isSelected: Bool) {
        title = video.title
        coverURL = Self.optimizedBiliImageURL(
            video.coverURL,
            width: 640,
            height: 360
        )
        ownerName = video.owner.name
        ownerAvatarURL = Self.optimizedBiliImageURL(
            video.owner.avatarURL,
            width: 96,
            height: 96
        )
        viewCount = video.statistics.viewCount
        danmakuCount = video.statistics.danmakuCount
        durationSeconds = video.durationSeconds
        publishedAt = video.publishedAt
        self.isSelected = isSelected
    }

    var body: some View {
        VideoCard(
            coverURL: coverURL,
            avatarURL: ownerAvatarURL,
            showsAvatar: true,
            title: title,
            coverMetrics: [
                VideoCardMetric(
                    GuestVideoCardFormatting.compactCount(viewCount),
                    systemImage: "play.fill"
                ),
                VideoCardMetric(
                    GuestVideoCardFormatting.compactCount(danmakuCount),
                    systemImage: "text.bubble.fill"
                ),
            ],
            coverTrailingText: durationSeconds.map(Self.duration),
            footerLeadingText: "\(ownerName) · "
                + GuestVideoCardFormatting.publishedDate(publishedAt),
            isSelected: isSelected
        )
    }

    private static func optimizedBiliImageURL(
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

    private static func duration(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

enum GuestVideoCardFormatting {
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
