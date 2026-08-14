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

public enum CollectionEpisodePagesState: Sendable, Equatable {
    case idle
    case loading
    case loaded(bvid: String)
    case failed(GuestApplicationError)
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
    public private(set) var expandedCollectionEpisodes: Set<VideoCollectionEpisodeIdentity> = []
    public private(set) var collectionEpisodePageStates:
        [VideoCollectionEpisodeIdentity: CollectionEpisodePagesState] = [:]

    @ObservationIgnored private let useCase: GuestVideoUseCase
    @ObservationIgnored private let playback: any PlaybackControlling
    @ObservationIgnored private let relatedVideoUseCase: RelatedVideoUseCase?
    @ObservationIgnored private let uploaderSignatureUseCase: UploaderSignatureUseCase?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var relatedVideoTask: Task<Void, Never>?
    @ObservationIgnored private var uploaderSignatureTask: Task<Void, Never>?
    @ObservationIgnored private var playbackFailureTask: Task<Void, Never>?
    @ObservationIgnored private var playbackIntent: PlaybackLoadIntent?
    @ObservationIgnored private var collectionEpisodeTask: Task<Void, Never>?
    @ObservationIgnored private var activeCollectionEpisodeRequest: CollectionEpisodePageRequest?
    @ObservationIgnored private var collectionEpisodeWaitersByBVID:
        [String: Set<VideoCollectionEpisodeIdentity>] = [:]
    @ObservationIgnored private var pendingCollectionEpisodeBVIDs: [String] = []
    @ObservationIgnored private var collectionEpisodeCache: [String: [VideoPage]] = [:]
    @ObservationIgnored private var collectionEpisodeCacheOrder: [String] = []
    @ObservationIgnored private var collectionSeasonID: Int64?
    @ObservationIgnored private var collectionEpisodeRequestGeneration = 0
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
        collectionEpisodeTask?.cancel()
    }

    /// 取代当前播放意图；已有非 idle 会话会先停止，避免两个 bridge/server 并存。
    public func loadVideo(_ bvid: String) {
        generation += 1
        let currentGeneration = generation
        loadTask?.cancel()
        cancelCollectionEpisodeRequest(markWaitersIdle: true)
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

    /// 合集 episode 的展开由 Feature 持有；远端未内嵌 pages 时才按 BVID 请求详情。
    public func setCollectionEpisodeExpanded(
        _ episode: VideoCollectionEpisode,
        expanded: Bool
    ) {
        guard collectionContains(episode) else { return }
        if !expanded {
            expandedCollectionEpisodes.remove(episode.id)
            removeCollectionEpisodeWaiter(episode)
            return
        }

        expandedCollectionEpisodes.insert(episode.id)
        resolveOrEnqueueCollectionEpisode(episode)
    }

    public func retryCollectionEpisodePages(
        _ episode: VideoCollectionEpisode
    ) {
        guard expandedCollectionEpisodes.contains(episode.id),
            collectionContains(episode),
            episode.isIdentityConsistent,
            let bvid = episode.bvid
        else { return }
        enqueueCollectionEpisode(episode, bvid: bvid)
    }

    public func collectionEpisodePages(
        for identity: VideoCollectionEpisodeIdentity
    ) -> [VideoPage]? {
        guard case .loaded(let bvid) = collectionEpisodePageStates[identity]
        else { return nil }
        return collectionEpisodeCache[bvid]
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
        clearCollectionEpisodeState()
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

    public func waitForCurrentCollectionEpisodeTask() async {
        await collectionEpisodeTask?.value
    }

    func collectionEpisodeTaskSnapshotForTesting() -> Task<Void, Never>? {
        collectionEpisodeTask
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
            reconcileCollectionContext(context.detail.collection)
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
            playback.beginPlayback(identity: identity, intent: intent)
            presentedPlaybackIdentity = requestedPlaybackIdentity
            state = .ready(context)
        } catch is CancellationError {
            guard generation == currentGeneration else { return }
            clearCollectionEpisodeState()
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
            playback.beginPlayback(identity: identity, intent: intent)
            presentedPlaybackIdentity = identity
            state = .ready(replacement)
        } catch is CancellationError {
            guard generation == currentGeneration else { return }
            clearCollectionEpisodeState()
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

    private func resolveOrEnqueueCollectionEpisode(
        _ episode: VideoCollectionEpisode
    ) {
        guard episode.isIdentityConsistent, let bvid = episode.bvid else {
            collectionEpisodePageStates[episode.id] = .failed(.invalidResponse)
            return
        }
        if let knownPages = episode.knownPages {
            cacheAndMarkCollectionPages(knownPages, bvid: bvid, requested: episode.id)
            return
        }
        if presentedContext?.detail.bvid == bvid,
            let pages = presentedContext?.pages,
            !pages.isEmpty
        {
            cacheAndMarkCollectionPages(pages, bvid: bvid, requested: episode.id)
            return
        }
        if collectionEpisodeCache[bvid] != nil {
            touchCollectionEpisodeCache(bvid)
            collectionEpisodePageStates[episode.id] = .loaded(bvid: bvid)
            return
        }
        enqueueCollectionEpisode(episode, bvid: bvid)
    }

    private func enqueueCollectionEpisode(
        _ episode: VideoCollectionEpisode,
        bvid: String
    ) {
        collectionEpisodeWaitersByBVID[bvid, default: []].insert(episode.id)
        collectionEpisodePageStates[episode.id] = .loading
        if activeCollectionEpisodeRequest?.bvid != bvid,
            !pendingCollectionEpisodeBVIDs.contains(bvid)
        {
            pendingCollectionEpisodeBVIDs.append(bvid)
        }
        startNextCollectionEpisodeRequestIfNeeded()
    }

    private func startNextCollectionEpisodeRequestIfNeeded() {
        guard activeCollectionEpisodeRequest == nil else { return }
        while !pendingCollectionEpisodeBVIDs.isEmpty {
            let bvid = pendingCollectionEpisodeBVIDs.removeFirst()
            guard let waiters = collectionEpisodeWaitersByBVID[bvid],
                !waiters.isEmpty,
                let seasonID = collectionSeasonID
            else { continue }
            collectionEpisodeRequestGeneration += 1
            let request = CollectionEpisodePageRequest(
                seasonID: seasonID,
                bvid: bvid,
                generation: collectionEpisodeRequestGeneration
            )
            activeCollectionEpisodeRequest = request
            let useCase = useCase
            collectionEpisodeTask = Task { [weak self, useCase] in
                let result: CollectionEpisodePageResult
                do {
                    let pages = try await useCase.pagesForCollectionEpisode(
                        bvid: request.bvid
                    )
                    try Task.checkCancellation()
                    result = .success(pages)
                } catch is CancellationError {
                    result = .cancelled
                } catch let error as GuestApplicationError {
                    result = Task.isCancelled ? .cancelled : .failure(error)
                } catch {
                    result = Task.isCancelled ? .cancelled : .failure(.unavailable)
                }
                self?.completeCollectionEpisodeRequest(request, result: result)
            }
            return
        }
    }

    private func completeCollectionEpisodeRequest(
        _ request: CollectionEpisodePageRequest,
        result: CollectionEpisodePageResult
    ) {
        guard activeCollectionEpisodeRequest == request,
            collectionSeasonID == request.seasonID
        else { return }
        let waiters = matchingCollectionEpisodeWaiters(for: request.bvid)
        switch result {
        case .success(let pages):
            do {
                let resolved = try validatedCollectionPages(pages)
                storeCollectionEpisodeCache(resolved, for: request.bvid)
                for identity in waiters {
                    collectionEpisodePageStates[identity] = .loaded(bvid: request.bvid)
                }
            } catch let error as GuestApplicationError {
                for identity in waiters {
                    collectionEpisodePageStates[identity] = .failed(error)
                }
            } catch {
                for identity in waiters {
                    collectionEpisodePageStates[identity] = .failed(.invalidResponse)
                }
            }
        case .failure(let error):
            recordAuthenticationInvalidationIfNeeded(error)
            for identity in waiters {
                collectionEpisodePageStates[identity] = .failed(error)
            }
        case .cancelled:
            for identity in waiters
            where collectionEpisodePageStates[identity] == .loading {
                collectionEpisodePageStates[identity] = .idle
            }
        }
        collectionEpisodeWaitersByBVID.removeValue(forKey: request.bvid)
        activeCollectionEpisodeRequest = nil
        collectionEpisodeTask = nil
        startNextCollectionEpisodeRequestIfNeeded()
    }

    private func cacheAndMarkCollectionPages(
        _ pages: [VideoPage],
        bvid: String,
        requested identity: VideoCollectionEpisodeIdentity
    ) {
        do {
            let resolved = try validatedCollectionPages(pages)
            storeCollectionEpisodeCache(resolved, for: bvid)
            let matchingExpanded = expandedCollectionEpisodes.filter {
                collectionEpisode(identity: $0)?.bvid == bvid
            }
            for matchingIdentity in matchingExpanded {
                collectionEpisodePageStates[matchingIdentity] = .loaded(bvid: bvid)
            }
            collectionEpisodePageStates[identity] = .loaded(bvid: bvid)
        } catch let error as GuestApplicationError {
            collectionEpisodePageStates[identity] = .failed(error)
        } catch {
            collectionEpisodePageStates[identity] = .failed(.invalidResponse)
        }
    }

    private func validatedCollectionPages(
        _ pages: [VideoPage]
    ) throws
        -> [VideoPage]
    {
        guard !pages.isEmpty,
            Set(pages.map(\.cid)).count == pages.count,
            Set(pages.map(\.index)).count == pages.count
        else {
            throw GuestApplicationError.invalidResponse
        }
        return pages.sorted(by: { $0.index < $1.index })
    }

    private func matchingCollectionEpisodeWaiters(
        for bvid: String
    )
        -> Set<VideoCollectionEpisodeIdentity>
    {
        Set(
            (collectionEpisodeWaitersByBVID[bvid] ?? []).filter { identity in
                expandedCollectionEpisodes.contains(identity)
                    && collectionEpisode(identity: identity)?.bvid == bvid
            }
        )
    }

    private func cancelCollectionEpisodeRequest(markWaitersIdle: Bool) {
        collectionEpisodeRequestGeneration += 1
        collectionEpisodeTask?.cancel()
        collectionEpisodeTask = nil
        if markWaitersIdle {
            for waiters in collectionEpisodeWaitersByBVID.values {
                for identity in waiters
                where collectionEpisodePageStates[identity] == .loading {
                    collectionEpisodePageStates[identity] = .idle
                }
            }
        }
        activeCollectionEpisodeRequest = nil
        collectionEpisodeWaitersByBVID.removeAll()
        pendingCollectionEpisodeBVIDs.removeAll()
    }

    private func removeCollectionEpisodeWaiter(
        _ episode: VideoCollectionEpisode
    ) {
        collectionEpisodePageStates[episode.id] = .idle
        guard let bvid = episode.bvid else { return }
        collectionEpisodeWaitersByBVID[bvid]?.remove(episode.id)
        guard collectionEpisodeWaitersByBVID[bvid]?.isEmpty == true else { return }
        collectionEpisodeWaitersByBVID.removeValue(forKey: bvid)
        pendingCollectionEpisodeBVIDs.removeAll(where: { $0 == bvid })
        if activeCollectionEpisodeRequest?.bvid == bvid {
            collectionEpisodeRequestGeneration += 1
            activeCollectionEpisodeRequest = nil
            let cancelledTask = collectionEpisodeTask
            collectionEpisodeTask = nil
            cancelledTask?.cancel()
            startNextCollectionEpisodeRequestIfNeeded()
        }
    }

    private func reconcileCollectionContext(_ collection: VideoCollection?) {
        guard let collection else {
            clearCollectionEpisodeState()
            return
        }
        if collectionSeasonID != collection.id {
            clearCollectionEpisodeState()
            collectionSeasonID = collection.id
            return
        }
        let validIdentities = Set(
            collection.sections.flatMap(\.episodes).map(\.id)
        )
        expandedCollectionEpisodes.formIntersection(validIdentities)
        collectionEpisodePageStates = collectionEpisodePageStates.filter {
            validIdentities.contains($0.key)
        }
        resumeExpandedCollectionEpisodeLoads()
    }

    private func resumeExpandedCollectionEpisodeLoads() {
        let identities = expandedCollectionEpisodes
        for identity in identities {
            guard let episode = collectionEpisode(identity: identity) else { continue }
            resolveOrEnqueueCollectionEpisode(episode)
        }
    }

    private func clearCollectionEpisodeState() {
        cancelCollectionEpisodeRequest(markWaitersIdle: false)
        expandedCollectionEpisodes.removeAll()
        collectionEpisodePageStates.removeAll()
        collectionEpisodeCache.removeAll()
        collectionEpisodeCacheOrder.removeAll()
        collectionSeasonID = nil
    }

    private func collectionContains(_ episode: VideoCollectionEpisode) -> Bool {
        collectionEpisode(identity: episode.id) == episode
    }

    private func collectionEpisode(
        identity: VideoCollectionEpisodeIdentity
    ) -> VideoCollectionEpisode? {
        presentedContext?.detail.collection?.sections
            .flatMap(\.episodes)
            .first(where: { $0.id == identity })
    }

    private func storeCollectionEpisodeCache(
        _ pages: [VideoPage],
        for bvid: String
    ) {
        collectionEpisodeCache[bvid] = pages
        touchCollectionEpisodeCache(bvid)
        while collectionEpisodeCacheOrder.count > 12 {
            let evicted = collectionEpisodeCacheOrder.removeFirst()
            collectionEpisodeCache.removeValue(forKey: evicted)
            let evictedIdentities = collectionEpisodePageStates.compactMap { identity, state in
                state == .loaded(bvid: evicted) ? identity : nil
            }
            for identity in evictedIdentities {
                collectionEpisodePageStates[identity] = .idle
                expandedCollectionEpisodes.remove(identity)
            }
        }
    }

    private func touchCollectionEpisodeCache(_ bvid: String) {
        collectionEpisodeCacheOrder.removeAll(where: { $0 == bvid })
        collectionEpisodeCacheOrder.append(bvid)
    }
}

private struct CollectionEpisodePageRequest: Sendable, Equatable {
    let seasonID: Int64
    let bvid: String
    let generation: Int
}

private enum CollectionEpisodePageResult: Sendable {
    case success([VideoPage])
    case failure(GuestApplicationError)
    case cancelled
}
