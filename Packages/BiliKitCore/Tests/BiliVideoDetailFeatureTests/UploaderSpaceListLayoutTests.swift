import AppKit
import BiliModels
import Testing

@testable import BiliVideoDetailFeature

/// UP 主空间列表的头部随列表宽度重新布局。
struct UploaderSpaceListLayoutTests {
    /// 空间层进场时列表可能先以很窄的中间宽度布局；变宽后头部必须跟着重新布局。
    ///
    /// 没有投稿行时没有别的更新会顺带重算布局，头部停在旧宽度会让排序挤出屏幕、名字宽度为零。
    @Test @MainActor
    func headerFollowsTheListWidthAfterAnInterimNarrowLayout() throws {
        let list = UploaderSpaceListFixture(rows: [], listWidth: 120)
        let scrollView = list.controller.scrollView

        scrollView.frame.size.width = 420
        list.container.layoutSubtreeIfNeeded()

        let collectionView = try #require(scrollView.documentView as? NSCollectionView)
        let header = try #require(collectionView.item(at: IndexPath(item: 0, section: 0)))
        let expectedWidth =
            collectionView.bounds.width - UploaderSpaceGeometry.listHorizontalInset * 2
        #expect(expectedWidth > 300)
        #expect(abs(header.view.frame.width - expectedWidth) < 1)
        let picker = try #require(
            header.view.subviews.compactMap { $0 as? NSSegmentedControl }.first
        )
        let name = try #require(
            header.view.subviews.compactMap { $0 as? NSTextField }.first {
                $0.stringValue == "UP 主"
            }
        )
        #expect(picker.frame.minX > name.frame.minX)
        #expect(picker.frame.maxX <= header.view.bounds.width)
        #expect(name.frame.width > 0)
        list.controller.tearDown()
    }
}
