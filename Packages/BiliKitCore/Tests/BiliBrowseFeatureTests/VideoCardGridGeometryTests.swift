import BiliUI
import Foundation
import Testing

/// 原生网格与加载骨架共用的几何契约。
struct VideoCardGridGeometryTests {
    @Test(arguments: [
        (width: CGFloat(760), columns: 2),
        (width: 1_080, columns: 4),
        (width: 1_600, columns: 5),
        (width: 5_000, columns: 5),
        (width: 0, columns: 2)
    ])
    func columnCountStaysWithinTwoToFiveColumns(_ sample: (width: CGFloat, columns: Int)) {
        #expect(VideoCardGridGeometry.columnCount(for: sample.width) == sample.columns)
    }

    @Test(arguments: [
        (width: CGFloat(0), renderable: false),
        (width: 69, renderable: false),
        (width: 70, renderable: true),
        (width: 760, renderable: true),
        (width: .infinity, renderable: false),
        (width: .nan, renderable: false)
    ])
    func renderableViewportRequiresRoomForTwoColumns(
        _ sample: (width: CGFloat, renderable: Bool)
    ) {
        #expect(
            VideoCardGridGeometry.isRenderableViewport(width: sample.width) == sample.renderable
        )
    }

    @Test
    func itemSizeAndContentHeightPreservePopularGridContract() {
        let size = VideoCardGridGeometry.itemSize(for: 1_080)
        #expect(size.width == 243)
        #expect(size.height == 220)
        #expect(VideoCardGridGeometry.contentHeight(for: 1_080, itemCount: 50) == 3_220)
        #expect(VideoCardGridGeometry.contentHeight(for: 1_080, itemCount: 0) == 0)
    }

    @Test(arguments: [CGFloat.zero, 1, 48, 67])
    func provisionalWidthsStillProducePositiveCards(_ width: CGFloat) {
        let size = VideoCardGridGeometry.itemSize(for: width)
        #expect(size.width >= 1)
        #expect(size.height >= VideoCardGeometry.textAreaHeight)
    }

    @Test(arguments: [
        (width: CGFloat(224), height: CGFloat(210)),
        (width: 243, height: 220)
    ])
    func cardHeightIsSixteenByNineCoverPlusTextArea(
        _ sample: (width: CGFloat, height: CGFloat)
    ) {
        #expect(VideoCardGeometry.height(forWidth: sample.width) == sample.height)
    }
}
