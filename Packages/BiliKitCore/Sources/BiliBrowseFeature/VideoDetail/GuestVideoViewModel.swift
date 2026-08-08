import BiliApplication
import BiliModels
import Observation

public enum GuestVideoFailure: Sendable, Equatable {
    case content(GuestApplicationError)
    case playback
}

public enum GuestVideoState: Sendable, Equatable {
    case idle
    case loading(bvid: String)
    case loadingPage(context: GuestVideoContext, targetPage: VideoPage)
    case preparingPlayback(GuestVideoContext)
    case ready(GuestVideoContext)
    case failed(bvid: String, failure: GuestVideoFailure)
    case failedPage(
        context: GuestVideoContext,
        targetPage: VideoPage,
        failure: GuestVideoFailure
    )
}

public enum RelatedVideoState: Sendable, Equatable {
    case idle
    case loading(bvid: String)
    case loaded(bvid: String, videos: [RelatedVideo])
    case empty(bvid: String)
    case failed(bvid: String, error: GuestApplicationError)
}

@MainActor
@Observable
/// 拥有单个视频准备意图，并把内容准备与播放器安装串成同一 generation。
///
/// 新视频、重试或 reset 都使旧任务失效；旧任务即使忽略取消，也不能覆盖当前状态。
public final class GuestVideoViewModel {
    public private(set) var state: GuestVideoState = .idle
    public private(set) var relatedVideoState: RelatedVideoState = .idle
    public private(set) var uploaderSignatureState: VideoUploaderSignatureState =
        .loaded(nil)
    /// 供播放主区与上下文 Sidebar 共享的最近有效详情。
    ///
    /// 新视频加载或失败期间保留旧值，使同一个播放 surface 不因短暂状态拆除；取得新
    /// context 后原子替换，最终 reset 或当前请求取消回到 idle 时清空。
    public private(set) var presentedContext: GuestVideoContext?
    /// 用户最新请求的媒体身份；在 playurl 或播放器准备失败时仍保留给 retry。
    public private(set) var requestedPlaybackIdentity: PlaybackItemIdentity?
    /// 已经由播放器成功安装的媒体身份；切换开始和失败后必须为 nil。
    public private(set) var presentedPlaybackIdentity: PlaybackItemIdentity?
    /// 仅在确认凭据失效时递增，由 App 层协调账户重校验；其他播放失败不能触发登出。
    public private(set) var authenticationRevalidationGeneration = 0

    @ObservationIgnored private let useCase: GuestVideoUseCase
    @ObservationIgnored private let playback: any PlaybackControlling
    @ObservationIgnored private let relatedVideoUseCase: RelatedVideoUseCase?
    @ObservationIgnored private let uploaderSignatureUseCase: UploaderSignatureUseCase?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var relatedVideoTask: Task<Void, Never>?
    @ObservationIgnored private var uploaderSignatureTask: Task<Void, Never>?
    @ObservationIgnored private var playbackFailureTask: Task<Void, Never>?
    @ObservationIgnored private var playbackIntent: PlaybackLoadIntent?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var relatedVideoGeneration = 0
    @ObservationIgnored private var uploaderSignatureGeneration = 0

    public init(
        useCase: GuestVideoUseCase,
        playback: any PlaybackControlling,
        relatedVideoUseCase: RelatedVideoUseCase? = nil,
        uploaderSignatureUseCase: UploaderSignatureUseCase? = nil
    ) {
        self.useCase = useCase
        self.playback = playback
        self.relatedVideoUseCase = relatedVideoUseCase
        self.uploaderSignatureUseCase = uploaderSignatureUseCase
        playbackFailureTask = Task { [weak self, playback] in
            for await event in playback.playbackFailureEvents() {
                guard !Task.isCancelled else { return }
                self?.handlePlaybackFailure(event)
            }
        }
    }

    deinit {
        loadTask?.cancel()
        relatedVideoTask?.cancel()
        uploaderSignatureTask?.cancel()
        playbackFailureTask?.cancel()
    }

