import BiliApplication
import BiliModels
import Observation

public enum VideoLoadFailure: Sendable, Equatable {
    case content(ContentApplicationError)
    case playback
}

public enum VideoLoadState: Sendable, Equatable {
    case idle
    case loading(bvid: String)
    case loadingPage(context: VideoContext, targetPage: VideoPage)
    case preparingPlayback(VideoContext)
    case ready(VideoContext)
    case failed(bvid: String, failure: VideoLoadFailure)
    case failedPage(
        context: VideoContext,
        targetPage: VideoPage,
        failure: VideoLoadFailure
    )
}

public enum RelatedVideoState: Sendable, Equatable {
    case idle
    case loading(bvid: String)
    case loaded(bvid: String, videos: [RelatedVideo])
    case empty(bvid: String)
    case failed(bvid: String, error: ContentApplicationError)
}

public enum CollectionEpisodePagesState: Sendable, Equatable {
    case idle
    case loading
    case loaded(bvid: String)
    case failed(ContentApplicationError)
}

public struct PlaybackResumeNotice: Sendable, Equatable {
    public let positionSeconds: Double
    public let token: PlaybackResumeToken

    public init(positionSeconds: Double, token: PlaybackResumeToken) {
        self.positionSeconds = positionSeconds
        self.token = token
    }
}

private struct PlaybackStartPreparationFailure: Error {}

@MainActor
@Observable
/// 拥有单个视频准备意图，并把内容准备与播放器安装串成同一个可替换的 Task。
///
/// 新视频、重试或 reset 都使旧任务失效；旧任务即使忽略取消，也不能覆盖当前状态。
public final class VideoViewModel {
    public private(set) var state: VideoLoadState = .idle
    public var failedPageCID: Int64? {
        guard case .failedPage(_, let targetPage, _) = state else { return nil }
        return targetPage.cid
    }
    public private(set) var relatedVideoState: RelatedVideoState = .idle
    public private(set) var uploaderSignatureState: VideoUploaderSignatureState =
        .loaded(nil)
    /// 供播放主区与上下文 Sidebar 共享的最近有效详情。
    ///
    /// 新视频加载或失败期间保留旧值，使同一个播放 surface 不因短暂状态拆除；取得新
    /// context 后原子替换，最终 reset 或当前请求取消回到 idle 时清空。
    public private(set) var presentedContext: VideoContext?
    /// App 层只用这个稳定身份协调详情 surface 的滚动重置，不需要跨越 Feature 边界读取模型。
    public var presentedBVID: String? { presentedContext?.detail.bvid }
    /// App 层只用稳定的视频 subject 协调评论；分 P/CID 切换不重置同一视频评论。
    public var presentedVideoIdentity: (bvid: String, aid: Int64)? {
        guard let detail = presentedContext?.detail, let aid = detail.aid else {
            return nil
        }
        return (detail.bvid, aid)
    }
    /// 用户最新请求的媒体身份；在 playurl 或播放器准备失败时仍保留给 retry。
    public private(set) var requestedPlaybackIdentity: PlaybackItemIdentity?
    /// App 层最新选择意图的 BVID；与已成功安装的媒体身份分离。
    public private(set) var requestedSelectionBVID: String?
    /// 显式用户 CID；未知 pages 时可以先存在，绝不据此伪造已呈现媒体。
    public private(set) var requestedPreferredCID: Int64?
    /// 已经由播放器成功安装的媒体身份；切换开始和失败后必须为 nil。
    public private(set) var presentedPlaybackIdentity: PlaybackItemIdentity?
    /// 仅在确认凭据失效时递增，由 App 层协调账户重校验；其他播放失败不能触发登出。
    public private(set) var authenticationRevalidationGeneration = 0
    /// Picker 当前请求的合集 episode；可能先于新视频 context 到达。
    public var selectedCollectionEpisode: VideoCollectionEpisodeIdentity? {
        collectionEpisodes.selectedEpisode
    }
    public var collectionEpisodePageStates:
        [VideoCollectionEpisodeIdentity: CollectionEpisodePagesState]
    {
        collectionEpisodes.pageStates
    }
    /// 只在当前 item 已完成首次定位并开始播放后出现。
    public private(set) var resumeNotice: PlaybackResumeNotice?

