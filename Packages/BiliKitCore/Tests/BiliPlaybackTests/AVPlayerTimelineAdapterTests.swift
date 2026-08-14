@preconcurrency import AVFoundation
import BiliApplication
import Testing

@testable import BiliPlayback

struct AVPlayerTimelineAdapterTests {
    @Test
    @MainActor
    func resolvedInitialPositionUsesMediaBoundsInsteadOfTargetDelta() {
        #expect(
            AVPlayerEngine.validatedResolvedInitialPosition(
                CMTime(seconds: 37, preferredTimescale: 600),
                durationSeconds: 300
            ) == 37
        )
        #expect(
            AVPlayerEngine.validatedResolvedInitialPosition(
                CMTime(seconds: 0.25, preferredTimescale: 600),
                durationSeconds: 300
            ) == nil
        )
        #expect(
            AVPlayerEngine.validatedResolvedInitialPosition(
                CMTime(seconds: 299.96, preferredTimescale: 600),
                durationSeconds: 300
            ) == nil
        )
        #expect(
            AVPlayerEngine.validatedResolvedInitialPosition(
                .indefinite,
                durationSeconds: 300
            ) == nil
        )
    }

    @Test
    func interactionTrackerDoesNotInferIntentFromInFlightHLSSeekLanding() {
        let tracker = PlaybackInteractionTracker()
        tracker.allowInternalSeek(to: 42)

        tracker.observeTimeJump(at: 42.25)
        tracker.observeTimeJump(at: 10)
        #expect(tracker.revision == 0)
        tracker.completeInternalSeek(at: 37)

        tracker.observeTimeJump(at: 10)
        #expect(tracker.revision == 1)
    }

    @Test
    func initialSystemZeroJumpDoesNotCountAsUserSeek() {
        let tracker = PlaybackInteractionTracker()

        tracker.observeTimeJump(at: 0)
        tracker.observeTimeJump(at: 0.2)

        #expect(tracker.revision == 0)
        tracker.observeTimeJump(at: 0.3)
        #expect(tracker.revision == 1)
    }

    @Test
    func explicitPauseOrSeekAdvancesInteractionRevision() {
        let tracker = PlaybackInteractionTracker()

        tracker.markObserved()
        tracker.markObserved()

        #expect(tracker.hasObservedInteraction)
        #expect(tracker.revision == 2)
    }

    @Test
    func controlledRestartIsAnInteractionButIgnoresItsOwnTimeJump() {
        let tracker = PlaybackInteractionTracker()

        tracker.markObservedAllowingInternalSeek(to: 0)
        let revision = tracker.revision
        tracker.observeTimeJump(at: 0)

        #expect(revision == 1)
        #expect(tracker.revision == revision)
    }

    @Test
    func pausedTransitionOnlyCountsAfterPlaybackSessionHasStarted() {
        let tracker = PlaybackInteractionTracker()

        tracker.observeTimeControlStatus(
            isPaused: true,
            isPlaying: false,
            playbackRate: 0
        )
        #expect(tracker.revision == 0)

        tracker.observeTimeControlStatus(
            isPaused: false,
            isPlaying: true,
            playbackRate: 1
        )
        let playingRevision = tracker.revision
        tracker.markObservedAllowingInternalSeek(to: 0)
        let restartRevision = tracker.revision
        tracker.observeTimeControlStatus(
            isPaused: true,
            isPlaying: false,
            playbackRate: 0
        )

        #expect(playingRevision == 1)
        #expect(restartRevision == 2)
        #expect(tracker.revision == 3)
    }

    @Test
    func internalPlayStartIgnoresBufferingButPauseStillCancelsCommit() {
        let tracker = PlaybackInteractionTracker()
        tracker.allowInternalPlayStart()

        tracker.observeTimeControlStatus(
            isPaused: false,
            isPlaying: false,
            playbackRate: 0
        )
        #expect(tracker.revision == 0)

        tracker.observeTimeControlStatus(
            isPaused: true,
            isPlaying: false,
            playbackRate: 0
        )
        #expect(tracker.revision == 1)
    }

    @Test
    func playThenPauseDuringInitialSeekCancelsThePendingCommit() {
        let tracker = PlaybackInteractionTracker()
        tracker.allowInternalSeek(to: 42)

        tracker.observeTimeControlStatus(
            isPaused: false,
            isPlaying: true,
            playbackRate: 1
        )
        #expect(tracker.revision == 0)
        tracker.observeTimeControlStatus(
            isPaused: true,
            isPlaying: false,
            playbackRate: 0
        )

        #expect(tracker.revision == 1)
    }

    @Test
    func requestedWaitingThenPauseDuringInitialSeekCancelsCommit() {
        let tracker = PlaybackInteractionTracker()
        tracker.allowInternalSeek(to: 42)

        tracker.observeTimeControlStatus(
            isPaused: false,
            isPlaying: false,
            playbackRate: 1
        )
        #expect(tracker.revision == 0)
        tracker.observeTimeControlStatus(
            isPaused: true,
            isPlaying: false,
            playbackRate: 0
        )

        #expect(tracker.revision == 1)
    }

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
