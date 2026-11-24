import BiliApplication
import BiliModels

@testable import BiliVideoDetailFeature

/// 唯一的 PlaybackControlling 替身，记录 load、开播、换源、重播与停止。
///
/// 可让指定 BVID 的 load 失败、让第 `failingLoads` 次 load 失败（从 1 开始）、让第 `heldLoad` 次 load 挂起到测试放行，
/// 或让首个 load 先发布失败再等到 stop 才返回；换源可挂起到测试放行（`holdsRefreshes`）。
/// 失败与换源事件与生产 engine 一样经 `AsyncBroadcast` 发布：不回放、每个订阅独立，所以 ViewModel 必须在发起 load
/// 前订阅；测试可等 ViewModel 回来请求下一个事件。
@MainActor
final class PlayerStub: PlaybackControlling {
    private let startOutcome: PlaybackStartOutcome
    private let restartSucceeds: Bool
    private let holdsRestarts: Bool
    private let failingBVID: String?
    private let failingLoads: Set<Int>
    private let heldLoad: Int?
    private let failsFirstLoadUntilStopped: Bool
    private let holdsRefreshes: Bool
    private let failures = AsyncBroadcast<PlaybackFailureEvent>()
    private let sourceExpiries = AsyncBroadcast<PlaybackSourceExpiryEvent>()
    private var failureRequestCount = 0
    private var failureRequestWaiters = CountWaiters()
    private var sourceExpiryRequestCount = 0
    private var sourceExpiryRequestWaiters = CountWaiters()
    private var refreshWaiters = CountWaiters()
    private var heldRefresh: CheckedContinuation<Void, Never>?
    private(set) var refreshedPlaybacks: [VideoPlayback] = []
    private(set) var refreshedIdentities: [PlaybackItemIdentity] = []
    private var heldLoadContinuation: CheckedContinuation<Void, Never>?
    private var loadWaiters = CountWaiters()
    private var stopWaiters = CountWaiters()
    private var restartWaiters = CountWaiters()
    private var heldRestarts: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var loadedPlaybacks: [VideoPlayback] = []
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var loadedIntents: [PlaybackLoadIntent] = []
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var startedIntents: [PlaybackLoadIntent] = []
    private(set) var loadedStartPositions: [Double?] = []
    private(set) var restartTokens: [PlaybackResumeToken] = []
    private let replaySucceeds: Bool
    /// 收到的重播请求；结果由 init 的 `replaySucceeds` 决定。
    private(set) var replayedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCallCount = 0

