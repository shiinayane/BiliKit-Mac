import BiliApplication
import BiliModels
import Observation

/// 播放页失败的来源：内容读取失败或播放准备失败；措辞与是否可重试见 VideoLoadFailurePresentation.swift。
public enum VideoLoadFailure: Sendable, Equatable {
    case content(ContentApplicationError)
    case playback
}

/// 当前视频意图的阶段；`loadingPage`／`failedPage` 保留已呈现的视频，只针对目标分 P。
///
/// `preparingPlayback` 是页面已能呈现、播放器还没开播：详情已到而播放清单还在取，或播放器正在安装 item；
/// `ready` 才带播放清单（`PlayableVideo`）。
public enum VideoLoadState: Sendable, Equatable {
    case idle
    case loading(bvid: String)
    case loadingPage(context: VideoContext, targetPage: VideoPage)
    case preparingPlayback(VideoContext)
    case ready(PlayableVideo)
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
    /// 新视频加载或失败期间保留旧值，使同一个播放 surface 不因短暂状态拆除；新视频的分 P 一确定就原子替换
    /// （分 P 已定时在详情到达时，不等播放清单），最终 reset 或当前请求取消回到 idle 时清空。
    public private(set) var presentedContext: VideoContext?
    /// 已开播的那一项（`ready`）；充电提示、可跳转时长与时间戳上限只按它判断，其余阶段为 nil。
    public var playableVideo: PlayableVideo? {
        guard case .ready(let playable) = state else { return nil }
        return playable
    }
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
    /// 重试的起播秒数。
    ///
    /// 外部链接给出的 `t=`，开播前失败的重试沿用；开播成功后即用过、清除。开播后的失败（含换源失败）改记为
    /// 失败时的播放位置，重试从那里继续而不是从头开始。
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

