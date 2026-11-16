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
        #expect(CardGridGeometry.video.columnCount(for: sample.width) == sample.columns)
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
            CardGridGeometry.video.isRenderableViewport(width: sample.width) == sample.renderable
        )
    }

    @Test
    func itemSizeAndContentHeightPreservePopularGridContract() {
        let size = CardGridGeometry.video.itemSize(for: 1_080)
        #expect(size.width == 243)
        #expect(size.height == 220)
        #expect(CardGridGeometry.video.contentHeight(for: 1_080, itemCount: 50) == 3_220)
        #expect(CardGridGeometry.video.contentHeight(for: 1_080, itemCount: 0) == 0)
        // 为悬浮页码条留出的高度只加在有内容时的末行下方。
        #expect(
            CardGridGeometry.video.contentHeight(for: 1_080, itemCount: 50, bottomInset: 60)
                == 3_280
        )
    }

    @Test(arguments: [
        // 窄窗口 2 列、常见窗口 4 列、大窗口 5 列；以下高度都露出末行的一部分，这一行也画。
        (width: CGFloat(760), height: CGFloat(650), count: 6),
        (width: 1_080, height: 760, count: 16),
        (width: 1_600, height: 1_000, count: 20),
        (width: 2_560, height: 1_440, count: 20),
        // 三整行之下只露出行间距：多画的第四行在视野外，不可见。
        (width: 1_080, height: 720, count: 16),
        // 高度不足一行仍画一行。
        (width: 1_080, height: 1, count: 4)
    ])
    func placeholderCountCoversTheVisibleArea(
        _ sample: (width: CGFloat, height: CGFloat, count: Int)
    ) {
        #expect(
            CardGridGeometry.video.placeholderCount(
                for: CGSize(width: sample.width, height: sample.height)
            ) == sample.count
        )
    }

    @Test
    func placeholderCountDrawsNoExtraRowForExactRowsAndCoversAPartialRow() {
        let width: CGFloat = 1_080
        let columns = CardGridGeometry.video.columnCount(for: width)
        let rowHeight = CardGridGeometry.video.itemSize(for: width).height
        let threeRows =
            CardGridGeometry.topContentPadding
            + rowHeight * 3
            + CardGridGeometry.video.verticalSpacing * 2
        #expect(
            CardGridGeometry.video.placeholderCount(for: CGSize(width: width, height: threeRows))
                == columns * 3
        )
        #expect(
            CardGridGeometry.video.placeholderCount(
                for: CGSize(
                    width: width,
                    height: threeRows + CardGridGeometry.video.verticalSpacing + rowHeight / 2
                )
            ) == columns * 4
        )
    }

    @Test(arguments: [
        CGSize(width: 0, height: 0),
        CGSize(width: 1_080, height: 0),
        CGSize(width: 1_080, height: -1),
        CGSize(width: 69, height: 720),
        CGSize(width: 1_080, height: .infinity),
        CGSize(width: .infinity, height: 720),
        CGSize(width: .nan, height: 720),
        CGSize(width: 1_080, height: .nan)
    ])
    func placeholderCountIsZeroWithoutARenderableViewport(_ size: CGSize) {
        #expect(CardGridGeometry.video.placeholderCount(for: size) == 0)
    }

    @Test(arguments: [
        // 不知道条数时铺满；已知条数少于铺满张数时取条数，多于时仍只铺满；0 与负数不画。
        (expected: Int?.none, count: 16),
        (expected: 5, count: 5),
        (expected: 40, count: 16),
        (expected: 0, count: 0),
        (expected: -3, count: 0)
    ])
    func placeholderCountNeverExceedsTheKnownPageItemCount(
        _ sample: (expected: Int?, count: Int)
    ) {
        #expect(
            CardGridGeometry.video.placeholderCount(
                for: CGSize(width: 1_080, height: 760),
                expectedItemCount: sample.expected
            ) == sample.count
        )
    }

    @Test(arguments: [CGFloat.zero, 1, 48, 67])
    func provisionalWidthsStillProducePositiveCards(_ width: CGFloat) {
        let size = CardGridGeometry.video.itemSize(for: width)
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