    @ObservationIgnored private let useCase: VideoUseCase
    @ObservationIgnored private let playback: any PlaybackControlling
    @ObservationIgnored private let relatedVideoUseCase: RelatedVideoUseCase?
    @ObservationIgnored private let uploaderSignatureUseCase: UploaderSignatureUseCase?
    @ObservationIgnored private let loadTask = LatestTask()
    @ObservationIgnored private let relatedVideoTask = LatestTask()
    @ObservationIgnored private let uploaderSignatureTask = LatestTask()
    @ObservationIgnored private var playbackFailureTask: Task<Void, Never>?
    @ObservationIgnored private let resumeActionTask = LatestTask()
    @ObservationIgnored private var playbackIntent: PlaybackLoadIntent?
    @ObservationIgnored private let collectionEpisodes: CollectionEpisodePagesController

    public init(
        useCase: VideoUseCase,
        playback: any PlaybackControlling,
        relatedVideoUseCase: RelatedVideoUseCase? = nil,
        uploaderSignatureUseCase: UploaderSignatureUseCase? = nil
    ) {
        self.useCase = useCase
        self.playback = playback
        self.relatedVideoUseCase = relatedVideoUseCase
        self.uploaderSignatureUseCase = uploaderSignatureUseCase
        collectionEpisodes = CollectionEpisodePagesController(useCase: useCase)
        collectionEpisodes.onAuthenticationInvalid = { [weak self] in
            self?.recordAuthenticationInvalidationIfNeeded(.authenticationInvalid)
        }
        playbackFailureTask = Task { [weak self, playback] in
            for await event in playback.playbackFailureEvents() {
                guard !Task.isCancelled else { return }
                self?.handlePlaybackFailure(event)
            }
        }
    }

    deinit {
        playbackFailureTask?.cancel()
    }

    /// 取代当前播放意图；已有非 idle 会话会先停止，避免两个 bridge/server 并存。
    public func loadVideo(_ bvid: String, preferredCID: Int64? = nil) {
        loadTask.cancel()
        collectionEpisodes.cancelRequests()
        cancelUploaderSignature()
        if state != .idle {
            playback.stop()
        }
        requestedPlaybackIdentity = nil
        presentedPlaybackIdentity = nil
        requestedSelectionBVID = bvid
        requestedPreferredCID = preferredCID
        if let preferredCID {
            requestedPlaybackIdentity = PlaybackItemIdentity(
                bvid: bvid,
                cid: preferredCID
            )
        }
        playbackIntent = nil
        clearResumeNotice()
        state = .loading(bvid: bvid)
        loadRelatedVideos(for: bvid)
        loadTask.replace { [weak self] isCurrent in
            await self?.performLoad(
                bvid: bvid,
                preferredCID: preferredCID,
                isCurrent: isCurrent
            )
        }
    }

    /// Picker 选择 episode 后解析其 pages；未知 pages 只在校验完成后提交跨 BVID 意图。
    public func selectCollectionEpisode(
        _ episode: VideoCollectionEpisode,
        onResolved: @escaping (String, Int64?) -> Void
    ) {
        collectionEpisodes.select(episode, onResolved: onResolved)
    }

    public func retryCollectionEpisodePages(_ episode: VideoCollectionEpisode) {
        collectionEpisodes.retry(episode)
    }

    public func collectionEpisodePages(
        for identity: VideoCollectionEpisodeIdentity
    ) -> [VideoPage]? {
        collectionEpisodes.pages(for: identity)
    }

    /// 在同一 BVID 的现有 pages 内替换 CID，不创建新的导航目的地或播放器 owner。
    public func selectPage(cid: Int64) {
        guard let context = presentedContext,
            let targetPage = context.pages.first(where: { $0.cid == cid })
        else { return }
        let targetIdentity = PlaybackItemIdentity(
            bvid: context.detail.bvid,
            cid: targetPage.cid
        )
        if case .ready = state,
            presentedPlaybackIdentity == targetIdentity
        {
            return
        }
        guard requestedPlaybackIdentity != targetIdentity else { return }

        loadTask.cancel()
        playback.stop()
        clearResumeNotice()
        requestedPlaybackIdentity = targetIdentity
        requestedSelectionBVID = context.detail.bvid
        requestedPreferredCID = targetPage.cid
        presentedPlaybackIdentity = nil
        let intent = PlaybackLoadIntent()
        playbackIntent = intent
        state = .loadingPage(context: context, targetPage: targetPage)
        loadTask.replace { [weak self] isCurrent in
            await self?.performPageLoad(
                context: context,
                targetPage: targetPage,
                intent: intent,
                isCurrent: isCurrent
            )
        }
    }

