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
                    VideoMetadataFormatting.compactCount(viewCount),
                    systemImage: "play.fill"
                ),
                VideoCardMetric(
                    VideoMetadataFormatting.compactCount(danmakuCount),
                    systemImage: "text.bubble.fill"
                ),
            ],
            coverTrailingText: durationSeconds.map(Self.duration),
            footerLeadingText: "\(ownerName) · "
                + VideoMetadataFormatting.publishedDate(publishedAt),
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
