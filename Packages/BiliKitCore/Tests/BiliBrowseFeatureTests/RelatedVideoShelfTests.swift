import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

struct RelatedVideoShelfTests {
    @Test
    func presentationMapsStableBVIDAndEveryVisibleSlot() {
        let locale = Locale(
            identifier: BrowseFeatureStrings.bundle.preferredLocalizations.first ?? "en"
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

        #expect(presentation.id == "BV1Related")
        #expect(presentation.title == "示例推荐")
        #expect(presentation.coverURL?.absoluteString == "https://example.com/cover.webp")
        #expect(presentation.ownerName == "示例 UP 主")
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
            presentation.danmakuCountText, presentation.durationText ?? "",
        ] {
            #expect(presentation.accessibilityLabel.contains(value))
        }
        #expect(RelatedVideoShelfState.loaded([presentation]).itemCount == 1)
    }

    @Test
    func presentationHidesMissingDurationWithoutInventingATrailingSlot() {
        let locale = Locale(
            identifier: BrowseFeatureStrings.bundle.preferredLocalizations.first ?? "en"
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
        #expect(!presentation.accessibilityLabel.contains("12:34"))
    }

    @Test
    func selectionForwardsOnlyTheReplacementBVID() {
        var selectedBVID: String?
        let selection = RelatedVideoShelfSelection { bvid in
            selectedBVID = bvid
        }

        selection.select("BV1Replacement")

        #expect(selectedBVID == "BV1Replacement")
    }
}
