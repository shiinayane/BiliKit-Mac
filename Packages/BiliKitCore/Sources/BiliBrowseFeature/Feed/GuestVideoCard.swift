import BiliModels
import BiliUI
import Foundation

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

public struct SearchVideoCardPresentation: Sendable, Equatable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let ownerName: String
    public let viewCountText: String
    public let danmakuCountText: String
    public let durationText: String?
    public let footerText: String
    public let accessibilityLabel: String

    public init(video: SearchVideo) {
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
        durationText = video.durationSeconds.map {
            VideoDurationFormatting.string(seconds: $0)
        }
        let publishedDateText = VideoMetadataFormatting.publishedDate(
            video.publishedAt
        )
        footerText = "\(video.owner.name) · \(publishedDateText)"
        accessibilityLabel = [
            video.title,
            video.owner.name,
            "播放 \(viewCountText)",
            "弹幕 \(danmakuCountText)",
            durationText.map { "时长 \($0)" },
            "发布 \(publishedDateText)",
        ]
        .compactMap { $0 }
        .joined(separator: "，")
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
