@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import Foundation

public enum AVPlayerEngineError: Error, Sendable, Equatable {
    case missingVideoRepresentation
    case missingAudioRepresentation
    case missingAudioTrackRepresentation(String)
    case duplicateAudioTrackID(String)
    case invalidDefaultAudioTrackCount(Int)
    case invalidAudioTrackRepresentation(trackID: String, representationID: Int)
    case preferredVideoRepresentationNotFound(Int)
    case preferredAudioTrackNotFound(String)
    case preferredAudioRepresentationNotFound(
        trackID: String,
        representationID: Int
    )
    case itemFailed(errorType: String)
    case invalidPlaybackRate
    case seekFailed
}

public enum NativeSubtitleToggleResult: Sendable, Equatable {
    case enabled(label: String)
    case disabled
    case unavailable
}

private struct NativeSubtitleSelectionPreference: Sendable {
    let propertyListData: Data?
}

enum PlaybackToggleAction: Equatable, Sendable {
    case play
    case pause

    init?(
        timeControlStatus: AVPlayer.TimeControlStatus,
        timelineState: PlaybackTimelineState
    ) {
        guard timelineState != .ended else { return nil }
        self = timeControlStatus == .paused ? .play : .pause
    }
}

struct TransportSeekOperationState: Sendable {
    struct Operation: Equatable, Sendable {
        let id: UUID
        let generation: UUID
        let itemIdentity: ObjectIdentifier
        let targetSeconds: Double
    }

    enum Completion: Equatable, Sendable {
        case ignored
        case failed
        case completed(positionSeconds: Double)
    }

    private(set) var current: Operation?

    mutating func prepare(
        offsetSeconds: Double,
        currentSeconds: Double,
        durationSeconds: Double,
        generation: UUID,
        itemIdentity: ObjectIdentifier,
        makeOperationID: () -> UUID = UUID.init
    ) -> Operation? {
        guard offsetSeconds.isFinite,
            currentSeconds.isFinite,
            currentSeconds >= 0,
            durationSeconds.isFinite,
            durationSeconds > 0
        else { return nil }
        let base =
            if let current,
                current.generation == generation,
                current.itemIdentity == itemIdentity
            {
                current.targetSeconds
            } else {
                currentSeconds
            }
        let operation = Operation(
            id: makeOperationID(),
            generation: generation,
            itemIdentity: itemIdentity,
            targetSeconds: min(max(base + offsetSeconds, 0), durationSeconds)
        )
        current = operation
        return operation
    }

    func matches(_ operation: Operation) -> Bool {
        current == operation
    }

    mutating func complete(
        _ operation: Operation,
        finished: Bool,
        resolvedPositionSeconds: Double?
    ) -> Completion {
        guard matches(operation) else { return .ignored }
        current = nil
        guard finished,
            let resolvedPositionSeconds,
            resolvedPositionSeconds.isFinite,
            resolvedPositionSeconds >= 0
        else { return .failed }
        return .completed(positionSeconds: resolvedPositionSeconds)
    }

    @discardableResult
    mutating func invalidate() -> Operation? {
        let operation = current
        current = nil
        return operation
    }
}

struct AudioSelectionOperationState: Sendable {
    private(set) var currentID: UUID?

    mutating func begin(makeID: () -> UUID = UUID.init) -> UUID {
        let id = makeID()
        currentID = id
        return id
    }

    func matches(_ id: UUID) -> Bool {
        currentID == id
    }

    mutating func invalidate() {
        currentID = nil
    }
}

