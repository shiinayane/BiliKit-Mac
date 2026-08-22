@preconcurrency import AVFoundation
import BiliApplication
import Testing

@testable import BiliPlayback

struct AVPlayerTimelineAdapterTests {
    @Test
    func playbackTogglePausesUnlessPlayerIsPaused() {
        #expect(
            PlaybackToggleAction(
                timeControlStatus: .paused,
                timelineState: .paused
            ) == .play
        )
        #expect(
            PlaybackToggleAction(
                timeControlStatus: .playing,
                timelineState: .playing
            ) == .pause
        )
        #expect(
            PlaybackToggleAction(
                timeControlStatus: .waitingToPlayAtSpecifiedRate,
                timelineState: .buffering
            ) == .pause
        )
        #expect(
            PlaybackToggleAction(
                timeControlStatus: .paused,
                timelineState: .ended
            ) == nil
        )
    }

    @Test
    func transportSeekAccumulatesClampsAndRejectsStaleCompletion() throws {
        final class Item {}
        var state = TransportSeekOperationState()
        let generation = UUID()
        let itemObject = Item()
        let item = ObjectIdentifier(itemObject)
        let firstCandidate = state.prepare(
            offsetSeconds: 5,
            currentSeconds: 90,
            durationSeconds: 100,
            generation: generation,
            itemIdentity: item
        )
        let first = try #require(firstCandidate)
        let secondCandidate = state.prepare(
            offsetSeconds: 5,
            currentSeconds: 90,
            durationSeconds: 100,
            generation: generation,
            itemIdentity: item
        )
        let second = try #require(secondCandidate)

        #expect(first.targetSeconds == 95)
        #expect(second.targetSeconds == 100)
        #expect(
            state.complete(
                first,
                finished: false,
                resolvedPositionSeconds: nil
            ) == .ignored
        )
        #expect(state.current == second)
        #expect(
            state.complete(
                second,
                finished: true,
                resolvedPositionSeconds: 99.8
            ) == .completed(positionSeconds: 99.8)
        )
        #expect(state.current == nil)
    }

    @Test
    func transportSeekRejectsIndefiniteDurationAndIsolatesReplacement() {
        final class Item {}
        var state = TransportSeekOperationState()
        let firstItemObject = Item()
        let replacementItemObject = Item()
        let firstGeneration = UUID()
        let replacementGeneration = UUID()

        #expect(
            state.prepare(
                offsetSeconds: 5,
                currentSeconds: 10,
                durationSeconds: .infinity,
                generation: firstGeneration,
                itemIdentity: ObjectIdentifier(firstItemObject)
            ) == nil
        )
        let first = state.prepare(
            offsetSeconds: -50,
            currentSeconds: 10,
            durationSeconds: 100,
            generation: firstGeneration,
            itemIdentity: ObjectIdentifier(firstItemObject)
        )
        #expect(first?.targetSeconds == 0)
        let replacement = state.prepare(
            offsetSeconds: 5,
            currentSeconds: 40,
            durationSeconds: 100,
            generation: replacementGeneration,
            itemIdentity: ObjectIdentifier(replacementItemObject)
        )
        #expect(replacement?.targetSeconds == 45)
        if let first {
            #expect(!state.matches(first))
        }
        state.invalidate()
        #expect(state.current == nil)
    }

    @Test
    func audioSelectionOperationRejectsCancelledOrReplacedWork() {
        var state = AudioSelectionOperationState()
        let firstID = UUID()
        let replacementID = UUID()

        let first = state.begin { firstID }
        #expect(state.matches(first))

        let replacement = state.begin { replacementID }
        #expect(!state.matches(first))
        #expect(state.matches(replacement))

        state.invalidate()
        #expect(!state.matches(replacement))
    }

    @Test
    @MainActor
    func completedTransportSeekAdvancesDiscontinuityWithoutResuming() {
        let player = AVPlayer()
        let timeline = AVPlayerTimelineAdapter(player: player)
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BVTransportFixture", cid: 1)
        )
        let before = timeline.currentSnapshot.discontinuityGeneration
        let operationID = UUID()

        timeline.prepareTransportSeek(operationID: operationID, to: 15)
        timeline.transportSeekCompleted(
            operationID: operationID,
            at: 14.9
        )

        #expect(player.rate == 0)
        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 1
        )
        #expect(timeline.currentSnapshot.positionSeconds == 14.9)
    }

    @Test
    @MainActor
    func seekCompletionSuppressesOnlyItsOwnLateLandingNotification() {
        let timeline = AVPlayerTimelineAdapter(player: AVPlayer())
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BVSeekLanding", cid: 1)
        )
        timeline.markReady(
            duration: CMTime(seconds: 100, preferredTimescale: 600)
        )
        let operationID = UUID()
        let before = timeline.currentSnapshot.discontinuityGeneration

        timeline.prepareTransportSeek(operationID: operationID, to: 15)
        timeline.transportSeekCompleted(operationID: operationID, at: 14.9)
        timeline.observeTimeJump(at: 14.9)

        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 1
        )
        timeline.observeTimeJump(at: 30)
        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 2
        )
    }

    @Test
    @MainActor
    func landingBeforeCompletionDoesNotLeaveStaleSuppression() {
        let timeline = AVPlayerTimelineAdapter(player: AVPlayer())
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BVSeekEarlyLanding", cid: 1)
        )
        timeline.markReady(
            duration: CMTime(seconds: 100, preferredTimescale: 600)
        )
        let operationID = UUID()
        let before = timeline.currentSnapshot.discontinuityGeneration

        timeline.prepareExplicitSeek(operationID: operationID, to: 15)
        timeline.observeTimeJump(at: 15)
        timeline.explicitSeekCompleted(operationID: operationID, at: 14.9)

        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 1
        )
        timeline.observeTimeJump(at: 14.9)
        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 2
        )
    }

    @Test
    @MainActor
    func staleSeekCallbacksCannotClearOrCompleteReplacementOperation() {
        let timeline = AVPlayerTimelineAdapter(player: AVPlayer())
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BVSeekReplacement", cid: 1)
        )
        timeline.markReady(
            duration: CMTime(seconds: 100, preferredTimescale: 600)
        )
        let initial = UUID()
        let remote = UUID()
        let transport = UUID()
        let before = timeline.currentSnapshot.discontinuityGeneration

        timeline.prepareInitialSeek(operationID: initial, to: 10)
        timeline.prepareExplicitSeek(operationID: remote, to: 20)
        timeline.initialSeekFailed(operationID: initial)
        timeline.prepareTransportSeek(operationID: transport, to: 25)
        timeline.explicitSeekCompleted(operationID: remote, at: 20)
        timeline.transportSeekCompleted(operationID: transport, at: 24.9)

        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 1
        )
        #expect(timeline.currentSnapshot.positionSeconds == 24.9)
    }

    @Test
    @MainActor
    func nonmatchingNativeJumpSupersedesPendingEngineSeek() {
        let timeline = AVPlayerTimelineAdapter(player: AVPlayer())
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BVNativeSupersede", cid: 1)
        )
        timeline.markReady(
            duration: CMTime(seconds: 100, preferredTimescale: 600)
        )
        let operationID = UUID()
        let before = timeline.currentSnapshot.discontinuityGeneration
        var supersededOperations: [UUID] = []
        timeline.onSeekSupersededByExternalJump = {
            supersededOperations.append($0)
        }

        timeline.prepareTransportSeek(operationID: operationID, to: 15)
        timeline.observeTimeJump(at: 50)
        timeline.transportSeekCompleted(operationID: operationID, at: 15)

        #expect(supersededOperations == [operationID])
        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 1
        )
        #expect(timeline.currentSnapshot.positionSeconds == 50)
    }

    @Test
    @MainActor
    func replacedFarSeekLandingCannotSupersedeCurrentSeek() {
        let timeline = AVPlayerTimelineAdapter(player: AVPlayer())
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BVFarSeekABA", cid: 1)
        )
        timeline.markReady(
            duration: CMTime(seconds: 100, preferredTimescale: 600)
        )
        let first = UUID()
        let second = UUID()
        let before = timeline.currentSnapshot.discontinuityGeneration
        var supersededOperations: [UUID] = []
        timeline.onSeekSupersededByExternalJump = {
            supersededOperations.append($0)
        }

        timeline.prepareTransportSeek(operationID: first, to: 5)
        timeline.prepareTransportSeek(operationID: second, to: 10)
        timeline.observeTimeJump(at: 5)
        timeline.transportSeekCompleted(operationID: second, at: 10)
        timeline.observeTimeJump(at: 10)

        #expect(supersededOperations.isEmpty)
        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 1
        )
        #expect(timeline.currentSnapshot.positionSeconds == 10)
    }

    @Test
    @MainActor
    func replacedNearbySeekLandingCannotPoseAsCurrentLanding() {
        let timeline = AVPlayerTimelineAdapter(player: AVPlayer())
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BVNearSeekABA", cid: 1)
        )
        timeline.markReady(
            duration: CMTime(seconds: 100, preferredTimescale: 600)
        )
        let first = UUID()
        let second = UUID()
        let before = timeline.currentSnapshot.discontinuityGeneration
        var supersededOperations: [UUID] = []
        timeline.onSeekSupersededByExternalJump = {
            supersededOperations.append($0)
        }

        timeline.prepareExplicitSeek(operationID: first, to: 0.2)
        timeline.prepareExplicitSeek(operationID: second, to: 0.5)
        timeline.observeTimeJump(at: 0.2)
        timeline.explicitSeekCompleted(operationID: second, at: 0.5)
        timeline.observeTimeJump(at: 0.5)

        #expect(supersededOperations.isEmpty)
        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 1
        )
        #expect(timeline.currentSnapshot.positionSeconds == 0.5)
    }

    @Test
    @MainActor
    func cancelledReplacedSeekDoesNotLeaveAStaleLandingAllowance() {
        let timeline = AVPlayerTimelineAdapter(player: AVPlayer())
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BVCancelledSeek", cid: 1)
        )
        timeline.markReady(
            duration: CMTime(seconds: 100, preferredTimescale: 600)
        )
        let first = UUID()
        let second = UUID()
        let before = timeline.currentSnapshot.discontinuityGeneration

        timeline.prepareTransportSeek(operationID: first, to: 5)
        timeline.prepareTransportSeek(operationID: second, to: 10)
        timeline.discardStaleSeekLanding(operationID: first)
        timeline.transportSeekCompleted(operationID: second, at: 10)
        timeline.observeTimeJump(at: 10)
        timeline.observeTimeJump(at: 5)

        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 2
        )
        #expect(timeline.currentSnapshot.positionSeconds == 5)
    }

    @Test
    @MainActor
    func lateTransportLandingCannotSupersedeReplacementExplicitSeek() {
        let timeline = AVPlayerTimelineAdapter(player: AVPlayer())
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BVTransportToExplicit", cid: 1)
        )
        timeline.markReady(
            duration: CMTime(seconds: 100, preferredTimescale: 600)
        )
        let transport = UUID()
        let explicit = UUID()
        let before = timeline.currentSnapshot.discontinuityGeneration
        var supersededOperations: [UUID] = []
        timeline.onSeekSupersededByExternalJump = {
            supersededOperations.append($0)
        }

        timeline.prepareTransportSeek(operationID: transport, to: 15)
        timeline.prepareExplicitSeek(operationID: explicit, to: 50)
        timeline.observeTimeJump(at: 15)
        timeline.explicitSeekCompleted(operationID: explicit, at: 50)
        timeline.observeTimeJump(at: 50)

        #expect(supersededOperations.isEmpty)
        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 1
        )
        #expect(timeline.currentSnapshot.positionSeconds == 50)
    }

    @Test
    @MainActor
    func identicalSeekTargetsShareOneLandingAllowance() {
        let timeline = AVPlayerTimelineAdapter(player: AVPlayer())
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BVIdenticalSeek", cid: 1)
        )
        timeline.markReady(
            duration: CMTime(seconds: 100, preferredTimescale: 600)
        )
        let first = UUID()
        let second = UUID()
        let before = timeline.currentSnapshot.discontinuityGeneration

        timeline.prepareTransportSeek(operationID: first, to: 100)
        timeline.prepareTransportSeek(operationID: second, to: 100)
        timeline.transportSeekCompleted(operationID: second, at: 100)
        timeline.observeTimeJump(at: 100)

        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 1
        )
        timeline.observeTimeJump(at: 50)
        timeline.observeTimeJump(at: 100)
        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 3
        )
        #expect(timeline.currentSnapshot.positionSeconds == 100)
    }

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
