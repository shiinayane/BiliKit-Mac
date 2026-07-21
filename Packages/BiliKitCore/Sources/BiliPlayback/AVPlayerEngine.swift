@preconcurrency import AVFoundation
import BiliModels
import Foundation

public enum AVPlayerEngineError: Error, Sendable, Equatable {
    case missingVideoRepresentation
    case missingAudioRepresentation
    case preferredVideoRepresentationNotFound(Int)
    case preferredAudioRepresentationNotFound(Int)
    case itemFailed(errorType: String)
    case seekFailed
}

@MainActor
public final class AVPlayerEngine: PlayerEngine {
    public let player: AVPlayer
    public let events: AsyncStream<PlayerEvent>

    private let bridge: DASHToHLSBridge
    private let eventContinuation: AsyncStream<PlayerEvent>.Continuation
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
        let stream = AsyncStream<PlayerEvent>.makeStream()
        events = stream.stream
        eventContinuation = stream.continuation
        player.automaticallyWaitsToMinimizeStalling = false
    }

    deinit {
        loadTask?.cancel()
        readinessTask?.cancel()
        preparedAsset?.stop()
        eventContinuation.finish()
    }

    public func load(_ request: PlaybackRequest) async throws {
        let generation = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await performLoad(request, generation: generation)
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelLoad(generation: generation)
            }
        }
    }

    private func performLoad(
        _ request: PlaybackRequest,
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
            let readinessTask = Task {
                try await waitUntilReadyToPlay(item)
            }
            self.readinessTask = readinessTask
            try await readinessTask.value
            try Task.checkCancellation()
            guard loadGeneration == generation else {
                throw CancellationError()
            }
            self.readinessTask = nil
            emit(.stateChanged(.ready))
        } catch is CancellationError {
            if loadGeneration == generation {
                loadTask = nil
                readinessTask = nil
                preparedAsset?.stop()
                preparedAsset = nil
                player.replaceCurrentItem(with: nil)
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
        emit(.stateChanged(.idle))
    }

    public func play() {
        guard player.currentItem != nil else { return }
        player.play()
        emit(.stateChanged(.playing))
    }

    public func pause() {
        guard player.currentItem != nil else { return }
        player.pause()
        emit(.stateChanged(.paused))
    }

    public func seek(to time: Duration) async throws {
        guard player.currentItem != nil else {
            throw AVPlayerEngineError.seekFailed
        }
        let components = time.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let didSeek = await player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        guard didSeek else {
            throw AVPlayerEngineError.seekFailed
        }
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

    private func waitUntilReadyToPlay(_ item: AVPlayerItem) async throws {
        let observationBox = PlayerItemStatusObservationBox()
        let statuses = AsyncStream<AVPlayerItem.Status> { continuation in
            let observation = item.observe(
                \.status,
                options: [.initial, .new]
            ) { observedItem, _ in
                continuation.yield(observedItem.status)
            }
            observationBox.store(observation)
            continuation.onTermination = { _ in
                observationBox.invalidate()
            }
        }

        for await status in statuses {
            try Task.checkCancellation()
            switch status {
            case .readyToPlay:
                return
            case .failed:
                let errorType = item.error.map {
                    String(reflecting: type(of: $0))
                } ?? "UnknownAVPlayerItemError"
                throw AVPlayerEngineError.itemFailed(errorType: errorType)
            case .unknown:
                continue
            @unknown default:
                throw AVPlayerEngineError.itemFailed(
                    errorType: "UnknownAVPlayerItemStatus"
                )
            }
        }
        throw CancellationError()
    }

    private func emit(_ event: PlayerEvent) {
        eventContinuation.yield(event)
    }
}

private final class PlayerItemStatusObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var isInvalidated = false

    func store(_ observation: NSKeyValueObservation) {
        let shouldInvalidate = lock.withLock { () -> Bool in
            guard !isInvalidated else { return true }
            self.observation = observation
            return false
        }
        if shouldInvalidate {
            observation.invalidate()
        }
    }

    func invalidate() {
        let observation = lock.withLock { () -> NSKeyValueObservation? in
            isInvalidated = true
            let observation = self.observation
            self.observation = nil
            return observation
        }
        observation?.invalidate()
    }
}