    /// 重试当前失败意图；分 P 失败只重取目标 CID 的 playurl。
    public func retry() {
        switch state {
        case .failed(let bvid, _):
            loadVideo(bvid, preferredCID: requestedPreferredCID)
        case .failedPage(_, let targetPage, _):
            requestedPlaybackIdentity = nil
            selectPage(cid: targetPage.cid)
        case .idle, .loading, .loadingPage, .preparingPlayback, .ready:
            break
        }
    }

    public func retryRelatedVideos() {
        guard case .failed(let bvid, _) = relatedVideoState else { return }
        loadRelatedVideos(for: bvid)
    }

    /// 取消内容准备并停止播放 adapter，作为离开播放目的地的最终清理边界。
    public func reset() {
        loadTask.cancel()
        relatedVideoTask.cancel()
        relatedVideoState = .idle
        cancelUploaderSignature()
        collectionEpisodes.clear()
        presentedContext = nil
        requestedPlaybackIdentity = nil
        presentedPlaybackIdentity = nil
        requestedSelectionBVID = nil
        requestedPreferredCID = nil
        playbackIntent = nil
        clearResumeNotice()
        state = .idle
        playback.stop()
    }

    /// 当前浮层的 token、identity 与 load intent 都匹配时才允许回到 0 秒。
    ///
    /// 新的重播、切换或 reset 都会取消旧动作；旧动作即使稍后返回，也不能清掉浮层或新动作。
    public func restartFromBeginning() {
        guard let resumeNotice,
            let identity = presentedPlaybackIdentity,
            let intent = playbackIntent
        else { return }
        resumeActionTask.replace { [weak self, playback] isCurrent in
            let restarted = await playback.restartFromBeginning(
                identity: identity,
                intent: intent,
                resumeToken: resumeNotice.token
            )
            guard let self, isCurrent(), restarted,
                self.resumeNotice?.token == resumeNotice.token
            else { return }
            self.resumeNotice = nil
        }
    }

    private func loadRelatedVideos(for bvid: String) {
        guard let relatedVideoUseCase else {
            relatedVideoTask.cancel()
            relatedVideoState = .empty(bvid: bvid)
            return
        }
        relatedVideoState = .loading(bvid: bvid)
        relatedVideoTask.replace { [weak self] isCurrent in
            let nextState: RelatedVideoState
            do {
                let videos = try await relatedVideoUseCase.relatedVideos(to: bvid)
                try Task.checkCancellation()
                nextState =
                    videos.isEmpty
                    ? .empty(bvid: bvid)
                    : .loaded(bvid: bvid, videos: videos)
            } catch is CancellationError {
                nextState = .idle
            } catch let error as ContentApplicationError {
                nextState = .failed(bvid: bvid, error: error)
            } catch {
                nextState = .failed(bvid: bvid, error: .unavailable)
            }
            guard let self, isCurrent() else { return }
            self.relatedVideoState = nextState
        }
    }

    private func performLoad(
        bvid: String,
        preferredCID: Int64?,
        isCurrent: LatestTask.IsCurrent
    ) async {
        do {
            let context = try await useCase.prepareVideo(
                bvid: bvid,
                preferredCID: preferredCID
            )
            try Task.checkCancellation()
            guard isCurrent() else { return }

            presentedContext = context
            collectionEpisodes.reconcile(
                with: context,
                preferredCID: requestedPreferredCID
            )
            loadUploaderSignature(for: context.detail.owner.id)
            let identity = PlaybackItemIdentity(
                bvid: context.detail.bvid,
                cid: context.selectedPage.cid
            )
            requestedPlaybackIdentity = identity
            requestedSelectionBVID = context.detail.bvid
            requestedPreferredCID = preferredCID
            let intent = PlaybackLoadIntent()
            playbackIntent = intent
            state = .preparingPlayback(context)
            guard
                try await startPlayback(
                    context,
                    identity: identity,
                    intent: intent,
                    isCurrent: isCurrent
                )
            else { return }
            presentedPlaybackIdentity = requestedPlaybackIdentity
            state = .ready(context)
        } catch {
            guard isCurrent() else { return }
            handleLoadFailure(error) { .failed(bvid: bvid, failure: $0) }
        }
    }

