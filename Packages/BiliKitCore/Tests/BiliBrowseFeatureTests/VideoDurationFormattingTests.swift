import BiliUI
import Foundation
import Testing

struct VideoDurationFormattingTests {
    @Test(
        arguments: ["zh_CN", "ja_JP", "en_US"],
        [
            (0, "0:00"),
            (1, "0:01"),
            (9, "0:09"),
            (59, "0:59"),
            (60, "1:00"),
            (61, "1:01"),
            (599, "9:59"),
            (3_599, "59:59"),
            (3_600, "1:00:00"),
            (3_661, "1:01:01"),
            (359_999, "99:59:59"),
            (360_000, "100:00:00")
        ]
    )
    func nonnegativeDurationsPreserveProductClockFormatAcrossLocales(
        localeIdentifier: String,
        expectation: (seconds: Int, text: String)
    ) {
        #expect(
            VideoDurationFormatting.string(
                seconds: expectation.seconds,
                locale: Locale(identifier: localeIdentifier)
            ) == expectation.text
        )
    }
}
