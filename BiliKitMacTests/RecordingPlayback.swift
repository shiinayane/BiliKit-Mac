import BiliApplication
import BiliModels

@testable import BiliKit

/// 播放 port 的唯一测试替身：记录 load/begin/stop；`holdsLoads` 时 load 挂起到
/// `failPendingLoad()` 为止，用于驱动加载失败路径。
@MainActor
final class RecordingPlayback: PlaybackControlling {
    private struct ControlledFailure: Error {}

    private let holdsLoads: Bool
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCallCount = 0
    private var pendingLoad: CheckedContinuation<Void, any Error>?
    private var loadWaiters = CountWaiters()
    private var stopWaiters = CountWaiters()

    init(holdsLoads: Bool = false) {
        self.holdsLoads = holdsLoads
    }

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        AsyncStream { $0.finish() }
    }

    func playbackSourceExpiryEvents() -> AsyncStream<PlaybackSourceExpiryEvent> {
        AsyncStream { $0.finish() }
    }

    func refreshSource(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {}

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        startPositionSeconds: Double?
    ) async throws {
        loadedIdentities.append(identity)
        loadWaiters.resume(reaching: loadedIdentities.count)
        guard holdsLoads else { return }
        try await withCheckedThrowingContinuation { continuation in
            pendingLoad = continuation
        }
    }

    func beginPlayback(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async -> PlaybackStartOutcome {
        startedIdentities.append(identity)
        return .startedAtBeginning
    }

    func restartFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        resumeToken: PlaybackResumeToken
    ) async -> Bool { false }

    func replayFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async -> Bool { false }

    func play() {}

    func pause() {}

    func stop() {
        stopCallCount += 1
        stopWaiters.resume(reaching: stopCallCount)
    }

    func failPendingLoad() {
        pendingLoad?.resume(throwing: ControlledFailure())
        pendingLoad = nil
    }

    func waitForLoadCallCount(_ target: Int) async {
        await withCheckedContinuation {
            loadWaiters.add($0, until: target, current: loadedIdentities.count)
        }
    }

    func waitForStopCallCount(_ target: Int) async {
        await withCheckedContinuation {
            stopWaiters.add($0, until: target, current: stopCallCount)
        }
    }
}