    private func performPageLoad(
        context: VideoContext,
        targetPage: VideoPage,
        intent: PlaybackLoadIntent,
        isCurrent: LatestTask.IsCurrent
    ) async {
        do {
            let replacement = try await useCase.preparePage(
                in: context,
                cid: targetPage.cid
            )
            try Task.checkCancellation()
            guard isCurrent() else { return }

            presentedContext = replacement
            state = .preparingPlayback(replacement)
            let identity = PlaybackItemIdentity(
                bvid: replacement.detail.bvid,
                cid: replacement.selectedPage.cid
            )
            guard
                try await startPlayback(
                    replacement,
                    identity: identity,
                    intent: intent,
                    isCurrent: isCurrent
                )
            else { return }
            presentedPlaybackIdentity = identity
            state = .ready(replacement)
        } catch {
            guard isCurrent() else { return }
            handleLoadFailure(error) {
                .failedPage(context: context, targetPage: targetPage, failure: $0)
            }
        }
    }

    /// 安装并开播已准备好的 context；返回 false 表示意图已被取代，调用方不得再写状态。
    private func startPlayback(
        _ context: VideoContext,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        isCurrent: LatestTask.IsCurrent
    ) async throws -> Bool {
        try await playback.load(
            context.playback,
            identity: identity,
            intent: intent
        )
        try Task.checkCancellation()
        guard isCurrent() else { return false }
        let startOutcome = await playback.beginPlayback(
            identity: identity,
            intent: intent,
            initialPositionSeconds: context.resumePositionSeconds
        )
        try Task.checkCancellation()
        guard isCurrent() else { return false }
        if startOutcome == .preparationFailed {
            throw PlaybackStartPreparationFailure()
        }
        applyResumeNotice(from: startOutcome)
        return true
    }

    /// 当前意图的准备失败：取消回到 idle，其余错误按调用方给出的失败形态呈现。
    private func handleLoadFailure(
        _ error: any Error,
        failedState: (VideoLoadFailure) -> VideoLoadState
    ) {
        clearResumeNotice()
        switch error {
        case is CancellationError:
            collectionEpisodes.clear()
            presentedContext = nil
            requestedPlaybackIdentity = nil
            presentedPlaybackIdentity = nil
            playbackIntent = nil
            state = .idle
        case let error as ContentApplicationError:
            recordAuthenticationInvalidationIfNeeded(error)
            state = failedState(.content(error))
        default:
            state = failedState(.playback)
        }
    }

    /// adapter 已拒绝旧 item token；Feature 再以当前请求 identity 与状态拒绝跨意图失败。
    private func handlePlaybackFailure(_ event: PlaybackFailureEvent) {
        guard requestedPlaybackIdentity == event.identity,
            playbackIntent == event.intent
        else { return }
        switch state {
        case .preparingPlayback, .ready:
            break
        case .idle, .loading, .loadingPage, .failed, .failedPage:
            return
        }
        guard
            let context = presentedContext,
            let targetPage = context.pages.first(where: {
                $0.cid == event.identity.cid
            })
        else { return }

        loadTask.cancel()
        playback.stop()
        clearResumeNotice()
        requestedPlaybackIdentity = event.identity
        presentedPlaybackIdentity = nil
        state = .failedPage(
            context: context,
            targetPage: targetPage,
            failure: .playback
        )
    }

    private func recordAuthenticationInvalidationIfNeeded(
        _ error: ContentApplicationError
    ) {
        guard error == .authenticationInvalid else { return }
        authenticationRevalidationGeneration += 1
    }

    private func applyResumeNotice(from outcome: PlaybackStartOutcome) {
        switch outcome {
        case .resumed(let positionSeconds, let token, _):
            resumeNotice = PlaybackResumeNotice(
                positionSeconds: positionSeconds,
                token: token
            )
        case .rejected, .preparationFailed, .startedAtBeginning:
            resumeNotice = nil
        }
    }

    private func clearResumeNotice() {
        resumeActionTask.cancel()
        resumeNotice = nil
    }

    private func loadUploaderSignature(for ownerID: Int64) {
        guard let uploaderSignatureUseCase else {
            cancelUploaderSignature()
            return
        }
        uploaderSignatureState = .loading
        uploaderSignatureTask.replace { [weak self] isCurrent in
            let signature: String?
            do {
                let resolved = try await uploaderSignatureUseCase.signature(
                    for: ownerID
                )
                try Task.checkCancellation()
                signature = resolved
            } catch {
                signature = nil
            }
            guard let self, isCurrent() else { return }
            self.uploaderSignatureState = .loaded(signature)
        }
    }

    private func cancelUploaderSignature() {
        uploaderSignatureTask.cancel()
        uploaderSignatureState = .loaded(nil)
    }
}
