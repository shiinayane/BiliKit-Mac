@preconcurrency import AVFoundation
import Foundation

enum AVPlayerItemReadiness {
    static func wait(untilReady item: AVPlayerItem) async throws {
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
