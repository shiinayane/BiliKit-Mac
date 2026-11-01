import BiliApplication
import BiliModels
import Observation

/// 播放页失败的来源：内容读取失败或播放准备失败；措辞与是否可重试见 VideoLoadFailurePresentation.swift。
public enum VideoLoadFailure: Sendable, Equatable {
    case content(ContentApplicationError)
    case playback
}

/// 当前视频意图的阶段；`loadingPage`／`failedPage` 保留已呈现的视频，只针对目标分 P。
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

/// 相关推荐按 BVID 标记的状态，呈现方只采用与当前视频一致的结果。
public enum RelatedVideoState: Sendable, Equatable {
    case idle
    case loading(bvid: String)
    case loaded(bvid: String, videos: [RelatedVideo])
    case empty(bvid: String)
    case failed(bvid: String, error: ContentApplicationError)
}

/// 合集里单个选集的分 P 读取状态，由 `CollectionEpisodePagesController` 按选集持有。
public enum CollectionEpisodePagesState: Sendable, Equatable {
    case idle
    case loading
    case loaded(bvid: String)
    case failed(ContentApplicationError)
}

/// 续播提示：开播位置与“从头播放”时用来确认仍是同一次续播的 token。
public struct PlaybackResumeNotice: Sendable, Equatable {
    public let positionSeconds: Double
    public let token: PlaybackResumeToken

    public init(positionSeconds: Double, token: PlaybackResumeToken) {
        self.positionSeconds = positionSeconds
        self.token = token
    }
}

/// 拥有单个视频准备意图，并把内容准备与播放器安装串成同一个可替换的 Task。
///
/// 新视频、重试或 reset 都使旧任务失效；旧任务即使忽略取消，也不能覆盖当前状态。
@MainActor
@Observable
public final class VideoViewModel: AccountRevalidationParticipant {
    public private(set) var state: VideoLoadState = .idle
    var failedPageCID: Int64? {
        guard case .failedPage(_, let targetPage, _) = state else { return nil }
        return targetPage.cid
    }
    public private(set) var relatedVideoState: RelatedVideoState = .idle
    public private(set) var uploaderProfileState: VideoUploaderProfileState =
        .loaded(UploaderProfile())
    /// 供播放主区与上下文 Sidebar 共享的最近有效详情。
    ///
    /// 新视频加载或失败期间保留旧值，使同一个播放 surface 不因短暂状态拆除；取得新
    /// context 后原子替换，最终 reset 或当前请求取消回到 idle 时清空。
    public private(set) var presentedContext: VideoContext?
    /// App 层只用这个稳定身份协调详情 surface 的滚动重置，不需要跨越 Feature 边界读取模型。
    public var presentedBVID: String? { presentedContext?.detail.bvid }
    /// 保留显示的旧详情此刻不可操作：换视频正在加载或失败（替换失败页盖在上面）。
    ///
    /// 播放页据此禁用主区，播放器的点赞、投币、收藏快捷键据此不响应，免得对已经不是用户想看的那个视频写入。
    public var blocksPresentedContext: Bool {
        switch state {
        case .loading, .failed, .failedPage:
            true
        case .idle, .loadingPage, .preparingPlayback, .ready:
            false
        }
    }
    /// 此刻可以操作的视频（播放器的点赞、投币、收藏快捷键与动作菜单作用于它）；旧详情不可操作时为 nil。
    public var operableBVID: String? {
        blocksPresentedContext ? nil : presentedBVID
    }
    /// App 层只用稳定的视频 subject 协调评论；分 P/CID 切换不重置同一视频评论。
    public var presentedVideoIdentity: (bvid: String, aid: Int64)? {
        guard let detail = presentedContext?.detail, let aid = detail.aid else {
            return nil
        }
        return (detail.bvid, aid)
    }
    /// 用户最新请求的媒体身份；在 playurl 或播放器准备失败时仍保留给 retry。
    public private(set) var requestedPlaybackIdentity: PlaybackItemIdentity?
    /// 最新选择意图的 BVID；与已成功安装的媒体身份分离。
    private(set) var requestedSelectionBVID: String?
    /// 显式用户 CID；未知 pages 时可以先存在，绝不据此伪造已呈现媒体。
    public private(set) var requestedPreferredCID: Int64?
    /// 外部链接给出的分 P 序号；详情到达前只用于重试，到达后换算为 `requestedPreferredCID`。
    private var requestedPreferredPageNumber: Int?
    /// 外部链接给出的起播秒数（`t=`）；开播前失败的重试沿用，开播成功后即用过、清除，之后的重试
    /// 不再跳回链接时间。
    private var requestedStartSeconds: Int?
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
    /// 只在当前 item 从续播位置就绪并开始播放后出现。
    public private(set) var resumeNotice: PlaybackResumeNotice?

