import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

struct RelatedVideoShelfTests {
    @Test
    func presentationMapsStableBVIDAndEveryVisibleSlot() {
        let presentation = RelatedVideoCardPresentation(
            video: RelatedVideo(
                bvid: "BV1Related",
                title: "示例推荐",
                coverURL: URL(string: "https://example.com/cover.webp"),
                ownerName: "示例 UP 主",
                viewCount: 123_456,
                danmakuCount: 7_890,
                durationSeconds: 754
            )
        )

        #expect(presentation.id == "BV1Related")
        #expect(presentation.title == "示例推荐")
        #expect(presentation.coverURL?.absoluteString == "https://example.com/cover.webp")
        #expect(presentation.ownerName == "示例 UP 主")
        #expect(presentation.viewCountText == "12.3万")
        #expect(presentation.danmakuCountText == "7890")
        #expect(presentation.durationText == "12:34")
        #expect(
            presentation.accessibilityLabel
                == ListFormatter.localizedString(
                    byJoining: [
                        "示例推荐",
                        "示例 UP 主",
                        BrowseFeatureStrings.localized("\("12.3万")播放"),
                        BrowseFeatureStrings.localized("\("7890")弹幕"),
                        BrowseFeatureStrings.localized("时长\("12:34")"),
                    ]
                )
        )
        #expect(RelatedVideoShelfState.loaded([presentation]).itemCount == 1)
    }

    @Test
    func presentationHidesMissingDurationWithoutInventingATrailingSlot() {
        let presentation = RelatedVideoCardPresentation(
            video: RelatedVideo(
                bvid: "BV1NoDuration",
                title: "无时长推荐",
                coverURL: nil,
                ownerName: "作者",
                viewCount: 1,
                danmakuCount: 0,
                durationSeconds: nil
            )
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
