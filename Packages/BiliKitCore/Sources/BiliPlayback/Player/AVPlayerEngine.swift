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
public final class AVPlayerEngine: PlayerEngine, PlaybackControlling {
    public let player: AVPlayer
    public let events: AsyncStream<PlayerEvent>

    private let bridge: DASHToHLSBridge
    private let eventContinuation: AsyncStream<PlayerEvent>.Continuation
    private let timeline: AVPlayerTimelineAdapter
    private var loadTask: Task<PreparedPlaybackAsset, any Error>?
    private var readinessTask: Task<Void, any Error>?
    private var loadGeneration = UUID()
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
        player.automaticallyWaitsToMinimizeStalling = false
        timeline.onEnded = { [weak self] in
            self?.emit(.stateChanged(.ended))
        }
    }

    deinit {
        loadTask?.cancel()
        readinessTask?.cancel()
        preparedAsset?.stop()
        eventContinuation.finish()
    }

    public var currentTimelineSnapshot: PlaybackTimelineSnapshot {
        timeline.currentSnapshot
    }

    public func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        timeline.updates()
    }

    public func load(
        _ request: PlaybackRequest,
        identity: PlaybackItemIdentity
    ) async throws {
        let generation = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await performLoad(
                request,
                identity: identity,
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

    private func performLoad(
        _ request: PlaybackRequest,
        identity: PlaybackItemIdentity,
        generation: UUID
    ) async throws {
        loadGeneration = generation
        loadTask?.cancel()
        loadTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        preparedAsset?.stop()
        preparedAsset = nil
        player.replaceCurrentItem(with: nil)
        timeline.begin(identity: identity)
        emit(.stateChanged(.loading))

        let video = try selectedVideo(for: request)
        let audio = try selectedAudio(for: request)
        let task = Task {
            try await bridge.prepare(
                video: video,
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

    public func seek(to time: Duration) async throws {
        guard player.currentItem != nil else {
            throw AVPlayerEngineError.seekFailed
        }
        let components = time.components
        let seconds = Double(components.seconds)
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

    public func stop() {
        loadGeneration = UUID()
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

    private func selectedVideo(
        for request: PlaybackRequest
    ) throws -> MediaRepresentation {
        if let preferredID = request.preferredVideoRepresentationID {
            guard let representation = request.manifest.videoRepresentations.first(
                where: { $0.id == preferredID }
            ) else {
                throw AVPlayerEngineError.preferredVideoRepresentationNotFound(
                    preferredID
                )
            }
            return representation
        }
        guard let representation = request.manifest.videoRepresentations.first else {
            throw AVPlayerEngineError.missingVideoRepresentation
        }
        return representation
    }

    private func selectedAudio(
        for request: PlaybackRequest
    ) throws -> MediaRepresentation {
        if let preferredID = request.preferredAudioRepresentationID {
            guard let representation = request.manifest.audioRepresentations.first(
                where: { $0.id == preferredID }
            ) else {
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
}
