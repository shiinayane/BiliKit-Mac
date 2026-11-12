import BiliApplication
import BiliModels
import Foundation

/// 弹幕数据、时间线订阅、分段与互动弹幕加载和 presentation 的会话 owner。
///
/// 同时最多加载两个 segment；失败的 segment 在当前 identity 内不再重试（被 412 间歇风控时的一次
/// 延迟重试在 API 客户端内完成，等待期间占用加载名额）。generation 阻止切视频或 stop 后的迟到结果
/// 写回。`stop` 必须取消所有任务（含等待中的重试）并清空分段缓存与 presentation。
///
/// 拥有时间线订阅 Task、各分段的加载 Task、互动弹幕的加载 Task、分段缓存与互动弹幕，取消点是 `stop`（换视频时由
/// `start` 先调用）与 `deinit`；`stop` 先停止 presentation，再递增 generation、取消任务、清空缓存。
///
/// 互动弹幕在 `start` 时读一次，失败不重试、只让互动弹幕缺席。其中的 UP 主弹幕按时间并入对应分段再交给呈现端，
/// 与分段弹幕一起排车道；卡片单独交给呈现端。只弱引用
/// presentation sink：呈现控制器由 App 的窗口组装持有。
///
/// 会话只负责数据：每个快照原样交给呈现端，分段到达或被淘汰时把整份缓存交给呈现端；哪些弹幕在屏上
/// 由呈现端按媒体时间决定。暂停、缓冲时没有后续快照，一个分段加载完腾出名额后，按时间线当前的快照
/// 继续请求还缺的分段。会话不自建计时器。
@MainActor
public final class DanmakuSession: DanmakuSessionControlling {
    /// 同时在途的分段请求上限。
    ///
    /// 一次最多要当前、上一（位置在分段开头时）与下一分段，当前分段总排在最前，两个名额让当前分段与
    /// 紧随其后的一个并行；调大会让这三段同时在途。
    private static let maximumConcurrentSegmentLoads = 2

    private let useCase: DanmakuSegmentUseCase
    private let commandUseCase: DanmakuCommandUseCase
    private let timeline: any PlaybackTimelineProviding
    /// 弱引用：呈现控制器由 App 的窗口组装持有，会话不延长它的生命周期。
    private weak var presentationSink: (any DanmakuPresentationSink)?
    private var authenticationInvalidationHandler: @MainActor () -> Void = {}
    private var segmentCache = DanmakuSegmentCache()
    private var presentationEnabled = true
    private var presentationFilter = DanmakuFilter()
    private var identity: PlaybackItemIdentity?
    /// `start` 与 `stop` 时递增；分段与互动弹幕的加载 Task 带上发起时的值，返回后比对，不等就丢弃分段、
    /// 互动弹幕、失败记录与账户复核报告。
    private var generation = 0
    /// 订阅时间线的 Task；弱引用 self，`stop` 与 `deinit` 时取消。
    private var timelineTask: Task<Void, Never>?
    /// 按分段号的加载 Task；完成或失败时由 Task 自己移除，`stop` 与 `deinit` 时取消。
    private var loadTasks: [Int: Task<Void, Never>] = [:]
    /// 当前 identity 内失败过的分段，不再请求；`stop` 时清空。
    private var failedSegmentIndices: Set<Int> = []
    /// 当前 identity 的互动弹幕；读到之前与 `stop` 后为空。
    private var commands = DanmakuCommands.empty
    /// 当前 identity 里本窗口发出成功的弹幕（`presentOwnDanmaku`），与 UP 主弹幕一样按时间并入分段；`stop` 时清空。
    private var ownEvents: [DanmakuEvent] = []
    /// 读取互动弹幕的 Task；完成时自己置空，`stop` 与 `deinit` 时取消。
    private var commandTask: Task<Void, Never>?
    /// 同一会话只报告一次需要复核账户，`stop` 时重置。
    private var authenticationInvalidationReported = false

    public init(
        useCase: DanmakuSegmentUseCase,
        commandUseCase: DanmakuCommandUseCase,
        timeline: any PlaybackTimelineProviding,
        presentationSink: (any DanmakuPresentationSink)? = nil
    ) {
        self.useCase = useCase
        self.commandUseCase = commandUseCase
        self.timeline = timeline
        self.presentationSink = presentationSink
    }

