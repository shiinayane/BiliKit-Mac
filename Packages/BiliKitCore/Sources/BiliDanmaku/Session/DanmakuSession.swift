import BiliApplication
import BiliModels
import Foundation

public enum DanmakuSessionState: Sendable, Equatable {
    case idle
    case loading(PlaybackItemIdentity)
    case ready(PlaybackItemIdentity)
    case failed(PlaybackItemIdentity, DanmakuApplicationError)
}

@MainActor
public final class DanmakuSession: DanmakuPresentationControlling {
    public private(set) var state: DanmakuSessionState = .idle

    private let useCase: DanmakuSegmentUseCase
    private let timeline: any PlaybackTimelineProviding
    private weak var presentationSink: (any DanmakuPresentationSink)?
    private var scheduler = DanmakuScheduler()
    private var presentationEnabled = true
    private var presentationFilter = DanmakuFilter()
    private var identity: PlaybackItemIdentity?
    private var generation = 0
    private var timelineTask: Task<Void, Never>?
    private var loadTasks: [Int: Task<Void, Never>] = [:]
    private var continuations: [
        UUID: AsyncStream<DanmakuBatch>.Continuation
    ] = [:]

    public init(
        useCase: DanmakuSegmentUseCase,
        timeline: any PlaybackTimelineProviding,
        presentationSink: (any DanmakuPresentationSink)? = nil
    ) {
        self.useCase = useCase
        self.timeline = timeline
        self.presentationSink = presentationSink
    }

    deinit {
        timelineTask?.cancel()
        loadTasks.values.forEach { $0.cancel() }
        continuations.values.forEach { $0.finish() }
    }

    public func batches() -> AsyncStream<DanmakuBatch> {
        let id = UUID()
        let stream = AsyncStream<DanmakuBatch>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        continuations[id] = stream.continuation
        stream.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.continuations.removeValue(forKey: id)
            }
        }
        return stream.stream
    }

    public func start(for identity: PlaybackItemIdentity) {
        guard self.identity != identity else { return }
        stop()
        generation &+= 1
        self.identity = identity
        scheduler.begin(for: identity)
        state = .loading(identity)
        let updates = timeline.timelineUpdates()
        timelineTask = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                self?.handle(snapshot)
            }
        }
    }

    public func setEnabled(_ enabled: Bool) {
        guard presentationEnabled != enabled else { return }
        presentationEnabled = enabled
        scheduler.setEnabled(enabled)
        if !enabled {
            presentationSink?.clearPresentation()
        }
    }

    public func setFilter(_ filter: DanmakuFilter) {
        guard presentationFilter != filter else { return }
        presentationFilter = filter
        scheduler.setFilter(filter)
        presentationSink?.clearPresentation()
    }

    public func setModeVisibility(
        scrolling: Bool,
        top: Bool,
        bottom: Bool
    ) {
        setFilter(
            DanmakuFilter(
                showsScrolling: scrolling,
                showsTop: top,
                showsBottom: bottom
            )
        )
    }

    public func stop() {
        presentationSink?.stopPresentation()
        generation &+= 1
        timelineTask?.cancel()
        timelineTask = nil
        loadTasks.values.forEach { $0.cancel() }
        loadTasks.removeAll(keepingCapacity: false)
        identity = nil
        scheduler.reset()
        state = .idle
    }

    public func waitForLoads() async {
        let tasks = Array(loadTasks.values)
        for task in tasks {
            await task.value
        }
    }

    private func handle(_ snapshot: PlaybackTimelineSnapshot) {
        guard let identity, snapshot.identity == identity else { return }
        let batch = scheduler.consume(snapshot)
        presentationSink?.apply(
            DanmakuPresentationUpdate(snapshot: snapshot, batch: batch)
        )
        if let batch {
            continuations.values.forEach { $0.yield(batch) }
        }
        let required = scheduler.desiredSegmentIndices(for: snapshot)
        for index in required where
            !scheduler.containsSegment(index: index)
            && loadTasks[index] == nil
            && loadTasks.count < 2
        {
            load(index: index, identity: identity, generation: generation)
        }
    }

    private func load(
        index: Int,
        identity: PlaybackItemIdentity,
        generation requestGeneration: Int
    ) {
        loadTasks[index] = Task { [weak self, useCase] in
            do {
                let segment = try await useCase.segment(
                    index: index,
                    for: identity
                )
                try Task.checkCancellation()
                guard let self,
                      self.generation == requestGeneration,
                      self.identity == identity
                else { return }
                self.scheduler.store(segment, for: identity)
                self.loadTasks[index] = nil
                self.state = .ready(identity)
            } catch is CancellationError {
                guard let self,
                      self.generation == requestGeneration
                else { return }
                self.loadTasks[index] = nil
            } catch let error as DanmakuApplicationError {
                guard let self,
                      self.generation == requestGeneration,
                      self.identity == identity
                else { return }
                self.loadTasks[index] = nil
                self.state = .failed(identity, error)
            } catch {
                guard let self,
                      self.generation == requestGeneration,
                      self.identity == identity
                else { return }
                self.loadTasks[index] = nil
                self.state = .failed(identity, .unavailable)
            }
        }
    }
}