@MainActor
/// AVPlayer、DASH→HLS 会话与统一播放时间线的唯一资源 owner。
///
/// 每次 load 用 UUID generation 取代旧准备流程；迟到 bridge/readiness 结果必须自毁而不能
/// 安装到当前 player。`stop` 同时释放 item、任务、loopback server、observer 与时间线 identity。
public final class AVPlayerEngine:
    PlaybackControlling,
    PlaybackTimelineProviding
{
    public let player: AVPlayer
    public let events: AsyncStream<PlayerEvent>

    private let bridge: DASHToHLSBridge
    private let subtitleUseCase: SubtitleUseCase?
    private let sourcePreferenceProvider: @MainActor @Sendable () -> PlaybackSourcePreference
    private let loudnessNormalizationEnabledProvider: @MainActor @Sendable () -> Bool
    private let eventContinuation: AsyncStream<PlayerEvent>.Continuation
    private let failureEvents: AsyncStream<PlaybackFailureEvent>
    private let failureContinuation: AsyncStream<PlaybackFailureEvent>.Continuation
    private let timeline: AVPlayerTimelineAdapter
    private var loadTask: Task<PreparedPlaybackAsset, any Error>?
    private var readinessTask: Task<Void, any Error>?
    private var loadGeneration = UUID()
    private var loadIntent: PlaybackLoadIntent?
    private var activeResumeToken: PlaybackResumeToken?
    private var restartOperation: UUID?
    private var activeSeekOperationID: UUID?
    private var preparedAsset: PreparedPlaybackAsset?
    private var subtitleIdentity: PlaybackItemIdentity?
    private var subtitleResetTask: Task<Void, Never>?
    private var subtitleToggleOperationID: UUID?
    private var lastSubtitleSelection: NativeSubtitleSelectionPreference?
    private var transportSeek = TransportSeekOperationState()
    private var loudnessTap: LoudnessProcessingTap?
    private var loudnessAudioTracks: [PlaybackAudioTrack] = []
    private var audioSelectionObserver: (any NSObjectProtocol)?
    private var audioSelectionTask: Task<Void, Never>?
    private var audioSelectionOperation = AudioSelectionOperationState()

    public init(
        player: AVPlayer = AVPlayer(),
        bridge: DASHToHLSBridge = DASHToHLSBridge(),
        subtitleUseCase: SubtitleUseCase? = nil,
        sourcePreferenceProvider:
            @escaping @MainActor @Sendable () -> PlaybackSourcePreference = {
                .serverDefault
            },
        loudnessNormalizationEnabledProvider:
            @escaping @MainActor @Sendable () -> Bool = {
                false
            }
    ) {
        self.player = player
        player.preventsDisplaySleepDuringVideoPlayback = true
        self.bridge = bridge
        self.subtitleUseCase = subtitleUseCase
        self.sourcePreferenceProvider = sourcePreferenceProvider
        self.loudnessNormalizationEnabledProvider = loudnessNormalizationEnabledProvider
        if subtitleUseCase != nil {
            player.appliesMediaSelectionCriteriaAutomatically = false
        }
        timeline = AVPlayerTimelineAdapter(player: player)
        let stream = AsyncStream<PlayerEvent>.makeStream()
        events = stream.stream
        eventContinuation = stream.continuation
        let failureStream = AsyncStream<PlaybackFailureEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        failureEvents = failureStream.stream
        failureContinuation = failureStream.continuation
        timeline.onEnded = { [weak self] in
            self?.emit(.stateChanged(.ended))
        }
        timeline.onFailed = { [weak self] in
            self?.handleCurrentItemFailure()
        }
        timeline.onSeekSupersededByExternalJump = {
            [weak self] operationID in
            self?.handleSeekSupersededByExternalJump(operationID)
        }
    }

    deinit {
        loadTask?.cancel()
        readinessTask?.cancel()
        audioSelectionTask?.cancel()
        if let audioSelectionObserver {
            NotificationCenter.default.removeObserver(audioSelectionObserver)
        }
        preparedAsset?.stop()
        if let subtitleUseCase, let subtitleIdentity {
            let previousReset = subtitleResetTask
            Task {
                await previousReset?.value
                await subtitleUseCase.reset(for: subtitleIdentity)
            }
        }
        eventContinuation.finish()
        failureContinuation.finish()
    }

    public var currentTimelineSnapshot: PlaybackTimelineSnapshot {
        timeline.currentSnapshot
    }

    public var nativeSubtitlesEnabled: Bool {
        subtitleUseCase != nil
    }

    public func toggleNativeSubtitles() async -> NativeSubtitleToggleResult {
        guard subtitleUseCase != nil, let item = player.currentItem else {
            return .unavailable
        }
        let operationID = UUID()
        let generation = loadGeneration
        subtitleToggleOperationID = operationID

        do {
            guard
                let group = try await item.asset.loadMediaSelectionGroup(
                    for: .legible
                ),
                !Task.isCancelled,
                subtitleToggleOperationID == operationID,
                loadGeneration == generation,
                player.currentItem === item
            else {
                finishSubtitleToggle(operationID)
                return .unavailable
            }

            if let selected = item.currentMediaSelection.selectedMediaOption(
                in: group
            ) {
                guard group.allowsEmptySelection else {
                    finishSubtitleToggle(operationID)
                    return .unavailable
                }
                lastSubtitleSelection = Self.subtitlePreference(for: selected)
                item.select(nil, in: group)
                finishSubtitleToggle(operationID)
                return .disabled
            }

            guard
                let option = Self.subtitleOption(
                    in: group,
                    restoring: lastSubtitleSelection
                )
            else {
                finishSubtitleToggle(operationID)
                return .unavailable
            }
            item.select(option, in: group)
            lastSubtitleSelection = Self.subtitlePreference(for: option)
            finishSubtitleToggle(operationID)
            return .enabled(label: option.displayName)
        } catch {
            finishSubtitleToggle(operationID)
            return .unavailable
        }
    }

    public func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        timeline.updates()
    }

    public func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        failureEvents
    }

    /// 准备并安装一个新播放项目；调用方取消会沿 generation 边界清理本次全部资源。
    public func load(
        _ request: PlaybackRequest,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent = PlaybackLoadIntent()
    ) async throws {
        let generation = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await performLoad(
                request,
                identity: identity,
                intent: intent,
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

    public func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        try await load(
            PlaybackRequest(
                manifest: playback.manifest,
                mediaHeaders: playback.mediaHeaders
            ),
            identity: identity,
            intent: intent
        )
    }

    private func performLoad(
        _ request: PlaybackRequest,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        generation: UUID
    ) async throws {
        // 每次新 load 只在准备前读取一次；设置变化不会触碰当前 AVPlayerItem。
        let sourcePreference = sourcePreferenceProvider()
        let loudnessNormalizationEnabled =
            loudnessNormalizationEnabledProvider()
        let videos = try selectedVideos(for: request).map {
            PlaybackSourceOrdering.applying(sourcePreference, to: $0)
        }
        let audioTracks = try selectedAudioTracks(for: request)
        try Task.checkCancellation()

        loadGeneration = generation
        activeSeekOperationID = nil
        invalidateSubtitleToggle(clearPreference: true)
        invalidateTransportSeek()
        loadIntent = intent
        activeResumeToken = nil
        restartOperation = nil
        loadTask?.cancel()
        loadTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        clearLoudnessNormalization()
        preparedAsset?.stop()
        preparedAsset = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        let pendingSubtitleReset = enqueueSubtitleReset()
        timeline.begin(identity: identity)
        emit(.stateChanged(.loading))

        await pendingSubtitleReset?.value
        try Task.checkCancellation()
        guard loadGeneration == generation else {
            throw CancellationError()
        }
        let subtitleSource = subtitleUseCase.map {
            NativeSubtitleSource(useCase: $0, identity: identity)
        }
        if subtitleSource != nil {
            subtitleIdentity = identity
        }
        let task = Task {
            try await bridge.prepare(
                videos: videos,
                audioTracks: audioTracks,
                headers: request.mediaHeaders,
                subtitleSource: subtitleSource
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
            if LoudnessNormalizationRuntimePolicy.shouldInstall(
                enabled: loudnessNormalizationEnabled,
                hasMetadata: audioTracks.contains {
                    $0.track.loudnessMetadata != nil
                }
            ),
                let defaultTrack = audioTracks.first(where: {
                    $0.track.isDefault
                }),
                let tap = LoudnessProcessingTap.make(
                    initialGain: LoudnessNormalizationPolicy().linearGain(
                        for: defaultTrack.track.loudnessMetadata
                    )
                )
            {
                loudnessTap = tap
                loudnessAudioTracks = audioTracks.map(\.track)
                item.audioMix = tap.makeAudioMix()
            }
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
            beginObservingAudioSelection(for: item, generation: generation)
            let audioSelectionOperationID = audioSelectionOperation.begin()
            await updateSelectedAudioGain(
                for: item,
                generation: generation,
                operationID: audioSelectionOperationID
            )
            emit(.stateChanged(.ready))
        } catch is CancellationError {
            if loadGeneration == generation {
                loadTask = nil
                readinessTask = nil
                clearLoudnessNormalization()
                activeSeekOperationID = nil
                preparedAsset?.stop()
                preparedAsset = nil
                player.replaceCurrentItem(with: nil)
                timeline.clear()
                _ = enqueueSubtitleReset()
                emit(.stateChanged(.idle))
            }
            throw CancellationError()
        } catch {
            if loadGeneration == generation {
                loadTask = nil
                readinessTask = nil
                clearLoudnessNormalization()
                activeSeekOperationID = nil
                preparedAsset?.stop()
                preparedAsset = nil
                player.replaceCurrentItem(with: nil)
                timeline.markFailed()
                _ = enqueueSubtitleReset()
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
        activeSeekOperationID = nil
        invalidateSubtitleToggle(clearPreference: true)
        invalidateTransportSeek()
        loadIntent = nil
        activeResumeToken = nil
        restartOperation = nil
        loadTask?.cancel()
        loadTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        clearLoudnessNormalization()
        preparedAsset?.stop()
        preparedAsset = nil
        player.replaceCurrentItem(with: nil)
        timeline.clear()
        _ = enqueueSubtitleReset()
        emit(.stateChanged(.idle))
    }

    /// 当前 item 保持暂停，先完成受 intent 和交互 revision 保护的首次定位，再开始播放。
    public func beginPlayback(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        initialPositionSeconds: Double?
    ) async -> PlaybackStartOutcome {
        guard loadIntent == intent,
            timeline.currentSnapshot.identity == identity,
            !timeline.hasObservedPlaybackInteraction,
            player.currentTime().seconds.isFinite,
            player.currentTime().seconds >= 0,
            player.currentTime().seconds <= 0.25,
            timeline.currentSnapshot.state == .ready
                || timeline.currentSnapshot.state == .paused,
            let item = player.currentItem
        else { return .rejected }

        let currentGeneration = loadGeneration
        let interactionRevision = timeline.playbackInteractionRevision
        guard let initialPositionSeconds,
            let durationSeconds = Self.validSeconds(item.duration),
            initialPositionSeconds.isFinite,
            initialPositionSeconds > 0,
            initialPositionSeconds < durationSeconds - 0.05
        else {
            activeResumeToken = nil
            play()
            return .startedAtBeginning
        }

        let operation = UUID()
        activeSeekOperationID = operation
        timeline.prepareInitialSeek(
            operationID: operation,
            to: initialPositionSeconds
        )
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        let didSeek = await player.seek(
            to: CMTime(seconds: initialPositionSeconds, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
        guard activeSeekOperationID == operation else {
            if !didSeek {
                timeline.discardStaleSeekLanding(operationID: operation)
            }
            return .rejected
        }
        guard didSeek else {
            timeline.initialSeekFailed(operationID: operation)
            activeSeekOperationID = nil
            return .preparationFailed
        }
        guard loadGeneration == currentGeneration,
            loadIntent == intent,
            player.currentItem === item,
            timeline.currentSnapshot.identity == identity,
            timeline.playbackInteractionRevision == interactionRevision,
            timeline.currentSnapshot.state == .ready
                || timeline.currentSnapshot.state == .paused
                || timeline.currentSnapshot.state == .buffering
        else {
            if player.currentItem === item {
                timeline.initialSeekFailed(operationID: operation)
            }
            activeSeekOperationID = nil
            return .rejected
        }

        guard
            let resolvedPosition = Self.validatedResolvedInitialPosition(
                player.currentTime(),
                durationSeconds: durationSeconds
            )
        else {
            timeline.initialSeekFailed(operationID: operation)
            activeSeekOperationID = nil
            return .preparationFailed
        }
        timeline.initialSeekCompleted(
            operationID: operation,
            at: resolvedPosition
        )
        activeSeekOperationID = nil
        let token = PlaybackResumeToken()
        activeResumeToken = token
        timeline.playAfterInternalSeek()
        emit(.stateChanged(.playing))
        return .resumed(
            positionSeconds: resolvedPosition,
            token: token,
            discontinuityGeneration:
                timeline.currentSnapshot.discontinuityGeneration
        )
    }

    public func restartFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        resumeToken: PlaybackResumeToken
    ) async -> Bool {
        guard activeResumeToken == resumeToken,
            restartOperation == nil,
            loadIntent == intent,
            timeline.currentSnapshot.identity == identity,
            let item = player.currentItem
        else { return false }
        let operation = UUID()
        supersedeTransportSeek()
        activeSeekOperationID = operation
        restartOperation = operation
        defer {
            if restartOperation == operation {
                restartOperation = nil
            }
        }
        let currentGeneration = loadGeneration
        timeline.prepareResumeRestart(operationID: operation)
        let interactionRevision = timeline.playbackInteractionRevision
        let didSeek = await player.seek(
            to: .zero,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        guard restartOperation == operation else {
            if !didSeek {
                timeline.discardStaleSeekLanding(operationID: operation)
            }
            return false
        }
        guard didSeek else {
            timeline.resumeRestartFailed(operationID: operation)
            activeSeekOperationID = nil
            return false
        }
        guard activeResumeToken == resumeToken,
            loadGeneration == currentGeneration,
            loadIntent == intent,
            player.currentItem === item,
            timeline.currentSnapshot.identity == identity,
            timeline.playbackInteractionRevision == interactionRevision
        else {
            if player.currentItem === item {
                timeline.resumeRestartFailed(operationID: operation)
            }
            activeSeekOperationID = nil
            return false
        }
        guard let resolvedPosition = Self.validSeconds(player.currentTime()),
            resolvedPosition <= 0.5
        else {
            timeline.resumeRestartFailed(operationID: operation)
            activeSeekOperationID = nil
            return false
        }
        timeline.resumeRestartCompleted(operationID: operation)
        activeSeekOperationID = nil
        activeResumeToken = nil
        timeline.playAfterInternalSeek()
        emit(.stateChanged(.playing))
        return true
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

    @discardableResult
    public func togglePlayback() -> Bool? {
        guard player.currentItem != nil,
            let action = PlaybackToggleAction(
                timeControlStatus: player.timeControlStatus,
                timelineState: currentTimelineSnapshot.state
            )
        else { return nil }
        switch action {
        case .play:
            play()
            return true
        case .pause:
            pause()
            return false
        }
    }

    public func setRate(_ rate: Double) throws {
        try timeline.setRate(rate)
    }

    /// 临时改变当前播放速率，但不覆盖用户选择的永久速率。
    public func beginMomentaryPlaybackRate(_ rate: Double) throws -> UUID? {
        try timeline.beginMomentaryRate(rate)
    }

    /// 结束仍匹配的临时速率会话；过期会话不会影响新的播放项目或用户改速。
    public func endMomentaryPlaybackRate(sessionID: UUID) {
        timeline.endMomentaryRate(sessionID: sessionID)
    }

    /// 在当前 VOD item 上累计执行播放器 transport 的相对跳转。
    @discardableResult
    public func seekByTransportOffset(_ offsetSeconds: Double) -> Bool {
        guard let item = player.currentItem,
            let currentSeconds = Self.validSeconds(player.currentTime()),
            let durationSeconds = Self.validSeconds(item.duration)
        else { return false }
        let generation = loadGeneration
        let itemIdentity = ObjectIdentifier(item)
        guard
            let operation = transportSeek.prepare(
                offsetSeconds: offsetSeconds,
                currentSeconds: currentSeconds,
                durationSeconds: durationSeconds,
                generation: generation,
                itemIdentity: itemIdentity
            )
        else { return false }

        restartOperation = nil
        activeSeekOperationID = operation.id
        timeline.prepareTransportSeek(
            operationID: operation.id,
            to: operation.targetSeconds
        )
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(
            to: CMTime(
                seconds: operation.targetSeconds,
                preferredTimescale: 600
            ),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self, weak item] finished in
            guard let item else { return }
            Task { @MainActor [weak self] in
                guard let self,
                    self.loadGeneration == generation,
                    self.player.currentItem === item
                else { return }
                guard self.activeSeekOperationID == operation.id,
                    self.transportSeek.matches(operation)
                else {
                    if !finished {
                        self.timeline.discardStaleSeekLanding(
                            operationID: operation.id
                        )
                    }
                    return
                }
                let resolved =
                    finished ? Self.validSeconds(self.player.currentTime()) : nil
                switch self.transportSeek.complete(
                    operation,
                    finished: finished,
                    resolvedPositionSeconds: resolved
                ) {
                case .ignored:
                    return
                case .failed:
                    self.timeline.transportSeekFailed(
                        operationID: operation.id
                    )
                    self.activeSeekOperationID = nil
                case .completed(let positionSeconds):
                    self.timeline.transportSeekCompleted(
                        operationID: operation.id,
                        at: positionSeconds
                    )
                    self.activeSeekOperationID = nil
                }
            }
        }
        return true
    }

    /// 执行精确 seek，并只为一次用户 seek 发布一个 discontinuity generation。
    public func seek(to time: Duration) async throws {
        guard let item = player.currentItem else {
            throw AVPlayerEngineError.seekFailed
        }
        let generation = loadGeneration
        let operation = UUID()
        restartOperation = nil
        supersedeTransportSeek()
        activeSeekOperationID = operation
        let components = time.components
        let seconds =
            Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        timeline.prepareExplicitSeek(operationID: operation, to: seconds)
        let didSeek = await player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        guard activeSeekOperationID == operation,
            loadGeneration == generation,
            player.currentItem === item
        else {
            if !didSeek {
                timeline.discardStaleSeekLanding(operationID: operation)
            }
            throw CancellationError()
        }
        guard didSeek else {
            timeline.explicitSeekFailed(operationID: operation)
            activeSeekOperationID = nil
            throw AVPlayerEngineError.seekFailed
        }
        timeline.explicitSeekCompleted(operationID: operation, at: seconds)
        activeSeekOperationID = nil
    }

    /// 同步接受当前 item 上的精确 seek，并在 engine 内完成 generation-safe 的异步收尾。
    ///
    /// 返回 `true` 表示 AVPlayer 已经收到请求；系统远程命令的同步 handler 无法等待完成回调。
    @discardableResult
    public func requestSeek(to time: Duration) -> Bool {
        guard let item = player.currentItem,
            let duration = currentTimelineSnapshot.durationSeconds
        else { return false }
        let components = time.components
        let seconds =
            Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        guard seconds.isFinite, seconds >= 0, seconds <= duration else {
            return false
        }

        let generation = loadGeneration
        let operation = UUID()
        restartOperation = nil
        supersedeTransportSeek()
        activeSeekOperationID = operation
        timeline.prepareExplicitSeek(operationID: operation, to: seconds)
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak item] didSeek in
            Task { @MainActor in
                guard let self, let item,
                    self.loadGeneration == generation,
                    self.player.currentItem === item
                else { return }
                guard self.activeSeekOperationID == operation else {
                    if !didSeek {
                        self.timeline.discardStaleSeekLanding(
                            operationID: operation
                        )
                    }
                    return
                }
                self.activeSeekOperationID = nil
                if didSeek {
                    self.timeline.explicitSeekCompleted(
                        operationID: operation,
                        at: seconds
                    )
                } else {
                    self.timeline.explicitSeekFailed(operationID: operation)
                }
            }
        }
        return true
    }

    /// 幂等终止当前及在途播放，将唯一时间线恢复为 `.idle` 状态。
    public func stop() {
        loadGeneration = UUID()
        activeSeekOperationID = nil
        invalidateSubtitleToggle(clearPreference: true)
        invalidateTransportSeek()
        loadIntent = nil
        activeResumeToken = nil
        restartOperation = nil
        loadTask?.cancel()
        loadTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        clearLoudnessNormalization()
        player.pause()
        player.replaceCurrentItem(with: nil)
        preparedAsset?.stop()
        preparedAsset = nil
        timeline.clear()
        _ = enqueueSubtitleReset()
        emit(.stateChanged(.idle))
    }

    private static func validSeconds(_ time: CMTime) -> Double? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private static func subtitlePreference(
        for option: AVMediaSelectionOption
    ) -> NativeSubtitleSelectionPreference {
        NativeSubtitleSelectionPreference(
            propertyListData: try? PropertyListSerialization.data(
                fromPropertyList: option.propertyList(),
                format: .binary,
                options: 0
            )
        )
    }

    private static func subtitleOption(
        in group: AVMediaSelectionGroup,
        restoring preference: NativeSubtitleSelectionPreference?
    ) -> AVMediaSelectionOption? {
        let playable = AVMediaSelectionGroup.playableMediaSelectionOptions(
            from: group.options
        )
        guard !playable.isEmpty else { return nil }
        if let preference {
            if let data = preference.propertyListData,
                let propertyList = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ),
                let exact = group.mediaSelectionOption(
                    withPropertyList: propertyList
                ),
                exact.isPlayable
            {
                return exact
            }
        }
        let preferred = AVMediaSelectionGroup.mediaSelectionOptions(
            from: playable,
            filteredAndSortedAccordingToPreferredLanguages:
                Locale.preferredLanguages
        )
        return preferred.first ?? playable.first
    }

    private func finishSubtitleToggle(_ operationID: UUID) {
        guard subtitleToggleOperationID == operationID else { return }
        subtitleToggleOperationID = nil
    }

    private func invalidateSubtitleToggle(clearPreference: Bool) {
        subtitleToggleOperationID = nil
        if clearPreference {
            lastSubtitleSelection = nil
        }
    }

    static func validatedResolvedInitialPosition(
        _ time: CMTime,
        durationSeconds: Double
    ) -> Double? {
        guard let positionSeconds = validSeconds(time),
            durationSeconds.isFinite,
            positionSeconds > 0.25,
            positionSeconds < durationSeconds - 0.05
        else { return nil }
        return positionSeconds
    }

    private func selectedVideos(
        for request: PlaybackRequest
    ) throws -> [MediaRepresentation] {
        if let preferredID = request.preferredVideoRepresentationID {
            guard
                let representation = request.manifest.videoRepresentations.first(
                    where: { $0.id == preferredID }
                )
            else {
                throw AVPlayerEngineError.preferredVideoRepresentationNotFound(
                    preferredID
                )
            }
            return [representation]
        }
        guard !request.manifest.videoRepresentations.isEmpty else {
            throw AVPlayerEngineError.missingVideoRepresentation
        }
        return request.manifest.videoRepresentations
    }

    func selectedAudioTracks(
        for request: PlaybackRequest
    ) throws -> [SelectedPlaybackAudioTrack] {
        guard !request.manifest.audioTracks.isEmpty else {
            throw AVPlayerEngineError.missingAudioRepresentation
        }
        var trackIDs = Set<String>()
        for track in request.manifest.audioTracks {
            guard trackIDs.insert(track.id).inserted else {
                throw AVPlayerEngineError.duplicateAudioTrackID(track.id)
            }
        }
        for trackID in request.preferredAudioRepresentationIDs.keys
        where !trackIDs.contains(trackID) {
            throw AVPlayerEngineError.preferredAudioTrackNotFound(trackID)
        }
        let defaultTracks = request.manifest.audioTracks.filter(\.isDefault)
        guard defaultTracks.count == 1 else {
            throw AVPlayerEngineError.invalidDefaultAudioTrackCount(
                defaultTracks.count
            )
        }

        return try request.manifest.audioTracks.map { track in
            for representation in track.representations
            where representation.kind != .audio {
                throw AVPlayerEngineError.invalidAudioTrackRepresentation(
                    trackID: track.id,
                    representationID: representation.id
                )
            }
            let representation: MediaRepresentation
            if let preferredID =
                request.preferredAudioRepresentationIDs[track.id]
            {
                guard
                    let preferred = track.representations.first(
                        where: { $0.id == preferredID }
                    )
                else {
                    throw
                        AVPlayerEngineError
                        .preferredAudioRepresentationNotFound(
                            trackID: track.id,
                            representationID: preferredID
                        )
                }
                representation = preferred
            } else {
                guard let first = track.representations.first else {
                    throw AVPlayerEngineError.missingAudioTrackRepresentation(
                        track.id
                    )
                }
                representation = first
            }
            return SelectedPlaybackAudioTrack(
                track: track,
                representation: representation
            )
        }
    }

    private func emit(_ event: PlayerEvent) {
        eventContinuation.yield(event)
    }

    private func handleCurrentItemFailure() {
        guard let identity = timeline.currentSnapshot.identity,
            let intent = loadIntent
        else { return }
        loadGeneration = UUID()
        activeSeekOperationID = nil
        invalidateSubtitleToggle(clearPreference: true)
        invalidateTransportSeek()
        loadIntent = nil
        loadTask?.cancel()
        loadTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        clearLoudnessNormalization()
        player.pause()
        player.replaceCurrentItem(with: nil)
        preparedAsset?.stop()
        preparedAsset = nil
        _ = enqueueSubtitleReset()
        failureContinuation.yield(
            PlaybackFailureEvent(identity: identity, intent: intent)
        )
        emit(.failed(message: "PlaybackItemFailed"))
    }

    private func beginObservingAudioSelection(
        for item: AVPlayerItem,
        generation: UUID
    ) {
        guard loudnessTap != nil else { return }
        audioSelectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let item else { return }
            Task { @MainActor [weak self, weak item] in
                guard let self, let item,
                    self.loadGeneration == generation,
                    self.player.currentItem === item
                else { return }
                self.audioSelectionTask?.cancel()
                let operationID = self.audioSelectionOperation.begin()
                let task = Task { @MainActor [weak self, weak item] in
                    guard let self, let item else { return }
                    await self.updateSelectedAudioGain(
                        for: item,
                        generation: generation,
                        operationID: operationID
                    )
                }
                self.audioSelectionTask = task
            }
        }
    }

    private func updateSelectedAudioGain(
        for item: AVPlayerItem,
        generation: UUID,
        operationID: UUID
    ) async {
        guard let loudnessTap,
            isCurrentAudioSelectionOperation(
                operationID,
                generation: generation,
                item: item,
                tap: loudnessTap
            )
        else { return }

        let group: AVMediaSelectionGroup?
        do {
            group = try await item.asset.loadMediaSelectionGroup(for: .audible)
        } catch {
            guard
                isCurrentAudioSelectionOperation(
                    operationID,
                    generation: generation,
                    item: item,
                    tap: loudnessTap
                )
            else { return }
            loudnessTap.setTargetGain(1)
            return
        }

        guard
            isCurrentAudioSelectionOperation(
                operationID,
                generation: generation,
                item: item,
                tap: loudnessTap
            )
        else { return }

        let metadata: PlaybackLoudnessMetadata?
        if let group,
            let option = item.currentMediaSelection.selectedMediaOption(in: group)
        {
            let matches = loudnessAudioTracks.filter {
                Self.matches($0, option: option)
            }
            metadata = matches.count == 1 ? matches[0].loudnessMetadata : nil
        } else {
            metadata = nil
        }
        loudnessTap.setTargetGain(
            LoudnessNormalizationPolicy().linearGain(for: metadata)
        )
    }

    private func isCurrentAudioSelectionOperation(
        _ operationID: UUID,
        generation: UUID,
        item: AVPlayerItem,
        tap: LoudnessProcessingTap
    ) -> Bool {
        !Task.isCancelled
            && audioSelectionOperation.matches(operationID)
            && loadGeneration == generation
            && player.currentItem === item
            && loudnessTap === tap
    }

    private static func matches(
        _ track: PlaybackAudioTrack,
        option: AVMediaSelectionOption
    ) -> Bool {
        let expectedLanguage = (track.languageTag ?? "und")
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let actualLanguage = (option.locale?.identifier ?? "und")
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let characteristic = AVMediaCharacteristic(
            rawValue:
                track.role == .original
                ? "public.original-content" : "public.machine-generated"
        )
        return option.displayName == track.displayName
            && actualLanguage == expectedLanguage
            && option.hasMediaCharacteristic(characteristic)
    }

    private func clearLoudnessNormalization() {
        audioSelectionTask?.cancel()
        audioSelectionTask = nil
        audioSelectionOperation.invalidate()
        if let audioSelectionObserver {
            NotificationCenter.default.removeObserver(audioSelectionObserver)
        }
        audioSelectionObserver = nil
        loudnessAudioTracks = []
        loudnessTap = nil
    }

    private func invalidateTransportSeek() {
        guard let operation = transportSeek.invalidate() else { return }
        timeline.transportSeekFailed(operationID: operation.id)
        if activeSeekOperationID == operation.id {
            activeSeekOperationID = nil
        }
    }

    private func supersedeTransportSeek() {
        guard let operation = transportSeek.invalidate() else { return }
        if activeSeekOperationID == operation.id {
            activeSeekOperationID = nil
        }
    }

    private func handleSeekSupersededByExternalJump(_ operationID: UUID) {
        guard activeSeekOperationID == operationID else { return }
        activeSeekOperationID = nil
        if restartOperation == operationID {
            restartOperation = nil
        }
        if transportSeek.current?.id == operationID {
            transportSeek.invalidate()
        }
    }

    @discardableResult
    private func enqueueSubtitleReset() -> Task<Void, Never>? {
        guard let subtitleUseCase, let identity = subtitleIdentity else {
            return subtitleResetTask
        }
        subtitleIdentity = nil
        let previousReset = subtitleResetTask
        let task = Task {
            await previousReset?.value
            await subtitleUseCase.reset(for: identity)
        }
        subtitleResetTask = task
        return task
    }
}