    @ObservationIgnored let useCase: VideoUseCase
    @ObservationIgnored let playback: any PlaybackControlling
    @ObservationIgnored private let relatedVideoUseCase: RelatedVideoUseCase
    @ObservationIgnored private let uploaderProfileUseCase: UploaderProfileUseCase
    /// 内容准备、开播与换源共用的唯一 Task；新视频、换分 P、重试与 reset 都取代它。
    @ObservationIgnored let loadTask = LatestTask()
    @ObservationIgnored private let relatedVideoTask = LatestTask()
    @ObservationIgnored private let uploaderProfileTask = LatestTask()
    /// 最近一次成功取得的名片；离开播放（reset）时清空。
    @ObservationIgnored private var lastUploaderProfile: (ownerID: Int64, profile: UploaderProfile)?
    @ObservationIgnored private var playbackFailureTask: Task<Void, Never>?
    @ObservationIgnored private var playbackSourceExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var playbackAuthenticationTask: Task<Void, Never>?
    @ObservationIgnored private let resumeActionTask = LatestTask()
    @ObservationIgnored private(set) var playbackIntent: PlaybackLoadIntent?
    /// 正在换源的 load intent。
    ///
    /// 换源开始时记下，结束（成功或失败）时清除；同一 intent 的重复换源事件据此忽略。换源被新的视频、分 P 或
    /// reset 取代时不必清除，它们都会换掉 `playbackIntent`。
    @ObservationIgnored var sourceRefreshIntent: PlaybackLoadIntent?
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
        // 在 init 内同步订阅：失败与换源事件都不回放，订阅晚于首个 load 会漏掉它们。
        let playbackFailures = playback.playbackFailureEvents()
        playbackFailureTask = Task { [weak self] in
            for await event in playbackFailures {
                guard !Task.isCancelled else { return }
                self?.handlePlaybackFailure(event)
            }
        }
        let sourceExpiries = playback.playbackSourceExpiryEvents()
        playbackSourceExpiryTask = Task { [weak self] in
            for await event in sourceExpiries {
                guard !Task.isCancelled else { return }
                self?.handlePlaybackSourceExpiry(event)
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
        playbackSourceExpiryTask?.cancel()
        playbackAuthenticationTask?.cancel()
    }

    /// 取代当前播放意图；已有非 idle 会话会先停止，避免两个 bridge/server 并存。
    ///
    /// `firstPageCIDHint` 是来源列表给的第一个分 P 的 CID，只在没有指定分 P 时用来与详情并行预取播放清单。
    public func loadVideo(
        _ bvid: String,
        preferredCID: Int64? = nil,
        preferredPageNumber: Int? = nil,
        startSeconds: Int? = nil,
        firstPageCIDHint: Int64? = nil
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
                // 指定了分 P 时第一个要请求的不是第一个分 P，预取用不上。
                firstPageCIDHint: preferredCID == nil && preferredPageNumber == nil
                    ? firstPageCIDHint : nil,
                isCurrent: isCurrent
            )
        }
    }

    /// Picker 或自动连播选择 episode 后解析其 pages；未知 pages 只在校验完成后提交跨 BVID 意图。
    ///
    /// `onFailed` 在这一集仍是当前选择、解析却失败时调用一次（自动连播据此说明下一集无法播放）；侧栏不传，失败由
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
        guard let playable = playableVideo,
            presentedPlaybackIdentity?.cid == playable.context.selectedPage.cid,
            pageNumber.map({ $0 == playable.context.selectedPage.index }) ?? true
        else { return false }
        return playable.acceptsSeek(toSeconds: seconds)
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
            case .ready(let playable) = state,
            let identity = presentedPlaybackIdentity,
            let intent = playbackIntent
        else { return .none }
        let context = playable.context
        let next: PlaybackNextItem?
        switch PlaybackEndPolicy.action(behavior: behavior, accessNotice: playable.accessNotice) {
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
        firstPageCIDHint: Int64?,
        isCurrent: LatestTask.IsCurrent
    ) async {
        // 与详情并行预取播放清单；取代、离开或失败退出时随本任务取消。CID 与详情核对不一致时结果不用。
        let useCase = useCase
        async let prefetched = useCase.prefetchPlayback(bvid: bvid, cid: firstPageCIDHint)
        do {
            let preparation = try await useCase.prepareDetail(
                bvid: bvid,
                preferredCID: preferredCID,
                preferredPageNumber: preferredPageNumber
            )
            try Task.checkCancellation()
            guard isCurrent() else { return }
            // 分 P 已定时详情一到就呈现页面，页面与评论不等 playurl 往返；播放器在播放清单到达前保持准备中。
            if let context = preparation.context {
                present(
                    context,
                    explicitCID: Self.explicitCID(preferredCID, preferredPageNumber, in: context)
                )
            }

            let usesPrefetch = firstPageCIDHint == preparation.firstPlaybackCID
            let playable = try await useCase.preparePlayback(
                for: preparation,
                prefetched: usesPrefetch ? await prefetched : nil
            )
            try Task.checkCancellation()
            guard isCurrent() else { return }
            let explicitCID = Self.explicitCID(
                preferredCID,
                preferredPageNumber,
                in: playable.context
            )
            // 分 P 要按续播记录选定时，页面到这里才呈现。
            if preparation.selectedPage == nil {
                present(playable.context, explicitCID: explicitCID)
            }
            // 取得播放清单后才把链接的分 P 序号换算成显式 CID：在此之前失败时，重试仍按序号打开、照常续播。
            requestedPreferredCID = explicitCID
            requestedPreferredPageNumber = nil
            let identity = PlaybackItemIdentity(
                bvid: playable.context.detail.bvid,
                cid: playable.context.selectedPage.cid
            )
            let intent = PlaybackLoadIntent()
            playbackIntent = intent
            guard
                try await startPlayback(
                    playable,
                    identity: identity,
                    intent: intent,
                    startSeconds: startSeconds,
                    isCurrent: isCurrent
                )
            else { return }
            presentedPlaybackIdentity = requestedPlaybackIdentity
            requestedStartSeconds = nil
            state = .ready(playable)
        } catch {
            guard isCurrent() else { return }
            handleLoadFailure(error) { .failed(bvid: bvid, failure: $0) }
        }
    }

    /// 呈现新视频的页面：替换详情、对齐合集选择、取 UP 主名片，记下这次请求的分 P，进入准备开播。
    private func present(_ context: VideoContext, explicitCID: Int64?) {
        presentedContext = context
        collectionEpisodes.reconcile(with: context, preferredCID: explicitCID)
        loadUploaderProfile(for: context.detail.owner.id)
        requestedPlaybackIdentity = PlaybackItemIdentity(
            bvid: context.detail.bvid,
            cid: context.selectedPage.cid
        )
        requestedSelectionBVID = context.detail.bvid
        state = .preparingPlayback(context)
    }

    /// 链接里的分 P 序号命中时与显式选择等价；没命中（超出范围）则按默认分 P，不算显式。
    private static func explicitCID(
        _ preferredCID: Int64?,
        _ preferredPageNumber: Int?,
        in context: VideoContext
    ) -> Int64? {
        preferredCID
            ?? preferredPageNumber.flatMap { number in
                context.selectedPage.index == number ? context.selectedPage.cid : nil
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

            presentedContext = replacement.context
            state = .preparingPlayback(replacement.context)
            let identity = PlaybackItemIdentity(
                bvid: replacement.context.detail.bvid,
                cid: replacement.context.selectedPage.cid
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

    /// 安装并开播已取得播放清单的一项；返回 false 表示意图已被取代，调用方不得再写状态。
    ///
    /// 链接给的起播秒数优先于续播位置；按 `PlayableVideo.linkStartPosition` 判断能否采用，采用时不显示
    /// 续播提示。
    private func startPlayback(
        _ playable: PlayableVideo,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        startSeconds: Int?,
        isCurrent: LatestTask.IsCurrent
    ) async throws -> Bool {
        let linkStartSeconds = playable.linkStartPosition(seconds: startSeconds)
        try await playback.load(
            playable.playback,
            identity: identity,
            intent: intent,
            startPositionSeconds: linkStartSeconds ?? playable.resumePositionSeconds
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
    ///
    /// 开播前（`.preparingPlayback`）的失败沿用链接的起播秒数重试；开播后的失败从失败位置重试。
    func handlePlaybackFailure(_ event: PlaybackFailureEvent) {
        guard requestedPlaybackIdentity == event.identity,
            playbackIntent == event.intent
        else { return }
        let retryPositionSeconds: Double?
        switch state {
        case .preparingPlayback:
            retryPositionSeconds = nil
        case .ready:
            retryPositionSeconds = event.positionSeconds
        case .idle, .loading, .loadingPage, .failed, .failedPage:
            return
        }
        presentPlaybackFailure(
            of: event.identity,
            failure: .playback,
            retryPositionSeconds: retryPositionSeconds
        )
    }

    /// 停下播放器，把 `identity` 所在分 P 呈现为失败，保留已呈现的视频。
    ///
    /// `retryPositionSeconds` 非 nil 时重试从那里继续。播放中失败与换源失败共用。
    func presentPlaybackFailure(
        of identity: PlaybackItemIdentity,
        failure: VideoLoadFailure,
        retryPositionSeconds: Double?
    ) {
        guard
            let context = presentedContext,
            let targetPage = context.pages.first(where: {
                $0.cid == identity.cid
            })
        else { return }

        loadTask.cancel()
        playback.stop()
        clearResumeNotice()
        requestedPlaybackIdentity = identity
        presentedPlaybackIdentity = nil
        if let retryPositionSeconds {
            requestedStartSeconds =
                retryPositionSeconds.isFinite && retryPositionSeconds >= 1
                ? Int(retryPositionSeconds) : nil
        }
        state = .failedPage(
            context: context,
            targetPage: targetPage,
            failure: failure
        )
    }

    func recordAuthenticationInvalidationIfNeeded(
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

    func clearResumeNotice() {
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
