import BiliModels
import BiliUI
import Foundation

/// 热门卡片的已格式化文字、缩略图地址与读屏标签，由 `PopularNativeGridView` 映射为原生卡片。
///
/// 计数、时长与日期的格式取自 BiliUI，图片地址经 `BiliImageThumbnail` 改写为缩略地址；
/// 渲染侧不再格式化。
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
    public let accessibilityLabel: String

    public init(video: PopularVideo, locale: Locale = InterfaceLocale.current) {
        bvid = video.bvid
        title = video.title
        coverURL = BiliImageThumbnail.url(video.coverURL, size: .videoCover)
        avatarURL = BiliImageThumbnail.url(video.owner.avatarURL, size: .avatar)
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
        let publishedDateText = VideoMetadataFormatting.publishedDate(
            video.publishedAt,
            locale: locale
        )
        footerText = "\(video.owner.name) · \(publishedDateText)"
        accessibilityLabel = videoCardAccessibilityLabel(
            title: video.title,
            ownerName: video.owner.name,
            viewCountText: viewCountText,
            danmakuCountText: danmakuCountText,
            durationSeconds: video.durationSeconds,
            publishedDateText: publishedDateText,
            locale: locale
        )
    }
}

/// 首页推荐卡片的已格式化文字、缩略图地址与读屏标签；另带推荐理由，由 `RecommendedNativeGridView`
/// 显示为页脚胶囊。
///
/// App 端推荐的计数与发布时间可能解析不出：缺失的计数为 nil（封面不显示这一项），没有发布时间时页脚只有 UP 主名；
/// 读屏标签同样跳过缺项。
public struct RecommendedVideoCardPresentation: Sendable, Equatable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let ownerName: String
    public let viewCountText: String?
    public let danmakuCountText: String?
    public let durationText: String
    public let footerText: String
    public let recommendationReason: String?
    public let accessibilityLabel: String

    public init(video: RecommendedVideo, locale: Locale = InterfaceLocale.current) {
        bvid = video.bvid
        title = video.title
        coverURL = BiliImageThumbnail.url(video.coverURL, size: .videoCover)
        avatarURL = BiliImageThumbnail.url(video.owner.avatarURL, size: .avatar)
        ownerName = video.owner.name
        viewCountText = video.viewCount.map {
            VideoMetadataFormatting.compactCount($0, locale: locale)
        }
        danmakuCountText = video.danmakuCount.map {
            VideoMetadataFormatting.compactCount($0, locale: locale)
        }
        durationText = VideoDurationFormatting.string(
            seconds: video.durationSeconds
        )
        let publishedDateText = video.publishedAt.map {
            VideoMetadataFormatting.publishedDate($0, locale: locale)
        }
        footerText = publishedDateText.map { "\(video.owner.name) · \($0)" } ?? video.owner.name
        recommendationReason = video.recommendationReason
        accessibilityLabel = videoCardAccessibilityLabel(
            title: video.title,
            ownerName: video.owner.name,
            viewCountText: viewCountText,
            danmakuCountText: danmakuCountText,
            durationSeconds: video.durationSeconds,
            publishedDateText: publishedDateText,
            recommendationReason: video.recommendationReason,
            locale: locale
        )
    }
}

/// 搜索结果卡片的已格式化文字、缩略图地址与读屏标签；搜索结果可能没有时长，
/// 此时 `durationText` 为 nil，封面不显示时长。
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

    public init(video: SearchVideo, locale: Locale = InterfaceLocale.current) {
        bvid = video.bvid
        title = video.title
        coverURL = BiliImageThumbnail.url(video.coverURL, size: .videoCover)
        avatarURL = BiliImageThumbnail.url(video.owner.avatarURL, size: .avatar)
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
        accessibilityLabel = videoCardAccessibilityLabel(
            title: video.title,
            ownerName: video.owner.name,
            viewCountText: viewCountText,
            danmakuCountText: danmakuCountText,
            durationSeconds: video.durationSeconds,
            publishedDateText: publishedDateText,
            locale: locale
        )
    }
}

/// 推荐、热门与搜索卡片共用的 VoiceOver 标签：读出卡片上可见的全部信息。
///
/// 缺失的计数与发布时间（App 端推荐可能解析不出）不进标签。
private func videoCardAccessibilityLabel(
    title: String,
    ownerName: String,
    viewCountText: String?,
    danmakuCountText: String?,
    durationSeconds: Int?,
    publishedDateText: String?,
    recommendationReason: String? = nil,
    locale: Locale
) -> String {
    ListFormatter.localizedString(
        byJoining: [
            title,
            ownerName,
            viewCountText.map {
                BrowseFeatureStrings.localized("播放 \($0)", locale: locale)
            },
            danmakuCountText.map {
                BrowseFeatureStrings.localized("弹幕 \($0)", locale: locale)
            },
            durationSeconds.map {
                VideoCardAccessibilityText.duration(seconds: $0, locale: locale)
            },
            publishedDateText.map {
                BrowseFeatureStrings.localized("发布 \($0)", locale: locale)
            },
            recommendationReason.map {
                BrowseFeatureStrings.localized("推荐理由 \($0)", locale: locale)
            }
        ].compactMap { $0 }
    )
}
