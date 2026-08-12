import Testing

@testable import BiliBrowseFeature

struct VideoPlaybackViewTests {
    @Test
    func detailScrollResetsOnlyForAReplacementPresentedBVID() {
        #expect(
            !PlaybackDetailScrollResetPolicy.shouldReset(
                from: nil,
                to: "BV1Initial"
            )
        )
        #expect(
            PlaybackDetailScrollResetPolicy.shouldReset(
                from: "BV1A",
                to: "BV1B"
            )
        )
        #expect(
            !PlaybackDetailScrollResetPolicy.shouldReset(
                from: "BV1A",
                to: "BV1A"
            )
        )
        #expect(
            !PlaybackDetailScrollResetPolicy.shouldReset(
                from: "BV1A",
                to: nil
            )
        )
    }
}