    deinit {
        timelineTask?.cancel()
        commandTask?.cancel()
        for task in loadTasks.values {
            task.cancel()
        }
    }

    public func start(for identity: PlaybackItemIdentity) {
        guard self.identity != identity else { return }
        stop()
        generation &+= 1
        self.identity = identity
        segmentCache.begin(for: identity)
        loadCommands(identity: identity, generation: generation)
        let updates = timeline.timelineUpdates()
        timelineTask = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                self?.handle(snapshot)
            }
        }
    }

    public func setAuthenticationInvalidationHandler(
        _ handler: @escaping @MainActor () -> Void
    ) {
        authenticationInvalidationHandler = handler
    }

    public func setEnabled(_ enabled: Bool) {
        guard presentationEnabled != enabled else { return }
        presentationEnabled = enabled
        presentationSink?.setEnabled(enabled)
    }

    public func setModeVisibility(
        scrolling: Bool,
        top: Bool,
        bottom: Bool
    ) {
        var filter = presentationFilter
        filter.showsScrolling = scrolling
        filter.showsTop = top
        filter.showsBottom = bottom
        applyFilter(filter)
    }

    public func setMergesDuplicates(_ merges: Bool) {
        var filter = presentationFilter
        filter.mergesDuplicates = merges
        applyFilter(filter)
    }

    public func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {
        presentationSink?.setSpeedLevel(speedLevel)
    }

    public func setOpacity(_ opacity: DanmakuOpacity) {
        presentationSink?.setOpacity(opacity)
    }

    public func setDisplayArea(_ displayArea: DanmakuDisplayArea) {
        presentationSink?.setDisplayArea(displayArea)
    }

    public func setDensity(_ density: DanmakuDensity) {
        presentationSink?.setDensity(density)
    }

    private func applyFilter(_ filter: DanmakuFilter) {
        guard presentationFilter != filter else { return }
        presentationFilter = filter
        presentationSink?.setFilter(filter)
    }

    /// 幂等结束整个会话，而不只是隐藏弹幕图层。
    public func stop() {
        presentationSink?.stopPresentation()
        generation &+= 1
        timelineTask?.cancel()
        timelineTask = nil
        commandTask?.cancel()
        commandTask = nil
        commands = .empty
        ownEvents.removeAll(keepingCapacity: false)
        for task in loadTasks.values {
            task.cancel()
        }
        loadTasks.removeAll(keepingCapacity: false)
        failedSegmentIndices.removeAll(keepingCapacity: false)
        authenticationInvalidationReported = false
        identity = nil
        segmentCache.reset()
    }

    public func presentOwnDanmaku(_ event: DanmakuEvent, for identity: PlaybackItemIdentity) {
        guard self.identity == identity, !ownEvents.contains(where: { $0.id == event.id }) else {
            return
        }
        ownEvents.append(event)
        // 所在分段还没读到时这里不交：那一段到达时 `presentationSegments` 会把它并进去。
        guard segmentCache.segments[DanmakuSegmentCache.segmentIndex(at: event.timeSeconds)] != nil
        else { return }
        presentationSink?.setSegments(presentationSegments(), for: identity)
    }

    private func handle(_ snapshot: PlaybackTimelineSnapshot) {
        guard let identity, snapshot.identity == identity else { return }
        segmentCache.observe(snapshot)
        presentationSink?.apply(snapshot)
        requestSegments(for: snapshot)
    }

    /// 按快照请求还缺的分段：已缓存、失败过、在途或名额已满的跳过。
    private func requestSegments(for snapshot: PlaybackTimelineSnapshot) {
        guard let identity else { return }
        for index in segmentCache.desiredSegmentIndices(for: snapshot)
        where
            !segmentCache.contains(index: index)
            && !failedSegmentIndices.contains(index)
            && loadTasks[index] == nil
            && loadTasks.count < Self.maximumConcurrentSegmentLoads
        {
            load(index: index, identity: identity, generation: generation)
        }
    }

    /// 一个分段加载结束、腾出名额后，按时间线当前的快照继续请求；暂停时不会有新快照来触发。
    ///
    /// 快照不属于当前 identity（换视频的途中）时 `desiredSegmentIndices` 给出空集，什么都不请求。先让缓存观察
    /// 这个快照：它可能比经 stream 收到的新一些，淘汰保护的与这里请求的要出自同一个位置，否则刚请求到的分段
    /// 可能一到就被淘汰。
    private func requestRemainingSegments() {
        let current = timeline.currentTimelineSnapshot
        segmentCache.observe(current)
        requestSegments(for: current)
    }

    private func load(
        index: Int,
        identity: PlaybackItemIdentity,
        generation requestGeneration: Int
    ) {
        loadTasks[index] = Task { [weak self, useCase] in
            do {
                let segment = try await useCase.segment(index: index, for: identity)
                try Task.checkCancellation()
                guard let self,
                    self.generation == requestGeneration,
                    self.identity == identity
                else { return }
                self.loadTasks[index] = nil
                // 淘汰同时保护屏上弹幕所在时刻（呈现端的显示时间）需要的分段，见 DanmakuSegmentCache。
                if self.segmentCache.store(
                    segment,
                    for: identity,
                    displayTime: self.presentationSink?.displayTime()
                ) {
                    self.presentationSink?.setSegments(self.presentationSegments(), for: identity)
                }
                self.requestRemainingSegments()
            } catch is CancellationError {
                guard let self,
                    self.generation == requestGeneration
                else { return }
                self.loadTasks[index] = nil
            } catch {
                guard let self,
                    self.generation == requestGeneration,
                    self.identity == identity
                else { return }
                self.loadTasks[index] = nil
                self.failedSegmentIndices.insert(index)
                self.requestRemainingSegments()
                self.reportAuthenticationInvalidationIfNeeded(error)
            }
        }
    }

    private func reportAuthenticationInvalidationIfNeeded(_ error: any Error) {
        guard (error as? DanmakuApplicationError)?.requiresAccountRevalidation == true,
            !authenticationInvalidationReported
        else { return }
        authenticationInvalidationReported = true
        authenticationInvalidationHandler()
    }

    /// 读一次互动弹幕：卡片交给呈现端；有 UP 主弹幕且已有分段时，把并入后的分段重新交一次。
    private func loadCommands(identity: PlaybackItemIdentity, generation requestGeneration: Int) {
        commandTask = Task { [weak self, commandUseCase] in
            do {
                let commands = try await commandUseCase.commands(for: identity)
                try Task.checkCancellation()
                guard let self,
                    self.generation == requestGeneration,
                    self.identity == identity
                else { return }
                self.commandTask = nil
                self.commands = commands
                self.presentationSink?.setCommandCards(commands.cards, for: identity)
                if !commands.uploaderEvents.isEmpty, !self.segmentCache.segments.isEmpty {
                    self.presentationSink?.setSegments(self.presentationSegments(), for: identity)
                }
            } catch {
                guard let self, self.generation == requestGeneration else { return }
                self.commandTask = nil
                self.reportAuthenticationInvalidationIfNeeded(error)
            }
        }
    }

    /// 交给呈现端的分段：缓存的分段，各自并入时间落在本段的 UP 主弹幕（第 i 段覆盖 [(i − 1)·360, i·360) 秒）。
    ///
    /// 只并入已缓存的分段，所以分段淘汰与车道布局的种子规则不变；UP 主弹幕的 ID 带前缀，不与分段弹幕冲突。
    /// 互动弹幕晚于分段到达时，含 UP 主弹幕的分段会重新交一次，呈现端为它（以及末尾占用因此变化的后续分段）
    /// 重排一次车道；不让分段等互动弹幕，是为了互动弹幕接口慢或失败时普通弹幕不被拖住。
    ///
    /// 自己发出的弹幕同样并入；分段里已有同 ID 的（被淘汰后重新读到，服务端那份已包含它）换成本地这一条：只显示一次，
    /// 且仍带“自己发的”标记（边框、不参与重复合并），不会因为重读变成普通弹幕。
    private func presentationSegments() -> [Int: [DanmakuEvent]] {
        let segments = segmentCache.segments
        guard !commands.uploaderEvents.isEmpty || !ownEvents.isEmpty else { return segments }
        var result = segments
        for event in commands.uploaderEvents {
            result[DanmakuSegmentCache.segmentIndex(at: event.timeSeconds)]?.append(event)
        }
        for event in ownEvents {
            let index = DanmakuSegmentCache.segmentIndex(at: event.timeSeconds)
            guard var segment = result[index] else { continue }
            segment.removeAll { $0.id == event.id }
            segment.append(event)
            result[index] = segment
        }
        return result
    }
}
