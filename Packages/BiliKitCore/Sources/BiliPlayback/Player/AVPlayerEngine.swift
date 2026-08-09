@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import Foundation

public enum AVPlayerEngineError: Error, Sendable, Equatable {
    case missingVideoRepresentation
    case missingAudioRepresentation
    case missingAudioTrackRepresentation(String)
    case duplicateAudioTrackID(String)
    case invalidDefaultAudioTrackCount(Int)
    case invalidAudioTrackRepresentation(trackID: String, representationID: Int)
    case preferredVideoRepresentationNotFound(Int)
    case preferredAudioTrackNotFound(String)
    case preferredAudioRepresentationNotFound(
        trackID: String,
        representationID: Int
    )
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
    private let subtitleUseCase: SubtitleUseCase?
    private let eventContinuation: AsyncStream<PlayerEvent>.Continuation
    private let failureEvents: AsyncStream<PlaybackFailureEvent>
    private let failureContinuation: AsyncStream<PlaybackFailureEvent>.Continuation
    private let timeline: AVPlayerTimelineAdapter
    private var loadTask: Task<PreparedPlaybackAsset, any Error>?
    private var readinessTask: Task<Void, any Error>?
    private var loadGeneration = UUID()
    private var loadIntent: PlaybackLoadIntent?
    private var preparedAsset: PreparedPlaybackAsset?
    private var subtitleIdentity: PlaybackItemIdentity?
    private var subtitleResetTask: Task<Void, Never>?

    public init(
        player: AVPlayer = AVPlayer(),
        bridge: DASHToHLSBridge = DASHToHLSBridge(),
        subtitleUseCase: SubtitleUseCase? = nil
    ) {
        self.player = player
        self.bridge = bridge
        self.subtitleUseCase = subtitleUseCase
        if subtitleUseCase != nil {
            player.appliesMediaSelectionCriteriaAutomatically = false
        }
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
        if let subtitleUseCase, let subtitleIdentity {
            let previousReset = subtitleResetTask
            Task {
                await previousReset?.value
                await subtitleUseCase.reset(for: subtitleIdentity)
            }
        }
        eventContinuation.finish()
        failureContinuation.finish()
    }

    public var currentTimelineSnapshot: PlaybackTimelineSnapshot {
        timeline.currentSnapshot
    }

    public var nativeSubtitlesEnabled: Bool {
        subtitleUseCase != nil
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
        player.pause()
        player.replaceCurrentItem(with: nil)
        let pendingSubtitleReset = enqueueSubtitleReset()
        timeline.begin(identity: identity)
        emit(.stateChanged(.loading))

        let videos = try selectedVideos(for: request)
        let audioTracks = try selectedAudioTracks(for: request)
        await pendingSubtitleReset?.value
        try Task.checkCancellation()
        guard loadGeneration == generation else {
            throw CancellationError()
        }
        let subtitleSource = subtitleUseCase.map {
            NativeSubtitleSource(useCase: $0, identity: identity)
        }
        if subtitleSource != nil {
            subtitleIdentity = identity
        }
        let task = Task {
            try await bridge.prepare(
                videos: videos,
                audioTracks: audioTracks,
                headers: request.mediaHeaders,
                subtitleSource: subtitleSource
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
                _ = enqueueSubtitleReset()
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
                _ = enqueueSubtitleReset()
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
        _ = enqueueSubtitleReset()
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

    /// 临时改变当前播放速率，但不覆盖用户选择的永久速率。
    public func beginMomentaryPlaybackRate(_ rate: Double) throws -> UUID? {
        try timeline.beginMomentaryRate(rate)
    }

    /// 结束仍匹配的临时速率会话；过期会话不会影响新的播放项目或用户改速。
    public func endMomentaryPlaybackRate(sessionID: UUID) {
        timeline.endMomentaryRate(sessionID: sessionID)
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
        _ = enqueueSubtitleReset()
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

    func selectedAudioTracks(
        for request: PlaybackRequest
    ) throws -> [SelectedPlaybackAudioTrack] {
        guard !request.manifest.audioTracks.isEmpty else {
            throw AVPlayerEngineError.missingAudioRepresentation
        }
        var trackIDs = Set<String>()
        for track in request.manifest.audioTracks {
            guard trackIDs.insert(track.id).inserted else {
                throw AVPlayerEngineError.duplicateAudioTrackID(track.id)
            }
        }
        for trackID in request.preferredAudioRepresentationIDs.keys
        where !trackIDs.contains(trackID) {
            throw AVPlayerEngineError.preferredAudioTrackNotFound(trackID)
        }
        let defaultTracks = request.manifest.audioTracks.filter(\.isDefault)
        guard defaultTracks.count == 1 else {
            throw AVPlayerEngineError.invalidDefaultAudioTrackCount(
                defaultTracks.count
            )
        }

        return try request.manifest.audioTracks.map { track in
            for representation in track.representations
            where representation.kind != .audio {
                throw AVPlayerEngineError.invalidAudioTrackRepresentation(
                    trackID: track.id,
                    representationID: representation.id
                )
            }
            let representation: MediaRepresentation
            if let preferredID =
                request.preferredAudioRepresentationIDs[track.id]
            {
                guard
                    let preferred = track.representations.first(
                        where: { $0.id == preferredID }
                    )
                else {
                    throw
                        AVPlayerEngineError
                        .preferredAudioRepresentationNotFound(
                            trackID: track.id,
                            representationID: preferredID
                        )
                }
                representation = preferred
            } else {
                guard let first = track.representations.first else {
                    throw AVPlayerEngineError.missingAudioTrackRepresentation(
                        track.id
                    )
                }
                representation = first
            }
            return SelectedPlaybackAudioTrack(
                track: track,
                representation: representation
            )
        }
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
        _ = enqueueSubtitleReset()
        failureContinuation.yield(
            PlaybackFailureEvent(identity: identity, intent: intent)
        )
        emit(.failed(message: "PlaybackItemFailed"))
    }

    @discardableResult
    private func enqueueSubtitleReset() -> Task<Void, Never>? {
        guard let subtitleUseCase, let identity = subtitleIdentity else {
            return subtitleResetTask
        }
        subtitleIdentity = nil
        let previousReset = subtitleResetTask
        let task = Task {
            await previousReset?.value
            await subtitleUseCase.reset(for: identity)
        }
        subtitleResetTask = task
        return task
    }
}
