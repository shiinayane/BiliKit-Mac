import BiliModels
import Foundation
import Testing

@testable import BiliUI
@testable import BiliVideoDetailFeature

/// 相关推荐卡片的展示值。
///
/// 封面上的计数与时长用紧凑格式，缺时长时不显示时长；读屏 label 读出每个可见项，时长读带单位的说法而不是封面上的
/// 「12:34」。
struct RelatedVideoShelfTests {
    @Test
    func presentationFillsAndReadsEveryVisibleSlot() {
        let locale = Locale(
            identifier: VideoDetailFeatureStrings.bundle.preferredLocalizations.first ?? "en"
        )
        let presentation = RelatedVideoCardPresentation(
            video: RelatedVideo(
                bvid: "BV1Related",
                title: "示例推荐",
                coverURL: URL(string: "https://example.com/cover.webp"),
                ownerName: "示例 UP 主",
                viewCount: 123_456,
                danmakuCount: 7_890,
                durationSeconds: 754
            ),
            locale: locale
        )

        #expect(
            presentation.viewCountText.hasPrefix(
                locale.language.languageCode?.identifier == "en" ? "123.4" : "12.3"
            )
        )
        #expect(
            presentation.danmakuCountText
                == (locale.language.languageCode?.identifier == "en" ? "7.8K" : "7890")
        )
        #expect(presentation.durationText == "12:34")
        for value in [
            presentation.title, presentation.ownerName, presentation.viewCountText,
            presentation.danmakuCountText
        ] {
            #expect(presentation.accessibilityLabel.contains(value))
        }
        // 读屏读带单位的时长，不读封面上会被当成时刻的「12:34」。
        #expect(
            presentation.accessibilityLabel.contains(
                VideoCardAccessibilityText.duration(seconds: 754, locale: locale)
            )
        )
        #expect(!presentation.accessibilityLabel.contains("12:34"))
    }

    @Test
    func presentationHidesMissingDurationWithoutInventingATrailingSlot() {
        let locale = Locale(
            identifier: VideoDetailFeatureStrings.bundle.preferredLocalizations.first ?? "en"
        )
        let presentation = RelatedVideoCardPresentation(
            video: RelatedVideo(
                bvid: "BV1NoDuration",
                title: "无时长推荐",
                coverURL: nil,
                ownerName: "作者",
                viewCount: 1,
                danmakuCount: 0,
                durationSeconds: nil
            ),
            locale: locale
        )

        #expect(presentation.durationText == nil)
    }
}
