@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import Foundation

/// 播放准备与控制的失败分类：媒体表示缺失或不一致、item 失败（只带错误类型名）与非法倍速。
public enum AVPlayerEngineError: Error, Sendable, Equatable {
    case missingVideoRepresentation
    case missingAudioTrackRepresentation(String)
    case duplicateAudioTrackID(String)
    case invalidDefaultAudioTrackCount(Int)
    case invalidAudioTrackRepresentation(trackID: String, representationID: Int)
    case itemFailed(errorType: String)
    case invalidPlaybackRate
}

/// 切换原生字幕的结果：已开启（带系统字幕选项的显示名）、已关闭，或当前 item 没有可切换的字幕。
public enum NativeSubtitleToggleResult: Sendable, Equatable {
    case enabled(label: String)
    case disabled
    case unavailable
}

/// AVPlayer、DASH→HLS 会话与统一播放时间线的唯一资源 owner。
///
/// 每次 load 与换源都用 UUID generation 取代旧准备流程；迟到 bridge/readiness 结果必须自毁而不能
/// 安装到当前 player。`stop` 同时释放 item、任务、loopback server、observer 与时间线 identity。
/// seek、原生字幕与换源分在同目录的扩展文件里，它们读写的状态因此不是 `private`，只由本类型及这些扩展使用。
@MainActor
public final class AVPlayerEngine:
    PlaybackControlling,
    PlaybackTimelineProviding
{
    public let player: AVPlayer

    private let bridge: DASHToHLSBridge
    private let subtitleUseCase: SubtitleUseCase
    private let loadPreferencesProvider: @MainActor @Sendable () -> PlaybackLoadPreferences
    private let failureEvents = AsyncBroadcast<PlaybackFailureEvent>()
    let sourceExpiryEvents = AsyncBroadcast<PlaybackSourceExpiryEvent>()
    let timeline: AVPlayerTimelineAdapter
    private var loadTask: Task<PreparedPlaybackAsset, any Error>?
    private var readinessTask: Task<Void, any Error>?
    /// 每次 load、换源、停止、失败与 item 失败都由 `releaseCurrentPlayback` 换新。
    ///
    /// 准备、就绪、seek 完成与字幕切换在 await 之后比对，不一致时停止迟到的 loopback
    /// 会话或丢弃回调。
    var loadGeneration = UUID()
    /// 当前 item 的 load intent；换源沿用同一个。
    var loadIntent: PlaybackLoadIntent?
    /// `beginPlayback` 报告续播时发出；只有持同一 token 的“从头播放”才执行，从头开始、release
    /// 或重新开始成功后清除。
    private var activeResumeToken: PlaybackResumeToken?
    /// 在途“从头播放”的操作 ID，同时只允许一个；新的 transport 或精确 seek 清掉它，旧的 restart
    /// 收尾时按被取代处理。
    var restartOperation: UUID?
    /// 当前拥有时间线待定 seek 的操作（从头播放、transport 或精确 seek），新 seek 覆盖它。
    ///
    /// 只有仍匹配的操作才能经 `settleSeek` 写回时间线；release 与外部时间跳变取代时清除。
    var activeSeekOperationID: UUID?
    private var preparedAsset: PreparedPlaybackAsset?
    private var subtitleIdentity: PlaybackItemIdentity?
    /// 字幕缓存按 identity 重置，重置 Task 串成链；新 load 先等上一次重置完成再取字幕目录，
    /// 旧重置不会清掉新目录。
    private var subtitleResetTask: Task<Void, Never>?
    /// 最近一次字幕切换的操作 ID；await 字幕组之后比对，不一致（被新切换或 release 取代）时返回
    /// `.unavailable`、不改选择。
    var subtitleToggleOperationID: UUID?
    var lastSubtitleSelection: NativeSubtitleSelectionPreference?
    var transportSeek = TransportSeekOperationState()
    /// 当前 item 的地址有效期，就绪时建立；release 时换回不检查。
    var sourceExpiry = PlaybackSourceExpiry.unchecked
    /// 已发出换源事件、等待 `refreshSource` 期间被推迟的播放意图；release 时清除。
    var pendingSourceRefresh: PendingSourceRefresh?
    /// 正在重建的换源 item 就绪后是否继续播放。
    ///
    /// 换源释放旧 item 后按被推迟的意图设置，重建期间的 `pause` 把它清掉（例如播放页此时被盖住），release 时清除。
    var sourceRefreshResumesPlayback = false
    /// 当前 item 的音频与字幕选项组，就绪时读取；release 时清除。
    var mediaSelectionGroups = NativeMediaSelectionGroups.none

    public init(
        player: AVPlayer,
        bridge: DASHToHLSBridge = DASHToHLSBridge(),
        subtitleUseCase: SubtitleUseCase,
        loadPreferencesProvider: @escaping @MainActor @Sendable () -> PlaybackLoadPreferences
    ) {
        self.player = player
        player.preventsDisplaySleepDuringVideoPlayback = true
        self.bridge = bridge
        self.subtitleUseCase = subtitleUseCase
        self.loadPreferencesProvider = loadPreferencesProvider
        // 起播的媒体选择只按播放列表的 DEFAULT：音频总是原声，字幕默认关闭。打开后系统会按界面语言
        // 挑 AUTOSELECT=YES 的 rendition，语言等于界面语言的 AI 配音会压过不写语言的原声。AI 配音另写
        // AUTOSELECT=NO，与这里共同保证起播是原声。
        player.appliesMediaSelectionCriteriaAutomatically = false
        timeline = AVPlayerTimelineAdapter(player: player)
        timeline.onFailed = { [weak self] in
            self?.handleCurrentItemFailure()
        }
        timeline.recoversFromFailure = { [weak self] snapshot in
            self?.recoverFromExpiredSourceFailure(snapshot) ?? false
        }
        timeline.onPlaybackStartedOutsideEngine = { [weak self] in
            self?.deferToSourceRefresh(resumesPlayback: true, targetSeconds: nil) ?? false
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
        if let subtitleIdentity {
            let previousReset = subtitleResetTask
            Task { [subtitleUseCase] in
                await previousReset?.value
                await subtitleUseCase.reset(for: subtitleIdentity)
            }
        }
    }

    public var currentTimelineSnapshot: PlaybackTimelineSnapshot {
        timeline.currentSnapshot
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
        failureEvents.subscribe(startingWith: nil)
    }

    public func playbackSourceExpiryEvents() -> AsyncStream<PlaybackSourceExpiryEvent> {
        sourceExpiryEvents.subscribe(startingWith: nil)
    }

    /// 准备并安装一个新播放项目；调用方取消会沿 generation 边界清理本次全部资源。
    public func load(
        _ request: PlaybackRequest,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent = PlaybackLoadIntent()
    ) async throws {
        try await install(request, identity: identity, intent: intent, continuing: nil)
    }

    /// load 与换源（`continuation` 非 nil）共用的安装入口；调用方取消时按 generation 清理。
    func install(
        _ request: PlaybackRequest,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        continuing continuation: PlaybackSourceContinuation?
    ) async throws {
        let generation = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await performLoad(
                request,
                identity: identity,
                intent: intent,
                generation: generation,
                continuing: continuation
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
        intent: PlaybackLoadIntent,
        startPositionSeconds: Double?
    ) async throws {
        try await load(
            PlaybackRequest(
                media: playback.media,
                mediaHeaders: playback.mediaHeaders,
                startPositionSeconds: startPositionSeconds,
                mediaExpiresAt: playback.mediaExpiresAt
            ),
            identity: identity,
            intent: intent
        )
    }

    private func performLoad(
        _ request: PlaybackRequest,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        generation: UUID,
        continuing continuation: PlaybackSourceContinuation?
    ) async throws {
        // 每次新 load 只在准备前读取一次；设置变化不会触碰当前 AVPlayerItem。
        let preferences = loadPreferencesProvider()
        let sourcePreference = preferences.sourcePreference
        let progressiveSource: ProgressivePlaybackSource?
        let videos: [MediaRepresentation]
        let fallbackVideos: [MediaRepresentation]
        let hdrVideos: [MediaRepresentation]
        let audioTracks: [SelectedPlaybackAudioTrack]
        switch request.media {
        case .dash(let manifest):
            progressiveSource = nil
            videos = try manifest.selectedVideos().map {
                PlaybackSourceOrdering.applying(sourcePreference, to: $0)
            }
            fallbackVideos = manifest.fallbackVideoRepresentations.map {
                PlaybackSourceOrdering.applying(sourcePreference, to: $0)
            }
            // `eligibleForHDRPlayback` 由系统按已连接的显示器与解码能力给出；App 的条件看不到它。
            let allowsHDR = preferences.allowsHDRVideo && AVPlayer.eligibleForHDRPlayback
            hdrVideos = (allowsHDR ? manifest.hdrVideoCandidates : []).map {
                PlaybackSourceOrdering.applying(sourcePreference, to: $0)
            }
            audioTracks = try manifest.selectedAudioTracks(
                allowsLosslessAudio: preferences.allowsLosslessAudio
            )
        case .progressive(let source):
            progressiveSource = source
            videos = []
            fallbackVideos = []
            hdrVideos = []
            audioTracks = []
        }
        try Task.checkCancellation()

        // 只有 DASH→HLS 能经 playlist 的 EXT-X-START 从续播位置起播；progressive 从头播放。
        let startPositionSeconds = request.startPositionSeconds.flatMap {
            progressiveSource == nil && $0.isFinite && $0 > 0 ? $0 : nil
        }
        releaseCurrentPlayback(nextGeneration: generation, nextIntent: intent)
        if let continuation {
            // 换源沿用同一 identity，字幕目录缓存仍然有效，不重置；时间线保留位置并记为暂停。
            sourceRefreshResumesPlayback = continuation.resumesPlayback
            timeline.beginReplacement(startPositionSeconds: continuation.positionSeconds)
        } else {
            let pendingSubtitleReset = enqueueSubtitleReset()
            timeline.begin(
                identity: identity,
                loadIntent: intent,
                startPositionSeconds: startPositionSeconds ?? 0
            )
            await pendingSubtitleReset?.value
            try Task.checkCancellation()
            guard loadGeneration == generation else {
                throw CancellationError()
            }
        }
        let subtitleSource =
            progressiveSource == nil
            ? NativeSubtitleSource(useCase: subtitleUseCase, identity: identity) : nil
        if subtitleSource != nil {
            subtitleIdentity = identity
        }
        let preparation = BridgePreparation(
            progressiveSource: progressiveSource,
            videos: videos,
            hdrVideos: hdrVideos,
            audioTracks: audioTracks,
            headers: request.mediaHeaders,
            subtitleSource: subtitleSource,
            startPositionSeconds: startPositionSeconds
        )

        do {
            let item: AVPlayerItem
            do {
                item = try await installReadyItem(preparation, generation: generation)
            } catch AVPlayerEngineError.itemFailed where !fallbackVideos.isEmpty {
                // 主阶梯（HEVC）的 item 在就绪前失败时，用同一份 playurl 的 AVC 阶梯在同一 generation 内
                // 重建一次：这台 Mac 不接受这种编码时，否则整条视频都放不了。错误里只有类型名，分不出是
                // 编码还是网络，所以凡是就绪前的 item 失败都回退；回退也失败就按普通失败处理，不再重试。
                // 失败从 readiness 传到这里要经过一次挂起：期间换了视频或这次 load 被取消时不得再回退，
                // 否则会动到新 load 的状态，或留下一个没人取消的准备与 loopback server。
                guard loadGeneration == generation, !Task.isCancelled else {
                    throw CancellationError()
                }
                discardFailedItem()
                item = try await installReadyItem(
                    preparation.replacingVideos(fallbackVideos),
                    generation: generation
                )
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
            try await finishInstalling(
                item,
                expiresAt: request.mediaExpiresAt,
                isProgressive: progressiveSource != nil,
                continuing: continuation,
                generation: generation
            )
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

    /// 准备 loopback 会话、安装 item 并等到就绪，返回就绪的 item。
    ///
    /// 每次 await 之后比对 generation，不一致时停掉迟到的会话并抛 `CancellationError`。失败时会话与
    /// item 仍挂在 engine 上，由调用方释放或交给 `discardFailedItem` 后重试。
    private func installReadyItem(
        _ preparation: BridgePreparation,
        generation: UUID
    ) async throws -> AVPlayerItem {
        let task = Task { [bridge] in
            try await preparation.prepare(using: bridge)
        }
        loadTask = task
        let prepared = try await task.value
        try Task.checkCancellation()
        guard loadGeneration == generation else {
            prepared.stop()
            throw CancellationError()
        }

        loadTask = nil
        preparedAsset = prepared
        let item = AVPlayerItem(url: prepared.url)
        item.variantPreferences = preparation.variantPreferences
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
        return item
    }

    /// 释放就绪前失败的 item 与它的 loopback 会话，保留 generation、intent 与时间线，供回退阶梯重建。
    ///
    /// 与 `releaseCurrentPlayback` 一样先移除 item 再停止会话。
    private func discardFailedItem() {
        readinessTask = nil
        player.replaceCurrentItem(with: nil)
        preparedAsset?.stop()
        preparedAsset = nil
    }

    private func cancelLoad(generation: UUID) {
        guard loadGeneration == generation else { return }
        resetToIdle()
    }

    /// 为当前 load intent 开播一次。
    ///
    /// 续播位置已由 playlist 的 `EXT-X-START` 在就绪前就位，这里不再 seek：按就绪位置报告续播
    /// 或从头开始。过期 intent／identity、已开播或已观察到用户操作（暂停、seek）时拒绝。
    public func beginPlayback(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async -> PlaybackStartOutcome {
        guard loadIntent == intent,
            timeline.currentSnapshot.identity == identity,
            !timeline.hasObservedPlaybackInteraction,
            timeline.currentSnapshot.state == .ready
                || timeline.currentSnapshot.state == .paused,
            player.currentItem != nil,
            let positionSeconds = Self.validSeconds(player.currentTime())
        else { return .rejected }
        // 不经 `play` 的过期检查：地址刚取得，这时已在余量内只可能是本机时钟偏快，重取也不会更新。
        timeline.play()
        guard positionSeconds > SeekPolicy.beginningThresholdSeconds else {
            activeResumeToken = nil
            return .startedAtBeginning
        }
        let token = PlaybackResumeToken()
        activeResumeToken = token
        return .resumed(positionSeconds: positionSeconds, token: token)
    }

    public func restartFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        resumeToken: PlaybackResumeToken
    ) async -> Bool {
        guard activeResumeToken == resumeToken else { return false }
        return await seekToBeginningAndPlay(identity: identity, intent: intent) { engine in
            engine.activeResumeToken == resumeToken
        }
    }

    public func replayFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async -> Bool {
        guard timeline.currentSnapshot.state == .ended else { return false }
        return await seekToBeginningAndPlay(identity: identity, intent: intent) { _ in true }
    }

    /// 断点浮层的「从头播放」与单集循环的重播共用：把仍是 `identity`、`intent` 的当前 item 定位到 0 秒并继续播放。
    ///
    /// 已有回到开头的动作在途、item 或意图已变时拒绝；seek 期间换 item、换意图、用户另有操作或 `stillValid` 不再成立
    /// 时落点作废、不播放。落到开头附近才算成功，时间线统一记为 0 秒；成功后作废断点 token，断点浮层随之收起。
    private func seekToBeginningAndPlay(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        stillValid: (AVPlayerEngine) -> Bool
    ) async -> Bool {
        guard restartOperation == nil,
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
        timeline.prepareRestartFromBeginning(operationID: operation)
        let interactionRevision = timeline.playbackInteractionRevision
        let didSeek = await seek(to: 0, tolerance: .zero)
        let settlement = settleSeek(
            operation,
            didSeek: didSeek,
            isOwned: restartOperation == operation,
            item: item,
            contextIsValid: stillValid(self)
                && loadGeneration == currentGeneration
                && loadIntent == intent
                && player.currentItem === item
                && timeline.currentSnapshot.identity == identity
                && timeline.playbackInteractionRevision == interactionRevision
        ) {
            // 只接受真正回到开头附近的落点，时间线统一记为 0 秒。
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

    /// 继续播放；地址将过期时改为停住并请求换源，换源后再播放。
    public func play() {
        guard player.currentItem != nil else { return }
        if deferToSourceRefresh(resumesPlayback: true, targetSeconds: nil) { return }
        timeline.play()
    }

    /// 暂停；等待换源或换源重建期间也记下“换源后不播放”。
    public func pause() {
        pendingSourceRefresh?.resumesPlayback = false
        sourceRefreshResumesPlayback = false
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

    /// 临时改变当前播放速率，但不覆盖用户选择的永久速率。
    public func beginMomentaryPlaybackRate(_ rate: Double) throws -> UUID? {
        try timeline.beginMomentaryRate(rate)
    }

    /// 结束仍匹配的临时速率会话；过期会话不会影响新的播放项目或用户改速。
    public func endMomentaryPlaybackRate(sessionID: UUID) {
        timeline.endMomentaryRate(sessionID: sessionID)
    }

    /// 幂等终止当前及在途播放，将唯一时间线恢复为 `.idle` 状态。
    public func stop() {
        resetToIdle()
    }

    /// 使当前 load 世代失效，并释放播放项目及其派生状态：在途加载／就绪任务、
    /// 字幕切换、seek、恢复与重新开始操作、地址有效期与待换源意图，以及 loopback 资源。
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
        sourceExpiry = .unchecked
        pendingSourceRefresh = nil
        sourceRefreshResumesPlayback = false
        mediaSelectionGroups = .none
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

    func finishSubtitleToggle(_ operationID: UUID) {
        guard subtitleToggleOperationID == operationID else { return }
        subtitleToggleOperationID = nil
    }

    private func invalidateSubtitleToggle(clearPreference: Bool) {
        subtitleToggleOperationID = nil
        if clearPreference {
            lastSubtitleSelection = nil
        }
    }

    private func handleCurrentItemFailure() {
        let snapshot = timeline.currentSnapshot
        guard let identity = snapshot.identity,
            let intent = loadIntent
        else { return }
        releaseCurrentPlayback()
        _ = enqueueSubtitleReset()
        failureEvents.yield(
            PlaybackFailureEvent(
                identity: identity,
                intent: intent,
                positionSeconds: snapshot.positionSeconds
            )
        )
    }

    @discardableResult
    private func enqueueSubtitleReset() -> Task<Void, Never>? {
        guard let identity = subtitleIdentity else {
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
