import Foundation
import Testing

@testable import BiliBrowseFeature

struct CommentPresentationFormattingTests {
    @Test
    func replyPageCountIsOverflowSafeAndNeverBelowOne() {
        #expect(CommentPresentationFormatting.pageCount(totalCount: 0, pageSize: 10) == 1)
        #expect(CommentPresentationFormatting.pageCount(totalCount: 12, pageSize: 10) == 2)
        #expect(
            CommentPresentationFormatting.pageCount(
                totalCount: Int.max,
                pageSize: 10
            ) > 0
        )
    }
}
