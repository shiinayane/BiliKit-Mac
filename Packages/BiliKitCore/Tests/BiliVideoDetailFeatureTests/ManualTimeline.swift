import BiliApplication
import Foundation

/// 时间线 port 在本 target 唯一的替身：手动推进，订阅时先补发当前快照，与真实时间线的 `observe` 一致。
@MainActor
final class ManualTimeline: PlaybackTimelineProviding {
    private(set) var currentTimelineSnapshot = PlaybackTimelineSnapshot.idle
    private var observers: [UUID: @MainActor (PlaybackTimelineSnapshot) -> Void] = [:]

    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        AsyncStream { $0.finish() }
    }

    func observeTimeline(
        _ observer: @escaping @MainActor (PlaybackTimelineSnapshot) -> Void
    ) -> @MainActor @Sendable () -> Void {
        let id = UUID()
        observers[id] = observer
        observer(currentTimelineSnapshot)
        return { [weak self] in self?.observers[id] = nil }
    }

    func send(_ snapshot: PlaybackTimelineSnapshot) {
        currentTimelineSnapshot = snapshot
        for observer in observers.values { observer(snapshot) }
    }
}
