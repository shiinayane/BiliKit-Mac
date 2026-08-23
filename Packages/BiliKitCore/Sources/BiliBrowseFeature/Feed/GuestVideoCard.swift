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

    public init(video: PopularVideo, locale: Locale = .current) {
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
            video.statistics.viewCount,
            locale: locale
        )
        danmakuCountText = VideoMetadataFormatting.compactCount(
            video.statistics.danmakuCount,
            locale: locale
        )
        durationText = VideoDurationFormatting.string(
            seconds: video.durationSeconds
        )
        footerText =
            "\(video.owner.name) · "
            + VideoMetadataFormatting.publishedDate(video.publishedAt, locale: locale)
    }
}

public struct RecommendedVideoCardPresentation: Sendable, Equatable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let ownerName: String
    public let viewCountText: String
    public let danmakuCountText: String
    public let durationText: String
    public let footerText: String
    public let recommendationReason: String?

    public init(video: RecommendedVideo, locale: Locale = .current) {
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
            video.statistics.viewCount,
            locale: locale
        )
        danmakuCountText = VideoMetadataFormatting.compactCount(
            video.statistics.danmakuCount,
            locale: locale
        )
        durationText = VideoDurationFormatting.string(
            seconds: video.durationSeconds
        )
        footerText =
            "\(video.owner.name) · "
            + VideoMetadataFormatting.publishedDate(video.publishedAt, locale: locale)
        recommendationReason = video.recommendationReason
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

    public init(video: SearchVideo, locale: Locale = .current) {
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
            video.statistics.viewCount,
            locale: locale
        )
        danmakuCountText = VideoMetadataFormatting.compactCount(
            video.statistics.danmakuCount,
            locale: locale
        )
        durationText = video.durationSeconds.map {
            VideoDurationFormatting.string(seconds: $0)
        }
        let publishedDateText = VideoMetadataFormatting.publishedDate(
            video.publishedAt,
            locale: locale
        )
        footerText = "\(video.owner.name) · \(publishedDateText)"
        accessibilityLabel = ListFormatter.localizedString(
            byJoining: [
                video.title,
                video.owner.name,
                BrowseFeatureStrings.localized("播放 \(viewCountText)", locale: locale),
                BrowseFeatureStrings.localized("弹幕 \(danmakuCountText)", locale: locale),
                durationText.map {
                    BrowseFeatureStrings.localized("时长 \($0)", locale: locale)
                },
                BrowseFeatureStrings.localized("发布 \(publishedDateText)", locale: locale),
            ].compactMap { $0 }
        )
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
