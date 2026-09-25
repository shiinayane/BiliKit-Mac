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
    case itemFailed(errorType: String)
    case invalidPlaybackRate
}

public enum NativeSubtitleToggleResult: Sendable, Equatable {
    case enabled(label: String)
    case disabled
    case unavailable
}

private struct NativeSubtitleSelectionPreference: Sendable {
    let propertyListData: Data?
}

/// 断点续播与 seek 的时间策略。
private enum SeekPolicy {
    static let timescale: CMTimeScale = 600
    /// 断点续播与 transport 相对跳转允许落在最近的可解码位置。
    static let resumeTolerance = CMTime(seconds: 0.25, preferredTimescale: timescale)
    /// 不超过该位置视为仍在开头：可自动起播，也不值得作为续播落点。
    static let beginningThresholdSeconds = 0.25
    /// 续播落点离结尾至少保留的余量。
    static let endMarginSeconds = 0.05
    /// “从头播放”的落点不超过该位置才算成功。
    static let restartLandingLimitSeconds = 0.5
}

private enum SeekSettlement: Equatable {
    /// 已被更新的 seek、重新 load 或外部时间跳变取代。
    case superseded
    /// AVPlayer 未完成 seek，或落点不满足调用方要求。
    case failed
    /// 等待期间 load、intent、identity 或用户交互已变化。
    case contextChanged
    case landed(positionSeconds: Double)
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

    private let bridge: DASHToHLSBridge
    private let subtitleUseCase: SubtitleUseCase?
    private let sourcePreferenceProvider: @MainActor @Sendable () -> PlaybackSourcePreference
    private let loudnessNormalizationEnabledProvider: @MainActor @Sendable () -> Bool
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
    private let loudness = LoudnessNormalizationController()

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
        let failureStream = AsyncStream<PlaybackFailureEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        failureEvents = failureStream.stream
        failureContinuation = failureStream.continuation
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
        preparedAsset?.stop()
        if let subtitleUseCase, let subtitleIdentity {
            let previousReset = subtitleResetTask
            Task {
                await previousReset?.value
                await subtitleUseCase.reset(for: subtitleIdentity)
            }
        }
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

