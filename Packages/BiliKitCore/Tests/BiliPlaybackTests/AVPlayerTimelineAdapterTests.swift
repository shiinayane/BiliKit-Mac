@preconcurrency import AVFoundation
import BiliApplication
import Testing

@testable import BiliPlayback

struct AVPlayerTimelineAdapterTests {
    @Test
    @MainActor
    func playImmediatelyUsesValidatedDefaultRateWhileWaitingForMedia() {
        let player = AVPlayer()
        player.defaultRate = 1.5
        let timeline = AVPlayerTimelineAdapter(player: player)
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BV1RateFixture", cid: 101)
        )

        timeline.play()

        #expect(player.defaultRate == 1.5)
        #expect(player.rate == 1.5)
        #expect(player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        #expect(timeline.currentSnapshot.rate == 1.5)
        #expect(timeline.currentSnapshot.state == .playing)
    }

    @Test
    @MainActor
    func setRateWhilePausedOnlyChangesThePermanentDefaultRate() throws {
        let player = AVPlayer()
        let timeline = AVPlayerTimelineAdapter(player: player)

        try timeline.setRate(2)

        #expect(player.defaultRate == 2)
        #expect(player.rate == 0)
    }

    @Test
    @MainActor
    func setRateWhileWaitingChangesDefaultAndImmediatePlaybackRate() throws {
        let player = AVPlayer()
        let timeline = AVPlayerTimelineAdapter(player: player)
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BV1RateFixture", cid: 102)
        )
        timeline.play()

        try timeline.setRate(2)

        #expect(player.defaultRate == 2)
        #expect(player.rate == 2)
        #expect(timeline.currentSnapshot.rate == 2)
        #expect(timeline.currentSnapshot.state == .playing)
    }

    @Test
    @MainActor
    func invalidPlayerDefaultRateFallsBackBeforePlayback() {
        let player = AVPlayer()
        player.defaultRate = .nan

        let timeline = AVPlayerTimelineAdapter(player: player)

        #expect(player.defaultRate == 1)
        withExtendedLifetime(timeline) {}
    }
}