    @ObservationIgnored private let useCase: VideoUseCase
    @ObservationIgnored private let playback: any PlaybackControlling
    @ObservationIgnored private let relatedVideoUseCase: RelatedVideoUseCase
    @ObservationIgnored private let uploaderProfileUseCase: UploaderProfileUseCase
    @ObservationIgnored private let loadTask = LatestTask()
    @ObservationIgnored private let relatedVideoTask = LatestTask()
    @ObservationIgnored private let uploaderProfileTask = LatestTask()
    /// 最近一次成功取得的名片；离开播放（reset）时清空。
    @ObservationIgnored private var lastUploaderProfile: (ownerID: Int64, profile: UploaderProfile)?
    @ObservationIgnored private var playbackFailureTask: Task<Void, Never>?
    @ObservationIgnored private var playbackAuthenticationTask: Task<Void, Never>?
    @ObservationIgnored private let resumeActionTask = LatestTask()
    @ObservationIgnored private var playbackIntent: PlaybackLoadIntent?
    @ObservationIgnored private let collectionEpisodes: CollectionEpisodePagesController

    public init(
        useCase: VideoUseCase,
        playback: any PlaybackControlling,
        relatedVideoUseCase: RelatedVideoUseCase,
        uploaderProfileUseCase: UploaderProfileUseCase,
        playbackAuthenticationInvalidations: AsyncStream<Void>
    ) {
        self.useCase = useCase
        self.playback = playback
        self.relatedVideoUseCase = relatedVideoUseCase
        self.uploaderProfileUseCase = uploaderProfileUseCase
        collectionEpisodes = CollectionEpisodePagesController(useCase: useCase)
        collectionEpisodes.onAuthenticationInvalid = { [weak self] in
            self?.recordAuthenticationInvalidationIfNeeded(.authenticationInvalid)
        }
        // 在 init 内同步订阅：失败事件不回放，订阅晚于首个 load 会漏掉它。
        let playbackFailures = playback.playbackFailureEvents()
        playbackFailureTask = Task { [weak self] in
            for await event in playbackFailures {
                guard !Task.isCancelled else { return }
                self?.handlePlaybackFailure(event)
            }
        }
        // 播放附带的账户读取（字幕目录）发现凭据失效：不影响播放，只请求窗口复核。
        playbackAuthenticationTask = Task { [weak self] in
            for await _ in playbackAuthenticationInvalidations {
                guard !Task.isCancelled else { return }
                self?.recordAuthenticationInvalidationIfNeeded(.authenticationInvalid)
            }
        }
    }

    deinit {
        playbackFailureTask?.cancel()
        playbackAuthenticationTask?.cancel()
    }