    /// 取代当前播放意图；已有非 idle 会话会先停止，避免两个 bridge/server 并存。
    public func loadVideo(_ bvid: String) {
        generation += 1
        let currentGeneration = generation
        loadTask?.cancel()
        cancelUploaderSignature()
        if state != .idle {
            playback.stop()
        }
        requestedPlaybackIdentity = nil
        presentedPlaybackIdentity = nil
        playbackIntent = nil
        state = .loading(bvid: bvid)
        loadRelatedVideos(for: bvid)
        loadTask = Task { [weak self] in
            await self?.performLoad(
                bvid: bvid,
                generation: currentGeneration
            )
        }
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

        generation += 1
        let currentGeneration = generation
        loadTask?.cancel()
        playback.stop()
        requestedPlaybackIdentity = targetIdentity
        presentedPlaybackIdentity = nil
        let intent = PlaybackLoadIntent()
        playbackIntent = intent
        state = .loadingPage(context: context, targetPage: targetPage)
        loadTask = Task { [weak self] in
            await self?.performPageLoad(
                context: context,
                targetPage: targetPage,
                intent: intent,
                generation: currentGeneration
            )
        }
    }

    /// 重试当前失败意图；分 P 失败只重取目标 CID 的 playurl。
    public func retry() {
        switch state {
        case .failed(let bvid, _):
            loadVideo(bvid)
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
        generation += 1
        relatedVideoGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        relatedVideoTask?.cancel()
        relatedVideoTask = nil
        relatedVideoState = .idle
        cancelUploaderSignature()
        presentedContext = nil
        requestedPlaybackIdentity = nil
        presentedPlaybackIdentity = nil
        playbackIntent = nil
        state = .idle
        playback.stop()
    }

    public func waitForCurrentTask() async {
        await loadTask?.value
    }

    func taskSnapshotForTesting() -> Task<Void, Never>? {
        loadTask
    }

    public func waitForCurrentRelatedVideoTask() async {
        await relatedVideoTask?.value
    }

    func relatedVideoTaskSnapshotForTesting() -> Task<Void, Never>? {
        relatedVideoTask
    }

    public func waitForCurrentUploaderSignatureTask() async {
        await uploaderSignatureTask?.value
    }

    func uploaderSignatureTaskSnapshotForTesting() -> Task<Void, Never>? {
        uploaderSignatureTask
    }

    private func loadRelatedVideos(for bvid: String) {
        relatedVideoGeneration += 1
        let currentGeneration = relatedVideoGeneration
        relatedVideoTask?.cancel()
        guard let relatedVideoUseCase else {
            relatedVideoState = .empty(bvid: bvid)
            relatedVideoTask = nil
            return
        }
        relatedVideoState = .loading(bvid: bvid)
        relatedVideoTask = Task { [weak self] in
            do {
                let videos = try await relatedVideoUseCase.relatedVideos(
                    to: bvid
                )
                try Task.checkCancellation()
                guard let self,
                    self.relatedVideoGeneration == currentGeneration
                else { return }
                self.relatedVideoState =
                    videos.isEmpty
                    ? .empty(bvid: bvid)
                    : .loaded(bvid: bvid, videos: videos)
                self.relatedVideoTask = nil
            } catch is CancellationError {
                guard let self,
                    self.relatedVideoGeneration == currentGeneration
                else { return }
                self.relatedVideoState = .idle
                self.relatedVideoTask = nil
            } catch let error as GuestApplicationError {
                guard let self,
                    self.relatedVideoGeneration == currentGeneration
                else { return }
                self.relatedVideoState = .failed(bvid: bvid, error: error)
                self.relatedVideoTask = nil
            } catch {
                guard let self,
                    self.relatedVideoGeneration == currentGeneration
                else { return }
                self.relatedVideoState = .failed(
                    bvid: bvid,
                    error: .unavailable
                )
                self.relatedVideoTask = nil
            }
        }
    }

    private func performLoad(
        bvid: String,
        generation currentGeneration: Int
    ) async {
        do {
            let context = try await useCase.prepareVideo(bvid: bvid)
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }

            presentedContext = context
            loadUploaderSignature(for: context.detail.owner.id)
            let identity = PlaybackItemIdentity(
                bvid: context.detail.bvid,
                cid: context.selectedPage.cid
            )
            requestedPlaybackIdentity = identity
            let intent = PlaybackLoadIntent()
            playbackIntent = intent
            state = .preparingPlayback(context)
            try await playback.load(
                context.playback,
                identity: identity,
                intent: intent
            )
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            presentedPlaybackIdentity = requestedPlaybackIdentity
            state = .ready(context)
        } catch is CancellationError {
            guard generation == currentGeneration else { return }
            presentedContext = nil
            requestedPlaybackIdentity = nil
            presentedPlaybackIdentity = nil
            playbackIntent = nil
            state = .idle
        } catch let error as GuestApplicationError {
            guard generation == currentGeneration else { return }
            recordAuthenticationInvalidationIfNeeded(error)
            state = .failed(bvid: bvid, failure: .content(error))
        } catch {
            guard generation == currentGeneration else { return }
            state = .failed(bvid: bvid, failure: .playback)
        }

        if generation == currentGeneration {
            loadTask = nil
        }
    }

