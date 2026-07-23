import BiliApplication
import BiliModels

public struct DanmakuPresentationUpdate: Sendable, Equatable {
    public let snapshot: PlaybackTimelineSnapshot
    public let batch: DanmakuBatch?

    public init(
        snapshot: PlaybackTimelineSnapshot,
        batch: DanmakuBatch?
    ) {
        self.snapshot = snapshot
        self.batch = batch
    }
}

@MainActor
public protocol DanmakuPresentationSink: AnyObject {
    func apply(_ update: DanmakuPresentationUpdate)
    func clearPresentation()
    func stopPresentation()
}
