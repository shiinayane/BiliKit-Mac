import CoreGraphics
import Testing

@testable import BiliVideoDetailFeature

/// 播放页分栏照 B 站 iPad 端：只看工具栏下方区域的宽高比切换双栏与单栏（进出各一个阈值，中间保持原状）；双栏时
/// 左列占固定比例、视频 16:9 撑满列宽并从工具栏下方开始，详情在视频下方，右栏占满剩余宽度并延伸到工具栏底下；单栏时
/// 视频撑满宽度，分页条下方是详情或右栏同一块区域。
struct PlaybackPageGeometryTests {
    @Test(arguments: [
        (CGSize(width: 1400, height: 1000), PlaybackPageColumns.single, PlaybackPageColumns.two),
        (CGSize(width: 1370, height: 1000), PlaybackPageColumns.single, PlaybackPageColumns.single),
        (CGSize(width: 1360, height: 1000), PlaybackPageColumns.two, PlaybackPageColumns.two),
        (CGSize(width: 1330, height: 1000), PlaybackPageColumns.two, PlaybackPageColumns.single),
        (CGSize.zero, PlaybackPageColumns.two, PlaybackPageColumns.two)
    ])
    func columnsFollowTheAspectRatioWithHysteresis(
        size: CGSize,
        current: PlaybackPageColumns,
        expected: PlaybackPageColumns
    ) {
        #expect(PlaybackPageGeometry.columns(for: size, current: current) == expected)
    }

    @Test
    func twoColumnsPutTheVideoAndDetailsLeftAndTheSideColumnRight() {
        let size = CGSize(width: 1272, height: 949)
        let frames = PlaybackPageGeometry.frames(for: size, topInset: 52, columns: .two)

        #expect(frames.video == CGRect(x: 0, y: 52, width: 806, height: 453))
        #expect(frames.details.minY == frames.video.maxY + PlaybackPageGeometry.separatorThickness)
        #expect(frames.details.width == frames.video.width)
        #expect(frames.details.maxY == size.height)
        #expect(frames.side.minX == frames.video.maxX + PlaybackPageGeometry.separatorThickness)
        #expect(frames.side.maxX == size.width)
        #expect(frames.side.minY == 0)
        #expect(frames.side.height == size.height)
        #expect(frames.columnSeparator.minX == frames.video.maxX)
        #expect(frames.columnSeparator.height == size.height)
        #expect(frames.tabBar.height == 0)
    }

    @Test
    func singleColumnStacksVideoTabBarAndOneSharedContentArea() {
        let size = CGSize(width: 1000, height: 952)
        let frames = PlaybackPageGeometry.frames(for: size, topInset: 52, columns: .single)

        #expect(frames.video == CGRect(x: 0, y: 52, width: 1000, height: 563))
        #expect(frames.tabBar.minY == frames.video.maxY)
        #expect(frames.tabBar.height == PlaybackPageGeometry.singleColumnTabBarHeight)
        #expect(frames.details == frames.side)
        #expect(frames.details.minY == frames.tabBar.maxY + PlaybackPageGeometry.separatorThickness)
        #expect(frames.details.maxY == size.height)
        #expect(frames.columnSeparator == .zero)
    }

    @Test
    func columnsAreJudgedBelowTheToolbar() {
        let content = PlaybackPageGeometry.contentSize(
            for: CGSize(width: 1400, height: 1052),
            topInset: 52
        )

        #expect(content == CGSize(width: 1400, height: 1000))
        #expect(PlaybackPageGeometry.columns(for: content, current: .single) == .two)
    }

    /// 极矮的页面里视频也不超出页面，下方区域高度不为负。
    @Test(arguments: [PlaybackPageColumns.two, .single])
    func shortPagesNeverProduceNegativeAreas(columns: PlaybackPageColumns) {
        let size = CGSize(width: 1600, height: 200)
        let frames = PlaybackPageGeometry.frames(for: size, topInset: 52, columns: columns)

        #expect(frames.video.maxY <= size.height)
        #expect(frames.details.height >= 0)
        #expect(frames.side.height >= 0)
    }
}
