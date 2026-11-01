import BiliModels
import BiliUI
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 竖向视频行的数据行：空间投稿是播放、弹幕与日期，相关推荐以 UP 主开头、没有日期。
///
/// 文字随测试机的资源语言变化；这里固定的是组合与省略规则，具体文案由各格式化工具的测试固定。
struct VideoRowPresentationTests {
    @Test
    func metadataJoinsViewsDanmakuAndDate() throws {
        let locale = try resourceLocale()
        let video = video(viewCount: 123_456, danmakuCount: 3_000, durationSeconds: 754)

        let row = VideoRowPresentation(video: video, locale: locale)

        #expect(row.durationText == "12:34")
        #expect(
            row.metadataText
                == [
                    VideoMetadataFormatting.viewCountText(123_456, locale: locale),
                    VideoMetadataFormatting.danmakuCountText(3_000, locale: locale),
                    VideoMetadataFormatting.publishedDate(video.publishedAt, locale: locale)
                ].joined(separator: " · ")
        )
        #expect(!row.isCollaboration)
        #expect(!row.accessibilityLabel.contains(row.collaborationText))
    }

    @Test
    func hiddenStatisticsAndDurationAreOmitted() throws {
        let locale = try resourceLocale()
        let video = video(viewCount: nil, danmakuCount: nil, durationSeconds: nil)

        let row = VideoRowPresentation(video: video, locale: locale)

        #expect(row.durationText == nil)
        #expect(
            row.metadataText
                == VideoMetadataFormatting.publishedDate(video.publishedAt, locale: locale)
        )
    }

    @Test
    func collaborationIsMarkedAndAnnounced() throws {
        let locale = try resourceLocale()

        let row = VideoRowPresentation(
            video: video(viewCount: 1, danmakuCount: 1, durationSeconds: 60, isCollaboration: true),
            locale: locale
        )

        #expect(row.isCollaboration)
        #expect(
            row.collaborationText
                == String(localized: "合作", bundle: VideoDetailFeatureStrings.bundle)
        )
        #expect(row.accessibilityLabel.hasPrefix("标题"))
        #expect(row.accessibilityLabel.contains(row.collaborationText))
    }

    @Test
    func relatedVideoLeadsWithTheUploaderAndHasNoDate() throws {
        let locale = try resourceLocale()
        let row = VideoRowPresentation(
            video: RelatedVideo(
                bvid: "BV1Related",
                title: "推荐",
                coverURL: nil,
                ownerName: "某 UP 主",
                viewCount: 123_456,
                danmakuCount: 3_000,
                durationSeconds: 754
            ),
            locale: locale
        )

        #expect(row.bvid == "BV1Related")
        #expect(row.durationText == "12:34")
        #expect(
            row.metadataText
                == [
                    "某 UP 主",
                    VideoMetadataFormatting.viewCountText(123_456, locale: locale),
                    VideoMetadataFormatting.danmakuCountText(3_000, locale: locale)
                ].joined(separator: " · ")
        )
        #expect(!row.isCollaboration)
        #expect(row.accessibilityLabel.contains("某 UP 主"))
    }

    private func resourceLocale() throws -> Locale {
        Locale(
            identifier: try #require(VideoDetailFeatureStrings.bundle.preferredLocalizations.first)
        )
    }

    private func video(
        viewCount: Int64?,
        danmakuCount: Int64?,
        durationSeconds: Int?,
        isCollaboration: Bool = false
    ) -> UploaderVideo {
        UploaderVideo(
            bvid: "BV1FixtureA1",
            title: "标题",
            coverURL: nil,
            durationSeconds: durationSeconds,
            viewCount: viewCount,
            danmakuCount: danmakuCount,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isCollaboration: isCollaboration
        )
    }
}
