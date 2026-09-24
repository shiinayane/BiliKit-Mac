@preconcurrency import AVFoundation
import Foundation

enum AVPlayerItemReadiness {
    static func wait(untilReady item: AVPlayerItem) async throws {
        let (statuses, continuation) = AsyncStream.makeStream(of: AVPlayerItem.Status.self)
        let observation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { observedItem, _ in
            continuation.yield(observedItem.status)
        }
        defer {
            observation.invalidate()
            continuation.finish()
        }

        for await status in statuses {
            try Task.checkCancellation()
            switch status {
            case .readyToPlay:
                return
            case .failed:
                let errorType =
                    item.error.map {
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
