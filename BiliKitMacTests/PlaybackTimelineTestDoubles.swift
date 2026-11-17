import BiliApplication
import BiliModels
import Foundation

/// 分段章节 port 的唯一测试替身：恒为空。
struct EmptyVideoChapterRepository: VideoChapterRepository {
    func chapters(for identity: PlaybackItemIdentity) async throws -> [VideoChapter] { [] }
}

/// 本 target 唯一的 `PlaybackTimelineProviding` 替身：手动推进，订阅时先补发当前快照，与真实时间线的 `observe` 一致。
@MainActor
final class ManualTimeline: PlaybackTimelineProviding {
    var current: PlaybackTimelineSnapshot
    private(set) var observers: [UUID: @MainActor (PlaybackTimelineSnapshot) -> Void] = [:]

    init(current: PlaybackTimelineSnapshot = .idle) {
        self.current = current
    }

    var currentTimelineSnapshot: PlaybackTimelineSnapshot { current }

    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        let current = current
        return AsyncStream { continuation in
            continuation.yield(current)
            continuation.finish()
        }
    }

    func observeTimeline(
        _ observer: @escaping @MainActor (PlaybackTimelineSnapshot) -> Void
    ) -> @MainActor @Sendable () -> Void {
        let id = UUID()
        observers[id] = observer
        observer(current)
        return { [weak self] in self?.observers[id] = nil }
    }

    func send(_ snapshot: PlaybackTimelineSnapshot) {
        current = snapshot
        for observer in observers.values { observer(snapshot) }
    }
}
