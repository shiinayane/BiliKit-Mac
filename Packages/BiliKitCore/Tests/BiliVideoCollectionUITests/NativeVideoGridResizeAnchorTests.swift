import AppKit
import BiliUI
import Testing

@testable import BiliVideoCollectionUI

/// 视口尺寸变化（含侧栏收起、展开动画中的连续变化）前后与其后的原地刷新中，网格的首张可见卡片不变；尺寸变化之后滚进
/// 近尾阈值仍会请求下一页；宽度只变半点（拖分隔条的一步）也按新卡片尺寸重排，不少排一列。
///
/// 每个测试都在 overlay 与传统滚动条下各跑一遍，结果不取决于运行机器的滚动条设置。
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct NativeVideoGridResizeAnchorTests {
    /// 侧栏收起、展开时细节栏的宽度：每步约一帧，跨过 2、3、4 列。
    private static let sidebarAnimationWidths: [CGFloat] = Array(
        stride(from: 800, through: 1_120, by: 20)
    )
    private nonisolated static let scrollerStyles: [NSScroller.Style] = [.overlay, .legacy]

    @Test(arguments: scrollerStyles)
    func continuousWidenThenNarrowKeepsTheFirstVisibleCard(
        scrollerStyle: NSScroller.Style
    ) async throws {
        let grid = try await GridHarness(scrollerStyle: scrollerStyle)
        grid.scroll(toLogicalOffset: 6_000)
        let original = try #require(grid.firstVisibleCard())

        for width in Self.sidebarAnimationWidths.dropFirst()
            + Self.sidebarAnimationWidths.reversed().dropFirst()
        {
            grid.setViewport(width: width)
            let card = try #require(grid.card(original.id))
            #expect(
                abs(card.offsetFromViewportTop - original.offsetFromViewportTop) <= 1,
                "宽度 \(width) 时首卡 \(original.id) 离开了视野顶部：原距离 \(original.offsetFromViewportTop)，现距离 \(card.offsetFromViewportTop)；\(grid.diagnostics)"
            )
        }
        #expect(grid.firstVisibleCard() == original, "\(grid.diagnostics)")
    }

    @Test(arguments: scrollerStyles)
    func narrowingNearTheEndReturnsToTheSameFirstVisibleCard(
        scrollerStyle: NSScroller.Style
    ) async throws {
        let grid = try await GridHarness(width: 1_120, scrollerStyle: scrollerStyle)
        grid.scroll(toLogicalOffset: grid.maximumLogicalOffset - 120)
        let original = try #require(grid.firstVisibleCard())

        for width in Self.sidebarAnimationWidths.reversed().dropFirst()
            + Self.sidebarAnimationWidths.dropFirst()
        {
            grid.setViewport(width: width)
        }
        #expect(grid.firstVisibleCard() == original, "\(grid.diagnostics)")
    }

    @Test(arguments: scrollerStyles)
    func heightChangeAtTheEndReturnsToTheSameFirstVisibleCard(
        scrollerStyle: NSScroller.Style
    ) async throws {
        let grid = try await GridHarness(scrollerStyle: scrollerStyle)
        grid.scroll(toLogicalOffset: grid.maximumLogicalOffset)
        let original = try #require(grid.firstVisibleCard())

        grid.setViewport(height: 1_000)
        grid.setViewport(height: GridHarness.defaultHeight)

        #expect(grid.firstVisibleCard() == original, "\(grid.diagnostics)")
    }

    @Test(arguments: scrollerStyles)
    func inPlaceRefreshAfterWidthChangeKeepsTheFirstVisibleCard(
        scrollerStyle: NSScroller.Style
    ) async throws {
        let grid = try await GridHarness(scrollerStyle: scrollerStyle)
        grid.scroll(toLogicalOffset: 6_000)
        let original = try #require(grid.firstVisibleCard())
        for width in Self.sidebarAnimationWidths.dropFirst() {
            grid.setViewport(width: width)
        }

        grid.replaceItems(with: (0..<10).map { "NEW\($0)" } + grid.ids)

        let card = try #require(grid.card(original.id))
        #expect(
            abs(card.offsetFromViewportTop - original.offsetFromViewportTop) <= 1,
            "\(grid.diagnostics)"
        )
    }

    /// 后一组是半点抖动：宽度变化不超过半点时不重排，其间在 layout 之外的追加照常重排。
    @Test(arguments: scrollerStyles, [(CGFloat(1_120), CGFloat(800)), (800.5, 799.5)])
    func scrollingIntoTheThresholdAfterResizingLoadsTheNextPage(
        scrollerStyle: NSScroller.Style,
        widths: (beforeAppend: CGFloat, afterAppend: CGFloat)
    ) async throws {
        let grid = try await GridHarness(scrollerStyle: scrollerStyle)
        grid.setViewport(width: widths.beforeAppend)
        grid.replaceItems(with: grid.ids + (300..<330).map { "BV\($0)" })
        grid.setViewport(width: widths.afterAppend)
        let requestsBeforeScrolling = grid.nearEndRequests

        grid.scroll(toLogicalOffset: grid.maximumLogicalOffset)

        #expect(grid.nearEndRequests == requestsBeforeScrolling + 1, "\(grid.diagnostics)")
    }

    // 988 与 987.5 分属两种卡片宽度：987.5 时旧卡片一行排不下 3 张；只用 overlay 滚动条，传统滚动条占掉的宽度
    // 会让分界落在别处。
    @Test
    func halfPointWidthChangeRelaysOutWithoutLosingAColumn() async throws {
        let wider: CGFloat = 988
        let narrower: CGFloat = 987.5
        try #require(
            NativeVideoGridGeometry.itemSize(for: wider).width
                != NativeVideoGridGeometry.itemSize(for: narrower).width
        )
        let grid = try await GridHarness(width: wider, scrollerStyle: .overlay)

        grid.setViewport(width: narrower)

        #expect(
            grid.firstRowCardCount() == NativeVideoGridGeometry.columnCount(for: narrower),
            "\(grid.diagnostics)"
        )
    }
}
