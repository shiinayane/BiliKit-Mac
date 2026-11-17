import BiliApplication
import BiliModels
import Observation

/// 某个分 P 的分段章节，带上所属分 P；呈现方据此丢弃别的分 P 的结果。
public struct VideoChapterList: Sendable, Equatable {
    public let identity: PlaybackItemIdentity
    public let chapters: [VideoChapter]
}

/// 进入某一章的提示内容：章节序号（从 1 起）与标题。
public struct VideoChapterAnnouncement: Sendable, Equatable {
    public let number: Int
    public let title: String
}

/// 播放页分段章节的唯一 owner：读取正在播放的分 P 的章节，按播放时间线维护当前章节，并在播放落定到另一章时发出提示。
///
/// 横排「章节」分页、播放器动作菜单的「章节」子菜单与播放器上的章节提示都只读这里，不各自换算时间。拥有章节读取的
/// Task（`LatestTask`）与时间线观察；不拥有跳转（由调用方经播放器 seek）与提示的显示（由播放器宿主经
/// `observeAnnouncements` 接到 `AVPlayerView.flashChapterNumber`）。
///
/// 由窗口组装持有，与弹幕模型同一生命周期：播放页在呈现的分 P 变化时 `select`，没有可播放的分 P、停止播放与关窗时
/// `reset`。`reset` 与换分 P 时先取消读取、停止时间线观察，再清空章节与当前章节；迟到的读取结果按 `LatestTask` 与
/// 所选分 P 一并核对后丢弃。读取失败不记下结果：同一分 P 再次 `select`（重新进入播放页）时重读，期间没有「章节」分页。
/// 只在有章节时观察时间线，没有章节的视频不为此多一个每帧回调。
@MainActor
@Observable
public final class VideoChapterModel {
    /// 正在播放的分 P 的章节；还没读到、读取失败或已换分 P 时为 nil，读到但没有章节时是空列表。
    public private(set) var chapters: VideoChapterList?
    /// 播放器当前所在的章节下标；时间线不属于这份章节、或位置在第一章之前时为 nil。
    ///
    /// 每个快照都按位置更新（暂停中拖动也跟着变），只在下标变化时写入，横排不随每帧重新求值。
    public private(set) var currentIndex: Int?

    @ObservationIgnored private let useCase: VideoChapterUseCase
    @ObservationIgnored private let timeline: any PlaybackTimelineProviding
    @ObservationIgnored private let loadTask = LatestTask()
    @ObservationIgnored private var selectedIdentity: PlaybackItemIdentity?
    @ObservationIgnored private var cancelTimelineObservation: (@MainActor @Sendable () -> Void)?
    /// 提示的判断只对一个 item 有效：load intent 变化（换 item、重新加载）时换新的。
    @ObservationIgnored private var gate = VideoChapterAnnouncementGate()
    @ObservationIgnored private var gateIntent: PlaybackLoadIntent?
    @ObservationIgnored private var announcementObservers:
        [UInt64: @MainActor (VideoChapterAnnouncement) -> Void] = [:]
    @ObservationIgnored private var nextObserverID: UInt64 = 0

    public init(useCase: VideoChapterUseCase, timeline: any PlaybackTimelineProviding) {
        self.useCase = useCase
        self.timeline = timeline
    }

    /// 播放页呈现的分 P 变了时调用；同一分 P 已读到或正在读时不重复请求。
    public func select(_ identity: PlaybackItemIdentity) {
        if selectedIdentity == identity, chapters != nil || loadTask.isRunning {
            return
        }
        if selectedIdentity != identity {
            clear()
            selectedIdentity = identity
        }
        let useCase = useCase
        loadTask.replace { [weak self] isCurrent in
            let loaded = try? await useCase.chapters(for: identity)
            guard let self, isCurrent(), self.selectedIdentity == identity, let loaded else {
                return
            }
            self.chapters = VideoChapterList(identity: identity, chapters: loaded)
            if !loaded.isEmpty {
                self.startObservingTimeline()
            }
        }
    }

    public func reset() {
        clear()
        selectedIdentity = nil
    }

    /// `identity` 正在播放时它的章节；不是这份章节所属的分 P 时为空。
    public func chapters(playing identity: PlaybackItemIdentity?) -> [VideoChapter] {
        guard let chapters, chapters.identity == identity else { return [] }
        return chapters.chapters
    }

    /// 订阅章节提示，返回取消订阅的函数；只收到此后的提示。
    public func observeAnnouncements(
        _ observer: @escaping @MainActor (VideoChapterAnnouncement) -> Void
    ) -> @MainActor () -> Void {
        nextObserverID &+= 1
        let id = nextObserverID
        announcementObservers[id] = observer
        return { [weak self] in
            self?.announcementObservers[id] = nil
        }
    }

    /// `seconds` 落在哪一章：最后一个起点不晚于它的章节；在第一章之前或没有章节时为 nil。
    static func chapterIndex(at seconds: Double, in chapters: [VideoChapter]) -> Int? {
        chapters.lastIndex { Double($0.startSeconds) <= seconds }
    }

    private func clear() {
        loadTask.cancel()
        stopObservingTimeline()
        chapters = nil
        if currentIndex != nil { currentIndex = nil }
    }

    /// 订阅当下先收到一次当前快照（`PlaybackTimelineProviding.observeTimeline`），当前章节随即对上。
    private func startObservingTimeline() {
        stopObservingTimeline()
        cancelTimelineObservation = timeline.observeTimeline { [weak self] snapshot in
            self?.consume(snapshot)
        }
    }

    private func stopObservingTimeline() {
        cancelTimelineObservation?()
        cancelTimelineObservation = nil
        gate = VideoChapterAnnouncementGate()
        gateIntent = nil
    }

    private func consume(_ snapshot: PlaybackTimelineSnapshot) {
        guard let list = chapters, snapshot.identity == list.identity else {
            if currentIndex != nil { currentIndex = nil }
            return
        }
        let index = Self.chapterIndex(at: snapshot.positionSeconds, in: list.chapters)
        if currentIndex != index { currentIndex = index }
        if snapshot.loadIntent != gateIntent {
            gate = VideoChapterAnnouncementGate()
            gateIntent = snapshot.loadIntent
        }
        guard
            let announced = gate.consume(
                positionSeconds: snapshot.positionSeconds,
                discontinuityGeneration: snapshot.discontinuityGeneration,
                isPlaying: snapshot.state == .playing,
                chapterIndex: index
            )
        else { return }
        let announcement = VideoChapterAnnouncement(
            number: announced + 1,
            title: list.chapters[announced].title
        )
        for observer in announcementObservers.values {
            observer(announcement)
        }
    }
}
