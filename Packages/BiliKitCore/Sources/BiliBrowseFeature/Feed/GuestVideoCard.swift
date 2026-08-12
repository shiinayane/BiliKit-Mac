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

    init(video: SearchVideo) {
        title = video.title
        coverURL = optimizedBiliImageURL(
            video.coverURL,
            width: 640,
            height: 360
        )
        ownerName = video.owner.name
        ownerAvatarURL = optimizedBiliImageURL(
            video.owner.avatarURL,
            width: 96,
            height: 96
        )
        viewCount = video.statistics.viewCount
        danmakuCount = video.statistics.danmakuCount
        durationSeconds = video.durationSeconds
        publishedAt = video.publishedAt
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
            coverTrailingText: durationSeconds.map {
                VideoDurationFormatting.string(seconds: $0)
            },
            footerLeadingText: "\(ownerName) · "
                + VideoMetadataFormatting.publishedDate(publishedAt)
        )
    }
}

public struct PopularVideoCardPresentation: Sendable, Equatable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let ownerName: String
    public let viewCountText: String
    public let danmakuCountText: String
    public let durationText: String
    public let footerText: String

    public init(video: PopularVideo) {
        bvid = video.bvid
        title = video.title
        coverURL = optimizedBiliImageURL(
            video.coverURL,
            width: 640,
            height: 360
        )
        avatarURL = optimizedBiliImageURL(
            video.owner.avatarURL,
            width: 96,
            height: 96
        )
        ownerName = video.owner.name
        viewCountText = VideoMetadataFormatting.compactCount(
            video.statistics.viewCount
        )
        danmakuCountText = VideoMetadataFormatting.compactCount(
            video.statistics.danmakuCount
        )
        durationText = VideoDurationFormatting.string(
            seconds: video.durationSeconds
        )
        footerText =
            "\(video.owner.name) · "
            + VideoMetadataFormatting.publishedDate(video.publishedAt)
    }
}

private func optimizedBiliImageURL(
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
