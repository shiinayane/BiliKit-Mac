@preconcurrency import AVFoundation
import BiliApplication
import Synchronization
import Testing

@testable import BiliPlayback

/// 播放时间线只在真实的不连续处推进 generation，用户交互只按真实操作计数。
///
/// 覆盖 `AVPlayerTimelineAdapter` 的 seek 落点吸收与取代、旧回调隔离、结束通知与观察者注销，
/// `TransportSeekOperationState` 的累加、夹取与旧完成回调拒绝，`PlaybackInteractionTracker` 对系统
/// 跳变、起播位置与内部 seek 的排除，以及临时倍速结束后的恢复策略。
@Suite(.timeLimit(.minutes(1)))
struct AVPlayerTimelineAdapterTests {
    @Test
    @MainActor
    func sameItemSeekCannotBeOverwrittenByQueuedEndNotification() async throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "video-avc",
                withExtension: "mp4",
                subdirectory: "Fixtures"
            )
        )
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let timeline = AVPlayerTimelineAdapter(player: player)
        timeline.begin(identity: PlaybackItemIdentity(bvid: "BVEndRace", cid: 1))
        timeline.markReady(duration: CMTime(seconds: 1, preferredTimescale: 600))
        timeline.installObservers(for: item)

        NotificationCenter.default.post(
            name: AVPlayerItem.didPlayToEndTimeNotification,
            object: item
        )
        timeline.observeTimeJump(at: 0.5)
        await Task.yield()

        #expect(timeline.currentSnapshot.state == .paused)
    }

    @Test
    @MainActor
    func observersAreRemovedAfterAdapterIsReleasedOffMainThread() async throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "video-avc",
                withExtension: "mp4",
                subdirectory: "Fixtures"
            )
        )
        let item = AVPlayerItem(url: url)
        let player = TimeObserverRemovalRecordingPlayer(playerItem: item)
        let box = ReleaseBox()
        box.adapter = AVPlayerTimelineAdapter(player: player)
        box.adapter?.begin(identity: PlaybackItemIdentity(bvid: "BVOffMainRelease", cid: 1))
        box.adapter?.installObservers(for: item)
        #expect(player.observationInfo != nil)
        #expect(item.observationInfo != nil)

        box.releaseOnBackgroundThread()
        #expect(box.releasedOffMain)

        // 观察集合的注销被排到主线程；让出主线程直到 periodic observer 被注销、KVO 全部移除，超时由 Suite
        // 时限取消兜底。periodic observer 只有显式注销才会移除，不会随对象释放自动消失。
        while player.timeObserverRemovalThreads.withLock({ $0.isEmpty })
            || player.observationInfo != nil
            || item.observationInfo != nil
        {
            try Task.checkCancellation()
            await Task.yield()
        }
        #expect(player.timeObserverRemovalThreads.withLock { $0 } == [true])
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
    @MainActor
    func completedTransportSeekAdvancesDiscontinuityWithoutResuming() {
        let player = AVPlayer()
        let timeline = AVPlayerTimelineAdapter(player: player)
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BVTransportFixture", cid: 1)
        )
        let before = timeline.currentSnapshot.discontinuityGeneration
        let operationID = UUID()

        timeline.prepareObservedSeek(operationID: operationID, to: 15)
        timeline.seekCompleted(
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

        timeline.prepareObservedSeek(operationID: operationID, to: 15)
        timeline.seekCompleted(operationID: operationID, at: 14.9)
        timeline.observeTimeJump(at: 14.9)
        // 暂停中 seek 后开播时系统在原处再报一次跳变，仍属于这次 seek。
        timeline.observeTimeJump(at: 14.9)

        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 1
        )
        timeline.observeTimeJump(at: 30)
        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 2
        )
    }

    /// 收尾前已见到落点跳变时，落点同样持续有效到被取代；取代之后回到原处的跳变是新的不连续。
    @Test
    @MainActor
    func landingSeenBeforeCompletionAbsorbsRepeatsUntilSuperseded() {
        let timeline = AVPlayerTimelineAdapter(player: AVPlayer())
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BVSeekEarlyLanding", cid: 1)
        )
        timeline.markReady(
            duration: CMTime(seconds: 100, preferredTimescale: 600)
        )
        let operationID = UUID()
        let before = timeline.currentSnapshot.discontinuityGeneration

        timeline.prepareObservedSeek(operationID: operationID, to: 15)
        timeline.observeTimeJump(at: 15)
        timeline.seekCompleted(operationID: operationID, at: 14.9)
        timeline.observeTimeJump(at: 14.9)

        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 1
        )
        timeline.observeTimeJump(at: 30)
        timeline.observeTimeJump(at: 14.9)
        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 3
        )
    }

    /// 落点只在播放位置仍在附近时吞掉重复跳变：播放离开落点之后，用原生控制条点回原处是新的不连续。
    @Test
    @MainActor
    func playbackLeavingTheLandingEndsItsRepeatAllowance() {
        let timeline = AVPlayerTimelineAdapter(player: AVPlayer())
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BVSeekLeaveLanding", cid: 1)
        )
        timeline.markReady(
            duration: CMTime(seconds: 100, preferredTimescale: 600)
        )
        let operationID = UUID()
        let before = timeline.currentSnapshot.discontinuityGeneration

        timeline.prepareObservedSeek(operationID: operationID, to: 15)
        timeline.seekCompleted(operationID: operationID, at: 15)
        timeline.observeTimeJump(at: 15)
        timeline.observePeriodicPosition(15.2)
        timeline.observeTimeJump(at: 15)
        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 1
        )

        timeline.observePeriodicPosition(45)
        timeline.observeTimeJump(at: 15.3)
        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 2
        )
        #expect(timeline.currentSnapshot.positionSeconds == 15.3)
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

        timeline.prepareObservedSeek(operationID: initial, to: 10)
        timeline.prepareObservedSeek(operationID: remote, to: 20)
        timeline.seekFailed(operationID: initial)
        timeline.prepareObservedSeek(operationID: transport, to: 25)
        timeline.seekCompleted(operationID: remote, at: 20)
        timeline.seekCompleted(operationID: transport, at: 24.9)

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

        timeline.prepareObservedSeek(operationID: operationID, to: 15)
        timeline.observeTimeJump(at: 50)
        timeline.seekCompleted(operationID: operationID, at: 15)

        #expect(supersededOperations == [operationID])
        #expect(
            timeline.currentSnapshot.discontinuityGeneration == before + 1
        )
        #expect(timeline.currentSnapshot.positionSeconds == 50)
    }

    /// 从 playlist 起播位置开始的 item：就绪即标记不连续，起播处的系统跳变不算用户操作。
    @Test
    @MainActor
    func playlistStartOffsetMarksReadyDiscontinuityWithoutInteraction() {
        let timeline = AVPlayerTimelineAdapter(player: AVPlayer())
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BVStartOffset", cid: 1),
            startPositionSeconds: 42
        )
        let before = timeline.currentSnapshot.discontinuityGeneration

        timeline.markReady(
            duration: CMTime(seconds: 100, preferredTimescale: 600)
        )
        timeline.observeTimeJump(at: 42.1)

        #expect(
            timeline.currentSnapshot.discontinuityGeneration > before
        )
        #expect(!timeline.hasObservedPlaybackInteraction)
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

        timeline.prepareObservedSeek(operationID: first, to: 5)
        timeline.prepareObservedSeek(operationID: second, to: 10)
        timeline.observeTimeJump(at: 5)
        timeline.seekCompleted(operationID: second, at: 10)
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

        timeline.prepareObservedSeek(operationID: first, to: 0.2)
        timeline.prepareObservedSeek(operationID: second, to: 0.5)
        timeline.observeTimeJump(at: 0.2)
        timeline.seekCompleted(operationID: second, at: 0.5)
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

        timeline.prepareObservedSeek(operationID: first, to: 5)
        timeline.prepareObservedSeek(operationID: second, to: 10)
        timeline.discardStaleSeekLanding(operationID: first)
        timeline.seekCompleted(operationID: second, at: 10)
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

        timeline.prepareObservedSeek(operationID: transport, to: 15)
        timeline.prepareObservedSeek(operationID: explicit, to: 50)
        timeline.observeTimeJump(at: 15)
        timeline.seekCompleted(operationID: explicit, at: 50)
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

        timeline.prepareObservedSeek(operationID: first, to: 100)
        timeline.prepareObservedSeek(operationID: second, to: 100)
        timeline.seekCompleted(operationID: second, at: 100)
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
    func interactionTrackerDoesNotInferIntentFromInFlightHLSSeekLanding() {
        let tracker = PlaybackInteractionTracker()
        tracker.markObservedAllowingInternalSeek(to: 42)
        let seekRevision = tracker.revision

        tracker.observeTimeJump(at: 42.25)
        tracker.observeTimeJump(at: 10)
        #expect(tracker.revision == seekRevision)
        tracker.completeInternalSeek(at: 37)

        tracker.observeTimeJump(at: 10)
        #expect(tracker.revision == seekRevision + 1)
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

    /// 从 playlist 起播位置开始的 item：落在起播位置的系统跳变不是用户操作，其他位置仍是。
    @Test
    func systemJumpToPlaylistStartPositionDoesNotCountAsUserSeek() {
        let tracker = PlaybackInteractionTracker(startPositionSeconds: 42)

        tracker.observeTimeJump(at: 42)
        tracker.observeTimeJump(at: 42.2)
        #expect(tracker.revision == 0)

        tracker.observeTimeJump(at: 0)
        #expect(tracker.revision == 1)
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

    /// 受控 seek 期间无论已真正播放还是仍在按请求速率等待，随后的暂停都算一次新的用户操作。
    @Test(arguments: [true, false])
    func pauseAfterStartDuringInternalSeekCountsAsInteraction(
        reachedPlaying: Bool
    ) {
        let tracker = PlaybackInteractionTracker()
        tracker.markObservedAllowingInternalSeek(to: 42)
        let seekRevision = tracker.revision

        tracker.observeTimeControlStatus(
            isPaused: false,
            isPlaying: reachedPlaying,
            playbackRate: 1
        )
        #expect(tracker.revision == seekRevision)
        tracker.observeTimeControlStatus(
            isPaused: true,
            isPlaying: false,
            playbackRate: 0
        )

        #expect(tracker.revision == seekRevision + 1)
    }

    @Test(
        arguments: [
            (AVPlayer.TimeControlStatus.paused, 0, MomentaryRateRestorationAction.none),
            (.playing, 2, .setCurrentRate),
            (.waitingToPlayAtSpecifiedRate, 0, .resumeAtDefaultRate),
            (.waitingToPlayAtSpecifiedRate, 1.5, .none)
        ] as [(AVPlayer.TimeControlStatus, Float, MomentaryRateRestorationAction)]
    )
    func momentaryRateRestorationPreservesPauseAndRecoversBuffering(
        status: AVPlayer.TimeControlStatus,
        currentRate: Float,
        expected: MomentaryRateRestorationAction
    ) {
        #expect(
            MomentaryRateRestorationPolicy.action(
                timeControlStatus: status,
                currentRate: currentRate,
                momentaryRate: 2
            ) == expected
        )
    }

    @Test
    @MainActor
    func playStartsAtValidatedDefaultRateAndReportsBufferingWhileWaitingForMedia() {
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
        #expect(timeline.currentSnapshot.state == .buffering)
    }
}

/// 把 adapter 的最后一个引用带到后台线程释放。
///
/// `@unchecked Sendable`：后台线程只在调用方线程阻塞于信号量期间读写这两个属性，信号量的 signal／wait
/// 保证先后，不需要锁。
private final class ReleaseBox: @unchecked Sendable {
    var adapter: AVPlayerTimelineAdapter?
    private(set) var releasedOffMain = false

    /// 调用方阻塞到后台线程放掉最后一个引用：期间主线程上排队的回调拿不到强引用，释放一定发生在后台线程。
    func releaseOnBackgroundThread() {
        let released = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            self.adapter = nil
            self.releasedOffMain = !Thread.isMainThread
            released.signal()
        }
        released.wait()
    }
}

/// 记录每次注销 periodic time observer 时是否在主线程。
private final class TimeObserverRemovalRecordingPlayer: AVPlayer {
    let timeObserverRemovalThreads = Mutex<[Bool]>([])

    override func removeTimeObserver(_ observer: Any) {
        timeObserverRemovalThreads.withLock { $0.append(Thread.isMainThread) }
        super.removeTimeObserver(observer)
    }
}
