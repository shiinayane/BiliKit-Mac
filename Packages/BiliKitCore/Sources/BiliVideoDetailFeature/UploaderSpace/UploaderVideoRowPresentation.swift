import BiliModels
import BiliUI
import Foundation

/// 空间投稿列表一行的展示值，renderer 直接消费。
public struct UploaderVideoRowPresentation: Identifiable, Equatable, Sendable {
    public var id: String { bvid }

    public let bvid: String
    public let title: String
    /// 封面的请求地址：按投稿行封面宽度（`UploaderSpaceGeometry.coverWidth`）取的 B 站图片 CDN 缩略图。
    public let coverURL: URL?
    public let durationText: String?
    /// “12万播放 · 3000弹幕 · 3天前”；统计被隐藏时省略对应部分。
    public let metadataText: String
    public let isCollaboration: Bool
    public let collaborationText: String
    public let accessibilityLabel: String

    public init(video: UploaderVideo, locale: Locale = InterfaceLocale.current) {
        bvid = video.bvid
        title = video.title
        coverURL = BiliImageThumbnail.url(
            video.coverURL,
            size: .cover(pointWidth: UploaderSpaceGeometry.coverWidth)
        )
        durationText = video.durationSeconds.map {
            VideoDurationFormatting.string(seconds: $0, locale: locale)
        }
        let viewCountText = video.viewCount.map {
            VideoMetadataFormatting.viewCountText($0, locale: locale)
        }
        let danmakuCountText = video.danmakuCount.map {
            VideoMetadataFormatting.danmakuCountText($0, locale: locale)
        }
        let publishedText = VideoMetadataFormatting.publishedDate(video.publishedAt, locale: locale)
        metadataText = [viewCountText, danmakuCountText, publishedText]
            .compactMap { $0 }
            .joined(separator: " · ")
        isCollaboration = video.isCollaboration
        collaborationText = VideoDetailFeatureStrings.localized("合作", locale: locale)

        var components = [video.title]
        if video.isCollaboration {
            components.append(collaborationText)
        }
        components += [viewCountText, danmakuCountText].compactMap { $0 }
        if let durationSeconds = video.durationSeconds {
            components.append(
                VideoCardAccessibilityText.duration(seconds: durationSeconds, locale: locale)
            )
        }
        components.append(publishedText)
        accessibilityLabel = ListFormatter.localizedString(byJoining: components)
    }
}
