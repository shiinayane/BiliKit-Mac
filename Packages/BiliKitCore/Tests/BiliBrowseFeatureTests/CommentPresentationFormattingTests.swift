import Foundation
import Testing

@testable import BiliBrowseFeature

struct CommentPresentationFormattingTests {
    @Test
    func commentCountsReuseDomesticCompactUnits() {
        let locale = Locale(identifier: "zh-Hans")

        #expect(CommentPresentationFormatting.compactCount(9_999, locale: locale) == "9999")
        #expect(CommentPresentationFormatting.compactCount(12_345, locale: locale) == "1.2万")
        #expect(
            CommentPresentationFormatting.compactCount(Int64(12_843), locale: locale)
                == "1.2万"
        )
        #expect(
            CommentPresentationFormatting.compactCount(123_456_789, locale: locale)
                == "1.2亿"
        )
    }

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