    public func observeTimeline(
        _ observer: @escaping @MainActor (PlaybackTimelineSnapshot) -> Void
    ) -> @MainActor @Sendable () -> Void {
        timeline.observe(observer)
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
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        try await load(
            PlaybackRequest(
                media: playback.media,
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
        let progressiveSource: ProgressivePlaybackSource?
        let videos: [MediaRepresentation]
        let audioTracks: [SelectedPlaybackAudioTrack]
        switch request.media {
        case .dash(let manifest):
            progressiveSource = nil
            videos = try manifest.selectedVideos().map {
                PlaybackSourceOrdering.applying(sourcePreference, to: $0)
            }
            audioTracks = try manifest.selectedAudioTracks()
        case .progressive(let source):
            progressiveSource = source
            videos = []
            audioTracks = []
        }
        try Task.checkCancellation()

        releaseCurrentPlayback(nextGeneration: generation, nextIntent: intent)
        let pendingSubtitleReset = enqueueSubtitleReset()
        timeline.begin(identity: identity, loadIntent: intent)

        await pendingSubtitleReset?.value
        try Task.checkCancellation()
        guard loadGeneration == generation else {
            throw CancellationError()
        }
        let subtitleSource =
            progressiveSource == nil
            ? subtitleUseCase.map {
                NativeSubtitleSource(useCase: $0, identity: identity)
            } : nil
        if subtitleSource != nil {
            subtitleIdentity = identity
        }
        let task = Task {
            if let progressiveSource {
                try await bridge.prepare(
                    progressive: progressiveSource,
                    headers: request.mediaHeaders
                )
            } else {
                try await bridge.prepare(
                    videos: videos,
                    audioTracks: audioTracks,
                    headers: request.mediaHeaders,
                    subtitleSource: subtitleSource
                )
            }
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
            loudness.install(
                on: item,
                audioTracks: audioTracks,
                enabled: loudnessNormalizationEnabled
            )
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
            if progressiveSource != nil,
                let endTime = try await Self.lastPresentableMediaEndTime(
                    in: item.asset
                )
            {
                item.forwardPlaybackEndTime = endTime
            }
            try Task.checkCancellation()
            guard loadGeneration == generation else {
                throw CancellationError()
            }
            self.readinessTask = nil
            timeline.markReady(duration: item.duration)
            await loudness.activate()
        } catch is CancellationError {
            if loadGeneration == generation {
                resetToIdle()
            }
            throw CancellationError()
        } catch {
            if loadGeneration == generation {
                releaseCurrentPlayback()
                timeline.markFailed()
                _ = enqueueSubtitleReset()
            }
            throw error
        }
    }

    private func cancelLoad(generation: UUID) {
        guard loadGeneration == generation else { return }
        resetToIdle()
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
            player.currentTime().seconds <= SeekPolicy.beginningThresholdSeconds,
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
            initialPositionSeconds < durationSeconds - SeekPolicy.endMarginSeconds
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
        let didSeek = await seek(
            to: initialPositionSeconds,
            tolerance: SeekPolicy.resumeTolerance
        )
        let settlement = settleSeek(
            operation,
            didSeek: didSeek,
            isOwned: activeSeekOperationID == operation,
            item: item,
            contextIsValid: loadGeneration == currentGeneration
                && loadIntent == intent
                && player.currentItem === item
                && timeline.currentSnapshot.identity == identity
                && timeline.playbackInteractionRevision == interactionRevision
                && (timeline.currentSnapshot.state == .ready
                    || timeline.currentSnapshot.state == .paused
                    || timeline.currentSnapshot.state == .buffering)
        ) {
            Self.validatedResolvedInitialPosition(
                player.currentTime(),
                durationSeconds: durationSeconds
            )
        }
        switch settlement {
        case .superseded, .contextChanged:
            return .rejected
        case .failed:
            return .preparationFailed
        case .landed(let resolvedPosition):
            let token = PlaybackResumeToken()
            activeResumeToken = token
            timeline.playAfterInternalSeek()
            return .resumed(
                positionSeconds: resolvedPosition,
                token: token,
                discontinuityGeneration:
                    timeline.currentSnapshot.discontinuityGeneration
            )
        }
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
        let didSeek = await seek(to: 0, tolerance: .zero)
        let settlement = settleSeek(
            operation,
            didSeek: didSeek,
            isOwned: restartOperation == operation,
            item: item,
            contextIsValid: activeResumeToken == resumeToken
                && loadGeneration == currentGeneration
                && loadIntent == intent
                && player.currentItem === item
                && timeline.currentSnapshot.identity == identity
                && timeline.playbackInteractionRevision == interactionRevision
        ) {
            // 断点浮层只接受真正回到开头附近的落点，时间线统一记为 0 秒。
            guard let resolvedPosition = Self.validSeconds(player.currentTime()),
                resolvedPosition <= SeekPolicy.restartLandingLimitSeconds
            else { return nil }
            return 0
        }
        guard case .landed = settlement else { return false }
        activeResumeToken = nil
        timeline.playAfterInternalSeek()
        return true
    }

    public func play() {
        guard player.currentItem != nil else { return }
        timeline.play()
    }

    public func pause() {
        guard player.currentItem != nil else { return }
        timeline.pause()
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
        timeline.prepareObservedSeek(
            operationID: operation.id,
            to: operation.targetSeconds
        )
        issueSeek(
            to: operation.targetSeconds,
            tolerance: SeekPolicy.resumeTolerance,
            generation: generation,
            item: item
        ) { engine, finished in
            let isOwned =
                engine.activeSeekOperationID == operation.id
                && engine.transportSeek.matches(operation)
            var landing: Double?
            if isOwned,
                case .completed(let positionSeconds) = engine.transportSeek.complete(
                    operation,
                    finished: finished,
                    resolvedPositionSeconds: finished
                        ? Self.validSeconds(engine.player.currentTime()) : nil
                )
            {
                landing = positionSeconds
            }
            engine.settleSeek(
                operation.id,
                didSeek: finished,
                isOwned: isOwned,
                item: item
            ) { landing }
        }
        return true
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
        timeline.prepareObservedSeek(operationID: operation, to: seconds)
        issueSeek(
            to: seconds,
            tolerance: .zero,
            generation: generation,
            item: item
        ) { engine, didSeek in
            engine.settleSeek(
                operation,
                didSeek: didSeek,
                isOwned: engine.activeSeekOperationID == operation,
                item: item
            ) { seconds }
        }
        return true
    }

    /// 以 AVPlayer 的异步接口等待 seek 完成。
    private func seek(to seconds: Double, tolerance: CMTime) async -> Bool {
        await player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: SeekPolicy.timescale),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    /// 同步向 AVPlayer 发出 seek，调用方可立即返回；完成回调回到 main actor，旧 load 或旧 item
    /// 的回调静默丢弃。
    private func issueSeek(
        to seconds: Double,
        tolerance: CMTime,
        generation: UUID,
        item: AVPlayerItem,
        settle: @escaping @MainActor (AVPlayerEngine, Bool) -> Void
    ) {
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: SeekPolicy.timescale),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self, weak item] finished in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item,
                    self.loadGeneration == generation,
                    self.player.currentItem === item
                else { return }
                settle(self, finished)
            }
        }
    }

    /// 所有 seek 入口共用的收尾：只有仍拥有该操作的调用方才能写回时间线并结束 `activeSeekOperationID`。
    ///
    /// 被取代的操作只丢弃失败落点；等待期间上下文变化时，仅当 item 仍在播放器上才撤销时间线的
    /// 待定 seek；`landing` 返回 nil 表示落点不合格。
    @discardableResult
    private func settleSeek(
        _ operationID: UUID,
        didSeek: Bool,
        isOwned: Bool,
        item: AVPlayerItem,
        contextIsValid: Bool = true,
        landing: () -> Double?
    ) -> SeekSettlement {
        guard isOwned else {
            if !didSeek {
                timeline.discardStaleSeekLanding(operationID: operationID)
            }
            return .superseded
        }
        guard didSeek else {
            timeline.seekFailed(operationID: operationID)
            activeSeekOperationID = nil
            return .failed
        }
        guard contextIsValid else {
            if player.currentItem === item {
                timeline.seekFailed(operationID: operationID)
            }
            activeSeekOperationID = nil
            return .contextChanged
        }
        guard let positionSeconds = landing() else {
            timeline.seekFailed(operationID: operationID)
            activeSeekOperationID = nil
            return .failed
        }
        timeline.seekCompleted(operationID: operationID, at: positionSeconds)
        activeSeekOperationID = nil
        return .landed(positionSeconds: positionSeconds)
    }

    /// 幂等终止当前及在途播放，将唯一时间线恢复为 `.idle` 状态。
    public func stop() {
        resetToIdle()
    }

    /// 使当前 load 世代失效，并释放播放项目及其派生状态：在途加载／就绪任务、响度处理、
    /// 字幕切换、seek、恢复与重新开始操作，以及 loopback 资源。
    ///
    /// 先移除 AVPlayerItem 再停止 loopback 资源，避免旧项目因资源消失而触发失败回调。
    /// 时间线终态、字幕重置与对外事件由调用方决定。
    private func releaseCurrentPlayback(
        nextGeneration: UUID = UUID(),
        nextIntent: PlaybackLoadIntent? = nil
    ) {
        loadGeneration = nextGeneration
        activeSeekOperationID = nil
        invalidateSubtitleToggle(clearPreference: true)
        invalidateTransportSeek()
        loadIntent = nextIntent
        activeResumeToken = nil
        restartOperation = nil
        loadTask?.cancel()
        loadTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        loudness.clear()
        player.pause()
        player.replaceCurrentItem(with: nil)
        preparedAsset?.stop()
        preparedAsset = nil
    }

    private func resetToIdle() {
        releaseCurrentPlayback()
        timeline.clear()
        _ = enqueueSubtitleReset()
    }

    private static func validSeconds(_ time: CMTime) -> Double? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    /// Progressive MP4 使用音视频轨道实际 timeRange 的最晚样本边界，不用服务端 length 减固定 tolerance。
    ///
    /// 空轨、无效时间或零时长保持系统默认结束语义。
    package static func lastPresentableMediaEndTime(
        in asset: AVAsset
    ) async throws -> CMTime? {
        let tracks = try await asset.load(.tracks).filter {
            $0.mediaType == .video || $0.mediaType == .audio
        }
        var latest: CMTime?
        for track in tracks {
            let timeRange = try await track.load(.timeRange)
            let end = CMTimeRangeGetEnd(timeRange)
            guard let seconds = validSeconds(end), seconds > 0 else { continue }
            if latest.map({ CMTimeCompare(end, $0) > 0 }) ?? true {
                latest = end
            }
        }
        return latest
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
            positionSeconds > SeekPolicy.beginningThresholdSeconds,
            positionSeconds < durationSeconds - SeekPolicy.endMarginSeconds
        else { return nil }
        return positionSeconds
    }

    private func handleCurrentItemFailure() {
        guard let identity = timeline.currentSnapshot.identity,
            let intent = loadIntent
        else { return }
        releaseCurrentPlayback()
        _ = enqueueSubtitleReset()
        failureContinuation.yield(
            PlaybackFailureEvent(identity: identity, intent: intent)
        )
    }

    private func invalidateTransportSeek() {
        guard let operation = transportSeek.invalidate() else { return }
        timeline.seekFailed(operationID: operation.id)
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
