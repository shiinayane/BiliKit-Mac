import CoreGraphics
import Testing
@testable import BiliBrowseFeature

struct PlaybackPageLayoutTests {
    @Test
    func modeRequiresPagesAndUsesOneWideThreshold() {
        #expect(
            PlaybackPageLayout.mode(
                availableWidth: 870,
                pageCount: 0
            ) == nil
        )
        #expect(
            PlaybackPageLayout.mode(
                availableWidth: 1_100,
                pageCount: 1
            ) == .singlePart
        )
        #expect(
            PlaybackPageLayout.mode(
                availableWidth: 870,
                pageCount: 2
            ) == .compactParts
        )
        #expect(
            PlaybackPageLayout.mode(
                availableWidth: 1_100,
                pageCount: 2
            ) == .wideParts
        )
    }

    @Test
    func playerSizeKeepsSixteenByNineInsideContentPadding() {
        let size = PlaybackPageLayout.playerSize(availableWidth: 870)

        #expect(size.width == 790)
        #expect(size.height == 444.375)
        #expect(
            size.width / size.height
                == PlaybackPageLayout.playerAspectRatio
        )
        #expect(PlaybackPageLayout.horizontalContentPadding == 40)
        #expect(PlaybackPageLayout.verticalContentPadding == 24)
        #expect(PlaybackPageLayout.partsRailWidth == 400)
    }
}