    init(
        startOutcome: PlaybackStartOutcome = .startedAtBeginning,
        restartSucceeds: Bool = false,
        replaySucceeds: Bool = true,
        holdsRestarts: Bool = false,
        failingBVID: String? = nil,
        failingLoads: Set<Int> = [],
        heldLoad: Int? = nil,
        failsFirstLoadUntilStopped: Bool = false,
        holdsRefreshes: Bool = false
    ) {
        self.startOutcome = startOutcome
        self.restartSucceeds = restartSucceeds
        self.replaySucceeds = replaySucceeds
        self.holdsRestarts = holdsRestarts
        self.failingBVID = failingBVID
        self.failingLoads = failingLoads
        self.heldLoad = heldLoad
        self.failsFirstLoadUntilStopped = failsFirstLoadUntilStopped
        self.holdsRefreshes = holdsRefreshes
    }

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        let subscription = CountingEventSubscription(
            failures.subscribe(startingWith: nil)
        ) { [weak self] in
            self?.recordFailureRequest()
        }
        return AsyncStream(unfolding: { await subscription.next() })
    }

    func playbackSourceExpiryEvents() -> AsyncStream<PlaybackSourceExpiryEvent> {
        let subscription = CountingEventSubscription(
            sourceExpiries.subscribe(startingWith: nil)
        ) { [weak self] in
            self?.recordSourceExpiryRequest()
        }
        return AsyncStream(unfolding: { await subscription.next() })
    }

    private func recordFailureRequest() {
        failureRequestCount += 1
        failureRequestWaiters.resume(reaching: failureRequestCount)
    }

    private func recordSourceExpiryRequest() {
        sourceExpiryRequestCount += 1
        sourceExpiryRequestWaiters.resume(reaching: sourceExpiryRequestCount)
    }

    func refreshSource(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        refreshedPlaybacks.append(playback)
        refreshedIdentities.append(identity)
        refreshWaiters.resume(reaching: refreshedIdentities.count)
        if holdsRefreshes {
            await withCheckedContinuation { heldRefresh = $0 }
        }
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        startPositionSeconds: Double?
    ) async throws {
        loadedPlaybacks.append(playback)
        loadedStartPositions.append(startPositionSeconds)
        loadedIdentities.append(identity)
        loadedIntents.append(intent)
        loadWaiters.resume(reaching: loadedIdentities.count)
        if identity.bvid == failingBVID || failingLoads.contains(loadedIdentities.count) {
            throw PlayerStubFailure()
        }
        if failsFirstLoadUntilStopped, loadedIdentities.count == 1 {
            failures.yield(
                PlaybackFailureEvent(identity: identity, intent: intent, positionSeconds: 0)
            )
            await withCheckedContinuation { heldLoadContinuation = $0 }
        } else if loadedIdentities.count == heldLoad {
            await withCheckedContinuation { heldLoadContinuation = $0 }
        }
    }

    func beginPlayback(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async -> PlaybackStartOutcome {
        startedIdentities.append(identity)
        startedIntents.append(intent)
        return startOutcome
    }

    func restartFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        resumeToken: PlaybackResumeToken
    ) async -> Bool {
        let index = restartTokens.count
        restartTokens.append(resumeToken)
        restartWaiters.resume(reaching: restartTokens.count)
        if holdsRestarts {
            await withCheckedContinuation { heldRestarts[index] = $0 }
        }
        return restartSucceeds
    }

    func replayFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async -> Bool {
        replayedIdentities.append(identity)
        return replaySucceeds
    }

    func play() {}

    func pause() {}

    func stop() {
        stopCallCount += 1
        stopWaiters.resume(reaching: stopCallCount)
        if failsFirstLoadUntilStopped {
            releaseHeldLoad()
        }
    }

    /// 以该 identity 最近一次 load 的 intent 发布 ready 后在 `positionSeconds` 处失败。
    func fail(_ identity: PlaybackItemIdentity, at positionSeconds: Double = 0) async {
        guard let index = loadedIdentities.lastIndex(of: identity) else { return }
        await publishFailure(
            PlaybackFailureEvent(
                identity: identity,
                intent: loadedIntents[index],
                positionSeconds: positionSeconds
            )
        )
    }

    func publishFailure(_ event: PlaybackFailureEvent) async {
        failures.yield(event)
    }

    /// 以该 identity 最近一次 load 的 intent 发布换源请求。
    func expireSource(_ identity: PlaybackItemIdentity, at positionSeconds: Double) {
        guard let index = loadedIdentities.lastIndex(of: identity) else { return }
        publishSourceExpiry(
            PlaybackSourceExpiryEvent(
                identity: identity,
                intent: loadedIntents[index],
                positionSeconds: positionSeconds
            )
        )
    }

    func publishSourceExpiry(_ event: PlaybackSourceExpiryEvent) {
        sourceExpiries.yield(event)
    }

    func waitForSourceExpiryRequestCount(_ expectedCount: Int) async {
        await withCheckedContinuation {
            sourceExpiryRequestWaiters.add(
                $0,
                until: expectedCount,
                current: sourceExpiryRequestCount
            )
        }
    }

    func waitForRefreshCount(_ expectedCount: Int) async {
        await withCheckedContinuation {
            refreshWaiters.add($0, until: expectedCount, current: refreshedIdentities.count)
        }
    }

    func releaseHeldRefresh() {
        heldRefresh?.resume()
        heldRefresh = nil
    }

    func waitForFailureRequestCount(_ expectedCount: Int) async {
        await withCheckedContinuation {
            failureRequestWaiters.add($0, until: expectedCount, current: failureRequestCount)
        }
    }

    func waitForLoadCount(_ expectedCount: Int) async {
        await withCheckedContinuation {
            loadWaiters.add($0, until: expectedCount, current: loadedIdentities.count)
        }
    }

    func releaseHeldLoad() {
        heldLoadContinuation?.resume()
        heldLoadContinuation = nil
    }

    func waitForRestartCount(_ expectedCount: Int) async {
        await withCheckedContinuation {
            restartWaiters.add($0, until: expectedCount, current: restartTokens.count)
        }
    }

    func releaseRestart(at index: Int) {
        heldRestarts.removeValue(forKey: index)?.resume()
    }

    func waitForStopCallCount(_ expectedCount: Int) async {
        await withCheckedContinuation {
            stopWaiters.add($0, until: expectedCount, current: stopCallCount)
        }
    }
}

/// 一个播放事件订阅；每次取下一个事件前通知替身，测试据此确认 ViewModel 已处理完上一个事件。
@MainActor
private final class CountingEventSubscription<Event: Sendable> {
    private var iterator: AsyncStream<Event>.Iterator
    private let onRequest: @MainActor () -> Void

    init(
        _ stream: AsyncStream<Event>,
        onRequest: @escaping @MainActor () -> Void
    ) {
        iterator = stream.makeAsyncIterator()
        self.onRequest = onRequest
    }

    func next() async -> Event? {
        onRequest()
        var iterator = self.iterator
        let event = await iterator.next(isolation: #isolation)
        self.iterator = iterator
        return event
    }
}

private struct PlayerStubFailure: Error {}