    /// 取代当前播放意图；已有非 idle 会话会先停止，避免两个 bridge/server 并存。
    public func loadVideo(
        _ bvid: String,
        preferredCID: Int64? = nil,
        preferredPageNumber: Int? = nil,
        startSeconds: Int? = nil
    ) {
        loadTask.cancel()
        collectionEpisodes.cancelRequests()
        cancelUploaderProfile()
        if state != .idle {
            playback.stop()
        }
        requestedPlaybackIdentity = nil
        presentedPlaybackIdentity = nil
        requestedSelectionBVID = bvid
        requestedPreferredCID = preferredCID
        requestedPreferredPageNumber = preferredPageNumber
        requestedStartSeconds = startSeconds
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
                preferredPageNumber: preferredPageNumber,
                startSeconds: startSeconds,
                isCurrent: isCurrent
            )
        }
    }

    /// Picker 或自动连播选择 episode 后解析其 pages；未知 pages 只在校验完成后提交跨 BVID 意图。
    ///
    /// `onFailed` 在这一集仍是当前选择、解析却失败时调用一次（自动连播据此说明下一集无法播放）；详情区不传，失败由
    /// 选集菜单里的重试呈现。
    public func selectCollectionEpisode(
        _ episode: VideoCollectionEpisode,
        onResolved: @escaping (String, Int64?) -> Void,
        onFailed: (() -> Void)? = nil
    ) {
        collectionEpisodes.select(episode, onResolved: onResolved, onFailed: onFailed)
    }

    public func retryCollectionEpisodePages(_ episode: VideoCollectionEpisode) {
        collectionEpisodes.retry(episode)
    }

    public func collectionEpisodePages(
        for identity: VideoCollectionEpisodeIdentity
    ) -> [VideoPage]? {
        collectionEpisodes.pages(for: identity)
    }

    /// 能否在播放器已经装好的分 P 里原地跳到某秒。
    ///
    /// `pageNumber` 为 nil 视为当前分 P，否则须与它相同；秒数按可跳转时长判断。还在加载、失败或没有
    /// 视频时为 false。
    func canSeekPresentedPage(number pageNumber: Int?, toSeconds seconds: Int) -> Bool {
        guard let context = presentedContext,
            presentedPlaybackIdentity?.cid == context.selectedPage.cid,
            pageNumber.map({ $0 == context.selectedPage.index }) ?? true
        else { return false }
        return context.acceptsSeek(toSeconds: seconds)
    }

    /// 当前视频里分 P 序号（从 1 开始）对应的 CID；没有当前视频或序号超出范围时为 nil。
    func presentedPageCID(forNumber number: Int) -> Int64? {
        presentedContext?.pages.first(where: { $0.index == number })?.cid
    }

    /// 在同一 BVID 的现有 pages 内替换 CID，不创建新的导航目的地或播放器 owner。
    ///
    /// `startSeconds` 来自外部链接（`t=`），从该处起播；应用内选分 P 不带它。同一分 P 正在加载时，
    /// 带起播秒数的请求取消在途加载并重开，不被去重吞掉。
    public func selectPage(cid: Int64, startSeconds: Int? = nil) {
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
        guard requestedPlaybackIdentity != targetIdentity || startSeconds != nil else { return }

        loadTask.cancel()
        playback.stop()
        clearResumeNotice()
        requestedPlaybackIdentity = targetIdentity
        requestedSelectionBVID = context.detail.bvid
        requestedPreferredCID = targetPage.cid
        requestedPreferredPageNumber = nil
        requestedStartSeconds = startSeconds
        presentedPlaybackIdentity = nil
        let intent = PlaybackLoadIntent()
        playbackIntent = intent
        state = .loadingPage(context: context, targetPage: targetPage)
        loadTask.replace { [weak self] isCurrent in
            await self?.performPageLoad(
                context: context,
                targetPage: targetPage,
                intent: intent,
                startSeconds: startSeconds,
                isCurrent: isCurrent
            )
        }
    }

    /// 重试当前失败意图；分 P 失败只重取目标 CID 的 playurl。
    public func retry() {
        switch state {
        case .failed(let bvid, _):
            loadVideo(
                bvid,
                preferredCID: requestedPreferredCID,
                preferredPageNumber: requestedPreferredPageNumber,
                startSeconds: requestedStartSeconds
            )
        case .failedPage(_, let targetPage, _):
            requestedPlaybackIdentity = nil
            selectPage(cid: targetPage.cid, startSeconds: requestedStartSeconds)
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
        cancelUploaderProfile()
        lastUploaderProfile = nil
        collectionEpisodes.clear()
        presentedContext = nil
        requestedPlaybackIdentity = nil
        presentedPlaybackIdentity = nil
        requestedSelectionBVID = nil
        requestedPreferredCID = nil
        requestedPreferredPageNumber = nil
        requestedStartSeconds = nil
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

    /// 当前 item 播完时按偏好处理（`PlaybackEndPolicy`），返回做了什么或要调用方接着做什么。
    ///
    /// 由 App 的播放结束观察者在时间线刚进入 `ended` 时调用一次。`snapshot` 必须属于此刻呈现、也是最新请求的那一项，
    /// 且页面已就绪；用户刚另选了分 P 或视频、旧 item 的结束才到时不动作。重播在这里执行，成功后断点浮层随之收起：它说的
    /// “上次看到”已经不是这一轮。下一项（`PlaybackNextItem`）只给出，不在这里跳转：跳转要经过 App 的导航。
    public func handlePlaybackEnded(
        _ snapshot: PlaybackTimelineSnapshot,
        behavior: PlaybackEndBehavior
    ) async -> PlaybackEndHandling {
        guard snapshot.state == .ended,
            isPresenting(snapshot),
            case .ready(let context) = state,
            let identity = presentedPlaybackIdentity,
            let intent = playbackIntent
        else { return .none }
        let next: PlaybackNextItem?
        switch PlaybackEndPolicy.action(behavior: behavior, accessNotice: context.accessNotice) {
        case .none:
            return .none
        case .replay:
            next = .replay
        case .next(let wraps):
            // 用户在选集菜单里另选的一集还在解析：那是用户的选择，连播不抢。
            if let selected = selectedCollectionEpisode,
                collectionEpisodePageStates[selected] == .loading
            {
                return .none
            }
            next = PlaybackNextItem.after(
                page: context.selectedPage,
                in: context,
                episode: currentCollectionEpisode(for: identity, in: context),
                wraps: wraps
            )
        }
        switch next {
        case nil:
            return .none
        case .replay:
            guard await playback.replayFromBeginning(identity: identity, intent: intent) else {
                return .replayFailed
            }
            if presentedPlaybackIdentity == identity {
                resumeNotice = nil
            }
            return .replayed
        case .page(let page):
            return .advance(.page(bvid: identity.bvid, page: page))
        case .episode(let episode):
            guard episode.isPlayableSelection else { return .nextUnavailable }
            return .advance(.episode(episode))
        }
    }

    /// `snapshot` 是否仍属于此刻呈现、也是最新请求的那一项（含同一次 load）。
    ///
    /// 播完的处理在动作前核对；连播的下一集解析完才跳转，跳转前也经它核对，期间用户换了分 P 或视频就作废。
    public func isPresenting(_ snapshot: PlaybackTimelineSnapshot) -> Bool {
        guard let identity = presentedPlaybackIdentity, let intent = playbackIntent else {
            return false
        }
        return snapshot.identity == identity
            && requestedPlaybackIdentity == identity
            && snapshot.loadIntent == intent
    }

    /// 正在播放的分 P 是合集里的哪一集；认不出时为 nil。
    ///
    /// 选集菜单的选择只在同一 BV 时才算数：另选的一集可能还在解析或已失败，不代表正在播放的这一集。同一 BV 的各集
    /// 各是一个分 P 时，按 CID 认出的那一集优先：在当前视频里换分 P 不更新选择，否则会一直按进入时的那一集算，
    /// 播完最后一个分 P 又跳回已经播过的分 P。
    private func currentCollectionEpisode(
        for identity: PlaybackItemIdentity,
        in context: VideoContext
    ) -> VideoCollectionEpisode? {
        guard let collection = context.detail.collection else { return nil }
        let episodes = collection.sections.flatMap(\.episodes)
        let byCID = episodes.filter { $0.bvid == identity.bvid && $0.defaultCID == identity.cid }
        if byCID.count == 1 { return byCID[0] }
        let explicit = selectedCollectionEpisode.flatMap { id in
            episodes.first(where: { $0.id == id && $0.bvid == identity.bvid })?.id
        }
        return PlaybackCollectionEpisodeResolver.resolve(
            episodes: episodes,
            explicitlySelectedID: explicit,
            bvid: identity.bvid,
            cid: identity.cid
        )
    }

    private func loadRelatedVideos(for bvid: String) {
        let relatedVideoUseCase = relatedVideoUseCase
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
            if case .failed(_, let error) = nextState {
                self.recordAuthenticationInvalidationIfNeeded(error)
            }
            self.relatedVideoState = nextState
        }
    }

    private func performLoad(
        bvid: String,
        preferredCID: Int64?,
        preferredPageNumber: Int?,
        startSeconds: Int?,
        isCurrent: LatestTask.IsCurrent
    ) async {
        do {
            let context = try await useCase.prepareVideo(
                bvid: bvid,
                preferredCID: preferredCID,
                preferredPageNumber: preferredPageNumber
            )
            try Task.checkCancellation()
            guard isCurrent() else { return }

            // 链接里的分 P 序号命中时与显式选择等价；没命中（超出范围）则按默认分 P，不算显式。
            let explicitCID =
                preferredCID
                ?? preferredPageNumber.flatMap { number in
                    context.selectedPage.index == number ? context.selectedPage.cid : nil
                }
            presentedContext = context
            collectionEpisodes.reconcile(
                with: context,
                preferredCID: explicitCID
            )
            loadUploaderProfile(for: context.detail.owner.id)
            let identity = PlaybackItemIdentity(
                bvid: context.detail.bvid,
                cid: context.selectedPage.cid
            )
            requestedPlaybackIdentity = identity
            requestedSelectionBVID = context.detail.bvid
            requestedPreferredCID = explicitCID
            requestedPreferredPageNumber = nil
            let intent = PlaybackLoadIntent()
            playbackIntent = intent
            state = .preparingPlayback(context)
            guard
                try await startPlayback(
                    context,
                    identity: identity,
                    intent: intent,
                    startSeconds: startSeconds,
                    isCurrent: isCurrent
                )
            else { return }
            presentedPlaybackIdentity = requestedPlaybackIdentity
            requestedStartSeconds = nil
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
        startSeconds: Int?,
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
                    startSeconds: startSeconds,
                    isCurrent: isCurrent
                )
            else { return }
            presentedPlaybackIdentity = identity
            requestedStartSeconds = nil
            state = .ready(replacement)
        } catch {
            guard isCurrent() else { return }
            handleLoadFailure(error) {
                .failedPage(context: context, targetPage: targetPage, failure: $0)
            }
        }
    }

    /// 安装并开播已准备好的 context；返回 false 表示意图已被取代，调用方不得再写状态。
    ///
    /// 链接给的起播秒数优先于续播位置；按 `VideoContext.linkStartPosition` 判断能否采用，采用时不显示
    /// 续播提示。
    private func startPlayback(
        _ context: VideoContext,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        startSeconds: Int?,
        isCurrent: LatestTask.IsCurrent
    ) async throws -> Bool {
        let linkStartSeconds = context.linkStartPosition(seconds: startSeconds)
        try await playback.load(
            context.playback,
            identity: identity,
            intent: intent,
            startPositionSeconds: linkStartSeconds ?? context.resumePositionSeconds
        )
        try Task.checkCancellation()
        guard isCurrent() else { return false }
        let startOutcome = await playback.beginPlayback(
            identity: identity,
            intent: intent
        )
        try Task.checkCancellation()
        guard isCurrent() else { return false }
        if linkStartSeconds == nil {
            applyResumeNotice(from: startOutcome)
        } else {
            resumeNotice = nil
        }
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
        guard error.requiresAccountRevalidation else { return }
        authenticationRevalidationGeneration &+= 1
    }

    private func applyResumeNotice(from outcome: PlaybackStartOutcome) {
        switch outcome {
        case .resumed(let positionSeconds, let token):
            resumeNotice = PlaybackResumeNotice(
                positionSeconds: positionSeconds,
                token: token
            )
        case .rejected, .startedAtBeginning:
            resumeNotice = nil
        }
    }

    private func clearResumeNotice() {
        resumeActionTask.cancel()
        resumeNotice = nil
    }

    private func loadUploaderProfile(for ownerID: Int64) {
        let uploaderProfileUseCase = uploaderProfileUseCase
        // 连续看同一 UP 主（合集、空间投稿）时沿用上一次名片，不再经过加载中，名字也不会重新变色。
        if let lastUploaderProfile, lastUploaderProfile.ownerID == ownerID {
            uploaderProfileTask.cancel()
            uploaderProfileState = .loaded(lastUploaderProfile.profile)
            return
        }
        uploaderProfileState = .loading
        uploaderProfileTask.replace { [weak self] isCurrent in
            // 名片只是增强：失败时不显示签名，名字按非大会员显示，也不留作下次沿用；凭据失效仍要复核。
            let profile: UploaderProfile?
            var failure: ContentApplicationError?
            do {
                let resolved = try await uploaderProfileUseCase.profile(for: ownerID)
                try Task.checkCancellation()
                profile = resolved
            } catch {
                profile = nil
                failure = error as? ContentApplicationError
            }
            guard let self, isCurrent() else { return }
            if let failure {
                self.recordAuthenticationInvalidationIfNeeded(failure)
            }
            if let profile {
                self.lastUploaderProfile = (ownerID, profile)
            }
            self.uploaderProfileState = .loaded(profile ?? UploaderProfile())
        }
    }

    private func cancelUploaderProfile() {
        uploaderProfileTask.cancel()
        uploaderProfileState = .loaded(UploaderProfile())
    }
}
