import BiliModels
import BiliUI
import Foundation

/// 竖向视频列表一行的展示值（UP 主空间投稿、相关推荐），renderer 直接消费。
public struct VideoRowPresentation: Identifiable, Equatable, Sendable {
    public var id: String { bvid }

    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let durationText: String?
    /// 空间投稿是“12万播放 · 3000弹幕 · 3天前”，相关推荐是“UP 主 · 12万播放 · 3000弹幕”；统计被隐藏时省略对应部分。
    public let metadataText: String
    public let isCollaboration: Bool
    public let collaborationText: String
    public let accessibilityLabel: String

    public init(video: UploaderVideo, locale: Locale = InterfaceLocale.current) {
        bvid = video.bvid
        title = video.title
        coverURL = video.coverURL
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

    /// 相关推荐：数据行以 UP 主开头（推荐来自不同的 UP 主），没有发布日期；接口不标记合作投稿。
    public init(video: RelatedVideo, locale: Locale = InterfaceLocale.current) {
        bvid = video.bvid
        title = video.title
        coverURL = video.coverURL
        durationText = video.durationSeconds.map {
            VideoDurationFormatting.string(seconds: $0, locale: locale)
        }
        let viewCountText = VideoMetadataFormatting.viewCountText(video.viewCount, locale: locale)
        let danmakuCountText = VideoMetadataFormatting.danmakuCountText(
            video.danmakuCount,
            locale: locale
        )
        metadataText = [video.ownerName, viewCountText, danmakuCountText]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        isCollaboration = false
        collaborationText = VideoDetailFeatureStrings.localized("合作", locale: locale)

        var components = [video.title, video.ownerName, viewCountText, danmakuCountText]
        if let durationSeconds = video.durationSeconds {
            components.append(
                VideoCardAccessibilityText.duration(seconds: durationSeconds, locale: locale)
            )
        }
        accessibilityLabel = ListFormatter.localizedString(
            byJoining: components.filter { !$0.isEmpty }
        )
    }
}
