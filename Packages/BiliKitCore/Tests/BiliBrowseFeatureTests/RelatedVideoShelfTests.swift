import Foundation
import Testing

@testable import BiliBrowseFeature

struct RelatedVideoShelfTests {
    @Test
    func itemIdentityIsTheReplacementBVID() {
        let item = RelatedVideoShelfItem(
            bvid: "BV1Related",
            title: "示例推荐",
            coverURL: URL(string: "https://example.com/cover.webp"),
            ownerName: "示例 UP 主",
            viewCount: 123_456,
            danmakuCount: 7_890,
            durationSeconds: 754
        )

        #expect(item.id == "BV1Related")
        #expect(RelatedVideoShelfState.loaded([item]).itemCount == 1)
        #expect(RelatedVideoShelfState.loading.itemCount == 0)
        #expect(RelatedVideoShelfState.empty.itemCount == 0)
        #expect(RelatedVideoShelfState.failure.itemCount == 0)
    }

    @Test
    func pagingAdvancesByTheVisibleCardCapacity() {
        let paging = RelatedVideoShelfPaging(
            itemCount: 8,
            cardWidth: 224,
            cardSpacing: 16,
            contentPadding: 40
        )

        #expect(
            paging.targetIndex(
                visibleIndices: [0, 1, 2],
                containerWidth: 784,
                direction: .forward
            ) == 3
        )
        #expect(
            paging.targetIndex(
                visibleIndices: [3, 4, 5],
                containerWidth: 784,
                direction: .forward
            ) == 6
        )
        #expect(
            paging.targetIndex(
                visibleIndices: [5, 6, 7],
                containerWidth: 784,
                direction: .backward
            ) == 2
        )
        #expect(
            paging.targetIndex(
                visibleIndices: [0, 1, 2],
                containerWidth: 784,
                direction: .backward
            ) == nil
        )
        #expect(
            paging.targetIndex(
                visibleIndices: [5, 6, 7],
                containerWidth: 784,
                direction: .forward
            ) == nil
        )
    }

    @Test
    func pagingStillMovesOneCardWhenTheViewportIsNarrow() {
        let paging = RelatedVideoShelfPaging(
            itemCount: 3,
            cardWidth: 224,
            cardSpacing: 16,
            contentPadding: 40
        )

        #expect(
            paging.targetIndex(
                visibleIndices: [0],
                containerWidth: 260,
                direction: .forward
            ) == 1
        )
    }
}
