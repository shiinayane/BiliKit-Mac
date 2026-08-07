@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import Foundation

public enum AVPlayerEngineError: Error, Sendable, Equatable {
    case missingVideoRepresentation
    case missingAudioRepresentation
    case preferredVideoRepresentationNotFound(Int)
    case preferredAudioRepresentationNotFound(Int)
    case itemFailed(errorType: String)
    case invalidPlaybackRate
    case seekFailed
}

@MainActor
/// AVPlayer、DASH→HLS 会话与统一播放时间线的唯一资源 owner。
///
/// 每次 load 用 UUID generation 取代旧准备流程；迟到 bridge/readiness 结果必须自毁而不能
/// 安装到当前 player。`stop` 同时释放 item、任务、loopback server、observer 与时间线 identity。
public final class AVPlayerEngine:
    PlaybackControlling,
    PlaybackTimelineProviding
{
    public let player: AVPlayer
    public let events: AsyncStream<PlayerEvent>

    private let bridge: DASHToHLSBridge
    private let eventContinuation: AsyncStream<PlayerEvent>.Continuation
    private let failureEvents: AsyncStream<PlaybackFailureEvent>
    private let failureContinuation: AsyncStream<PlaybackFailureEvent>.Continuation
    private let timeline: AVPlayerTimelineAdapter
    private var loadTask: Task<PreparedPlaybackAsset, any Error>?
    private var readinessTask: Task<Void, any Error>?
    private var loadGeneration = UUID()
    private var loadIntent: PlaybackLoadIntent?
    private var preparedAsset: PreparedPlaybackAsset?

    public init(
        player: AVPlayer = AVPlayer(),
        bridge: DASHToHLSBridge = DASHToHLSBridge()
    ) {
        self.player = player
        self.bridge = bridge
        timeline = AVPlayerTimelineAdapter(player: player)
        let stream = AsyncStream<PlayerEvent>.makeStream()
        events = stream.stream
        eventContinuation = stream.continuation
        let failureStream = AsyncStream<PlaybackFailureEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        failureEvents = failureStream.stream
        failureContinuation = failureStream.continuation
        timeline.onEnded = { [weak self] in
            self?.emit(.stateChanged(.ended))
        }
        timeline.onFailed = { [weak self] in
            self?.handleCurrentItemFailure()
        }
    }

    deinit {
        loadTask?.cancel()
        readinessTask?.cancel()
        preparedAsset?.stop()
        eventContinuation.finish()
        failureContinuation.finish()
    }

    public var currentTimelineSnapshot: PlaybackTimelineSnapshot {
        timeline.currentSnapshot
    }

    public func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        timeline.updates()
    }

    public func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        failureEvents
    }

    /// 准备并安装一个新播放项目；调用方取消会沿 generation 边界清理本次全部资源。
    public func load(
        _ request: PlaybackRequest,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent = PlaybackLoadIntent()
    ) async throws {
        let generation = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await performLoad(
                request,
                identity: identity,
                intent: intent,
                generation: generation
            )
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelLoad(generation: generation)
            }
        }
    }

    public func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity
    ) async throws {
        try await load(
            PlaybackRequest(
                manifest: playback.manifest,
                mediaHeaders: playback.mediaHeaders
            ),
            identity: identity
        )
    }

    public func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        try await load(
            PlaybackRequest(
                manifest: playback.manifest,
                mediaHeaders: playback.mediaHeaders
            ),
            identity: identity,
            intent: intent
        )
    }

    private func performLoad(
        _ request: PlaybackRequest,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        generation: UUID
    ) async throws {
        loadGeneration = generation
        loadIntent = intent
        loadTask?.cancel()
        loadTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        preparedAsset?.stop()
        preparedAsset = nil
        player.replaceCurrentItem(with: nil)
        timeline.begin(identity: identity)
        emit(.stateChanged(.loading))

        let videos = try selectedVideos(for: request)
        let audio = try selectedAudio(for: request)
        let task = Task {
            try await bridge.prepare(
                videos: videos,
                audio: audio,
                headers: request.mediaHeaders
            )
        }
        loadTask = task

        do {
            let prepared = try await task.value
            try Task.checkCancellation()
            guard loadGeneration == generation else {
                prepared.stop()
                throw CancellationError()
            }

            loadTask = nil
            preparedAsset = prepared
            let item = AVPlayerItem(url: prepared.url)
            player.replaceCurrentItem(with: item)
            timeline.installObservers(for: item)
            let readinessTask = Task {
                try await AVPlayerItemReadiness.wait(untilReady: item)
            }
            self.readinessTask = readinessTask
            try await readinessTask.value
            try Task.checkCancellation()
            guard loadGeneration == generation else {
                throw CancellationError()
            }
            self.readinessTask = nil
            timeline.markReady(duration: item.duration)
            emit(.stateChanged(.ready))
        } catch is CancellationError {
            if loadGeneration == generation {
                loadTask = nil
                readinessTask = nil
                preparedAsset?.stop()
                preparedAsset = nil
                player.replaceCurrentItem(with: nil)
                timeline.clear()
                emit(.stateChanged(.idle))
            }
            throw CancellationError()
        } catch {
            if loadGeneration == generation {
                loadTask = nil
                readinessTask = nil
                preparedAsset?.stop()
                preparedAsset = nil
                player.replaceCurrentItem(with: nil)
                timeline.markFailed()
                emit(
                    .failed(
                        message: String(reflecting: type(of: error))
                    )
                )
            }
            throw error
        }
    }

    private func cancelLoad(generation: UUID) {
        guard loadGeneration == generation else { return }
        loadGeneration = UUID()
        loadIntent = nil
        loadTask?.cancel()
        loadTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        preparedAsset?.stop()
        preparedAsset = nil
        player.replaceCurrentItem(with: nil)
        timeline.clear()
        emit(.stateChanged(.idle))
    }

    public func play() {
        guard player.currentItem != nil else { return }
        timeline.play()
        emit(.stateChanged(.playing))
    }

    public func pause() {
        guard player.currentItem != nil else { return }
        timeline.pause()
        emit(.stateChanged(.paused))
    }

    public func setRate(_ rate: Double) throws {
        try timeline.setRate(rate)
    }

    /// 执行精确 seek，并只为一次用户 seek 发布一个 discontinuity generation。
    public func seek(to time: Duration) async throws {
        guard player.currentItem != nil else {
            throw AVPlayerEngineError.seekFailed
        }
        let components = time.components
        let seconds =
            Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        timeline.prepareExplicitSeek(to: seconds)
        let didSeek = await player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        guard didSeek else {
            timeline.explicitSeekFailed()
            throw AVPlayerEngineError.seekFailed
        }
        timeline.explicitSeekCompleted(at: seconds)
    }

    /// 幂等终止当前及在途播放，将唯一时间线恢复为 `.idle` 状态。
    public func stop() {
        loadGeneration = UUID()
        loadIntent = nil
        loadTask?.cancel()
        loadTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        preparedAsset?.stop()
        preparedAsset = nil
        timeline.clear()
        emit(.stateChanged(.idle))
    }

    private func selectedVideos(
        for request: PlaybackRequest
    ) throws -> [MediaRepresentation] {
        if let preferredID = request.preferredVideoRepresentationID {
            guard
                let representation = request.manifest.videoRepresentations.first(
                    where: { $0.id == preferredID }
                )
            else {
                throw AVPlayerEngineError.preferredVideoRepresentationNotFound(
                    preferredID
                )
            }
            return [representation]
        }
        guard !request.manifest.videoRepresentations.isEmpty else {
            throw AVPlayerEngineError.missingVideoRepresentation
        }
        return request.manifest.videoRepresentations
    }

    private func selectedAudio(
        for request: PlaybackRequest
    ) throws -> MediaRepresentation {
        if let preferredID = request.preferredAudioRepresentationID {
            guard
                let representation = request.manifest.audioRepresentations.first(
                    where: { $0.id == preferredID }
                )
            else {
                throw AVPlayerEngineError.preferredAudioRepresentationNotFound(
                    preferredID
                )
            }
            return representation
        }
        guard let representation = request.manifest.audioRepresentations.first else {
            throw AVPlayerEngineError.missingAudioRepresentation
        }
        return representation
    }

    private func emit(_ event: PlayerEvent) {
        eventContinuation.yield(event)
    }

    private func handleCurrentItemFailure() {
        guard let identity = timeline.currentSnapshot.identity,
            let intent = loadIntent
        else { return }
        loadGeneration = UUID()
        loadIntent = nil
        loadTask?.cancel()
        loadTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        preparedAsset?.stop()
        preparedAsset = nil
        failureContinuation.yield(
            PlaybackFailureEvent(identity: identity, intent: intent)
        )
        emit(.failed(message: "PlaybackItemFailed"))
    }
}