    private func performPageLoad(
        context: GuestVideoContext,
        targetPage: VideoPage,
        intent: PlaybackLoadIntent,
        generation currentGeneration: Int
    ) async {
        do {
            let replacement = try await useCase.preparePage(
                in: context,
                cid: targetPage.cid
            )
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }

            presentedContext = replacement
            state = .preparingPlayback(replacement)
            let identity = PlaybackItemIdentity(
                bvid: replacement.detail.bvid,
                cid: replacement.selectedPage.cid
            )
            try await playback.load(
                replacement.playback,
                identity: identity,
                intent: intent
            )
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            presentedPlaybackIdentity = identity
            state = .ready(replacement)
        } catch is CancellationError {
            guard generation == currentGeneration else { return }
            requestedPlaybackIdentity = nil
            presentedPlaybackIdentity = nil
            playbackIntent = nil
            state = .idle
            presentedContext = nil
        } catch let error as GuestApplicationError {
            guard generation == currentGeneration else { return }
            recordAuthenticationInvalidationIfNeeded(error)
            state = .failedPage(
                context: context,
                targetPage: targetPage,
                failure: .content(error)
            )
        } catch {
            guard generation == currentGeneration else { return }
            state = .failedPage(
                context: context,
                targetPage: targetPage,
                failure: .playback
            )
        }

        if generation == currentGeneration {
            loadTask = nil
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

        generation += 1
        loadTask?.cancel()
        loadTask = nil
        playback.stop()
        requestedPlaybackIdentity = event.identity
        presentedPlaybackIdentity = nil
        state = .failedPage(
            context: context,
            targetPage: targetPage,
            failure: .playback
        )
    }

    private func recordAuthenticationInvalidationIfNeeded(
        _ error: GuestApplicationError
    ) {
        guard error == .authenticationInvalid else { return }
        authenticationRevalidationGeneration += 1
    }

    private func loadUploaderSignature(for ownerID: Int64) {
        uploaderSignatureGeneration += 1
        let currentGeneration = uploaderSignatureGeneration
        uploaderSignatureTask?.cancel()
        guard let uploaderSignatureUseCase else {
            uploaderSignatureState = .loaded(nil)
            uploaderSignatureTask = nil
            return
        }
        uploaderSignatureState = .loading
        uploaderSignatureTask = Task { [weak self] in
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
            guard let self,
                self.uploaderSignatureGeneration == currentGeneration,
                !Task.isCancelled
            else { return }
            self.uploaderSignatureState = .loaded(signature)
            self.uploaderSignatureTask = nil
        }
    }

    private func cancelUploaderSignature() {
        uploaderSignatureGeneration += 1
        uploaderSignatureTask?.cancel()
        uploaderSignatureTask = nil
        uploaderSignatureState = .loaded(nil)
    }
}
