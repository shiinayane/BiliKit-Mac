import BiliModels
import Foundation
import Testing

@testable import BiliPlayback

struct WebVTTEncoderTests {
    @Test
    func encodesNonZeroPresentationTimeAndEscapesCueMarkup() throws {
        let data = try WebVTTEncoder().encode(
            cues: [
                SubtitleCue(
                    startSeconds: 1.25,
                    endSeconds: 2.5,
                    text: "A < B & C > D\n\n下一行"
                )
            ],
            earliestPresentationTime: 250,
            timescale: 3_000
        )
        let body = try #require(String(data: data, encoding: .utf8))

        #expect(
            body.contains(
                "X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:7500"
            )
        )
        #expect(body.contains("00:00:01.250 --> 00:00:02.500"))
        #expect(body.contains("A &lt; B &amp; C &gt; D\n \n下一行"))
    }

    @Test
    func rejectsOutOfOrderOrUnsafeCues() throws {
        #expect(throws: WebVTTEncoderError.invalidCue(index: 1)) {
            try WebVTTEncoder().encode(
                cues: [
                    SubtitleCue(startSeconds: 2, endSeconds: 3, text: "later"),
                    SubtitleCue(startSeconds: 1, endSeconds: 2, text: "earlier"),
                ],
                earliestPresentationTime: 0,
                timescale: 1
            )
        }
        #expect(throws: WebVTTEncoderError.unsafeCueText(index: 0)) {
            try WebVTTEncoder().encode(
                cues: [
                    SubtitleCue(
                        startSeconds: 0,
                        endSeconds: 1,
                        text: "unsafe\u{0000}"
                    )
                ],
                earliestPresentationTime: 0,
                timescale: 1
            )
        }
    }

    @Test
    func rejectsTimestampOverflow() {
        #expect(throws: WebVTTEncoderError.timestampOverflow) {
            try WebVTTEncoder().encode(
                cues: [],
                earliestPresentationTime: .max,
                timescale: 1
            )
        }
    }
}
