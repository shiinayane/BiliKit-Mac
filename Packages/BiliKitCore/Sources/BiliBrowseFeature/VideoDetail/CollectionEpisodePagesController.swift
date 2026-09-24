import BiliApplication
import BiliModels
import Observation

/// 拥有合集 episode 的选择、pages 串行请求队列与有界缓存。
///
/// 同一时刻最多一个 pages 请求；等待者按 BVID 合并，旧请求以 request identity 隔离。
/// 只在 `reconcile` 时接收视频 context，从不回读 ViewModel。
@MainActor
@Observable
final class CollectionEpisodePagesController {
    /// 最多缓存多少个 BVID 的 pages；淘汰时对应 episode 回到 idle。
    static let maximumCachedPageSets = 12

    /// Picker 当前请求的合集 episode；可能先于新视频 context 到达。
    private(set) var selectedEpisode: VideoCollectionEpisodeIdentity?
    private(set) var pageStates: [VideoCollectionEpisodeIdentity: CollectionEpisodePagesState] =
        [:]
    /// 请求确认凭据失效时通知 owner 协调账户重校验。
    @ObservationIgnored var onAuthenticationInvalid: (@MainActor () -> Void)?

    @ObservationIgnored private let useCase: GuestVideoUseCase
    /// 最近一次 reconcile 的视频 context；分 P 切换不改变其 detail 与 pages。
    @ObservationIgnored private var context: GuestVideoContext?
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var activeRequest: PageRequest?
    @ObservationIgnored private var waitersByBVID: [String: Set<VideoCollectionEpisodeIdentity>] =
        [:]
    @ObservationIgnored private var pendingBVIDs: [String] = []
    @ObservationIgnored private var cache: [String: [VideoPage]] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []
    @ObservationIgnored private var selectionHandler: ((String, Int64?) -> Void)?
    @ObservationIgnored private var selectionIsExplicit = false
    @ObservationIgnored private var seasonID: Int64?
    @ObservationIgnored private var requestGeneration = 0

    init(useCase: GuestVideoUseCase) {
        self.useCase = useCase
    }

    deinit {
        task?.cancel()
    }

    /// Picker 选择 episode 后解析其 pages；未知 pages 只在校验完成后调用 `onResolved`。
    func select(
        _ episode: VideoCollectionEpisode,
        onResolved: @escaping (String, Int64?) -> Void
    ) {
        guard contains(episode) else { return }
        if selectedEpisode != episode.id {
            clearSelectedRequest(preservingRequestForBVID: episode.bvid)
        }
        selectedEpisode = episode.id
        selectionIsExplicit = true
        selectionHandler = onResolved
        resolveOrEnqueue(episode)
    }

    func retry(_ episode: VideoCollectionEpisode) {
        guard selectedEpisode == episode.id,
            contains(episode),
            episode.isIdentityConsistent,
            let bvid = episode.bvid
        else { return }
        enqueue(episode, bvid: bvid)
    }

    func pages(for identity: VideoCollectionEpisodeIdentity) -> [VideoPage]? {
        guard case .loaded(let bvid) = pageStates[identity] else { return nil }
        return cache[bvid]
    }

    /// 新视频 context 到达后对齐合集范围与当前 episode；`preferredCID` 是用户显式请求的分 P。
    func reconcile(with context: GuestVideoContext, preferredCID: Int64?) {
        guard let collection = context.detail.collection else {
            clear()
            return
        }
        if seasonID != collection.id {
            let explicitSelection = selectionIsExplicit ? selectedEpisode : nil
            clear()
            self.context = context
            seasonID = collection.id
            if let explicitSelection,
                collection.sections.flatMap(\.episodes).contains(where: {
                    $0.id == explicitSelection
                })
            {
                selectedEpisode = explicitSelection
                selectionIsExplicit = true
            }
            synchronizeSelection(preferredCID: preferredCID)
            return
        }
        self.context = context
        let validIdentities = Set(collection.sections.flatMap(\.episodes).map(\.id))
        if let selectedEpisode, !validIdentities.contains(selectedEpisode) {
            self.selectedEpisode = nil
            selectionIsExplicit = false
            selectionHandler = nil
        }
        pageStates = pageStates.filter { validIdentities.contains($0.key) }
        synchronizeSelection(preferredCID: preferredCID)
    }

    /// 取消在途与排队的请求，仍在 loading 的 episode 回到 idle；选择与缓存保留。
    func cancelRequests() {
        cancelRequests(markWaitersIdle: true)
    }

    /// 离开视频或合集范围时丢弃全部选择、状态与缓存。
    func clear() {
        cancelRequests(markWaitersIdle: false)
        selectedEpisode = nil
        selectionIsExplicit = false
        selectionHandler = nil
        pageStates.removeAll()
        cache.removeAll()
        cacheOrder.removeAll()
        seasonID = nil
        context = nil
    }

    private func resolveOrEnqueue(_ episode: VideoCollectionEpisode) {
        guard episode.isIdentityConsistent, let bvid = episode.bvid else {
            pageStates[episode.id] = .failed(.invalidResponse)
            return
        }
        if let knownPages = episode.knownPages {
            cacheAndMark(knownPages, bvid: bvid, requested: episode.id)
            return
        }
        if context?.detail.bvid == bvid,
            let pages = context?.pages,
            !pages.isEmpty
        {
            cacheAndMark(pages, bvid: bvid, requested: episode.id)
            return
        }
        if cache[bvid] != nil {
            touchCache(bvid)
            pageStates[episode.id] = .loaded(bvid: bvid)
            completeSelectionIfPossible(episode)
            return
        }
        enqueue(episode, bvid: bvid)
    }

    private func enqueue(_ episode: VideoCollectionEpisode, bvid: String) {
        waitersByBVID[bvid, default: []].insert(episode.id)
        pageStates[episode.id] = .loading
        if activeRequest?.bvid != bvid, !pendingBVIDs.contains(bvid) {
            pendingBVIDs.append(bvid)
        }
        startNextRequestIfNeeded()
    }

    private func startNextRequestIfNeeded() {
        guard activeRequest == nil else { return }
        while !pendingBVIDs.isEmpty {
            let bvid = pendingBVIDs.removeFirst()
            guard let waiters = waitersByBVID[bvid],
                !waiters.isEmpty,
                let seasonID
            else { continue }
            requestGeneration += 1
            let request = PageRequest(
                seasonID: seasonID,
                bvid: bvid,
                generation: requestGeneration
            )
            activeRequest = request
            let useCase = useCase
            task = Task { [weak self, useCase] in
                let result: PageResult
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
                self?.complete(request, result: result)
            }
            return
        }
    }

    private func complete(_ request: PageRequest, result: PageResult) {
        guard activeRequest == request, seasonID == request.seasonID else { return }
        let waiters = matchingWaiters(for: request.bvid)
        switch result {
        case .success(let pages):
            do {
                let resolved = try validated(pages)
                storeInCache(resolved, for: request.bvid)
                for identity in waiters {
                    pageStates[identity] = .loaded(bvid: request.bvid)
                }
                completeSelectionIfPossible()
            } catch let error as GuestApplicationError {
                for identity in waiters {
                    pageStates[identity] = .failed(error)
                }
            } catch {
                for identity in waiters {
                    pageStates[identity] = .failed(.invalidResponse)
                }
            }
        case .failure(let error):
            if error == .authenticationInvalid {
                onAuthenticationInvalid?()
            }
            for identity in waiters {
                pageStates[identity] = .failed(error)
            }
        case .cancelled:
            for identity in waiters where pageStates[identity] == .loading {
                pageStates[identity] = .idle
            }
        }
        waitersByBVID.removeValue(forKey: request.bvid)
        activeRequest = nil
        task = nil
        startNextRequestIfNeeded()
    }

    private func cacheAndMark(
        _ pages: [VideoPage],
        bvid: String,
        requested identity: VideoCollectionEpisodeIdentity
    ) {
        do {
            let resolved = try validated(pages)
            storeInCache(resolved, for: bvid)
            pageStates[identity] = .loaded(bvid: bvid)
            completeSelectionIfPossible()
        } catch let error as GuestApplicationError {
            pageStates[identity] = .failed(error)
        } catch {
            pageStates[identity] = .failed(.invalidResponse)
        }
    }

    private func validated(_ pages: [VideoPage]) throws -> [VideoPage] {
        guard !pages.isEmpty,
            Set(pages.map(\.cid)).count == pages.count,
            Set(pages.map(\.index)).count == pages.count
        else {
            throw GuestApplicationError.invalidResponse
        }
        return pages.sorted(by: { $0.index < $1.index })
    }

    private func matchingWaiters(for bvid: String) -> Set<VideoCollectionEpisodeIdentity> {
        Set(
            (waitersByBVID[bvid] ?? []).filter { identity in
                selectedEpisode == identity && episode(identity: identity)?.bvid == bvid
            }
        )
    }

    private func cancelRequests(markWaitersIdle: Bool) {
        requestGeneration += 1
        task?.cancel()
        task = nil
        if markWaitersIdle {
            for waiters in waitersByBVID.values {
                for identity in waiters where pageStates[identity] == .loading {
                    pageStates[identity] = .idle
                }
            }
        }
        activeRequest = nil
        waitersByBVID.removeAll()
        pendingBVIDs.removeAll()
    }

    private func removeWaiter(_ episode: VideoCollectionEpisode) {
        pageStates[episode.id] = .idle
        guard let bvid = episode.bvid else { return }
        waitersByBVID[bvid]?.remove(episode.id)
        guard waitersByBVID[bvid]?.isEmpty == true else { return }
        waitersByBVID.removeValue(forKey: bvid)
        pendingBVIDs.removeAll(where: { $0 == bvid })
        if activeRequest?.bvid == bvid {
            requestGeneration += 1
            activeRequest = nil
            let cancelledTask = task
            task = nil
            cancelledTask?.cancel()
            startNextRequestIfNeeded()
        }
    }

    private func synchronizeSelection(preferredCID: Int64?) {
        guard let context else { return }
        let episodes = context.detail.collection?.sections.flatMap(\.episodes) ?? []
        let explicitSelection = selectionIsExplicit ? selectedEpisode : nil
        let explicitSelectionForContext = explicitSelection.flatMap { identity in
            episodes.first(where: {
                $0.id == identity && $0.bvid == context.detail.bvid
            })?.id
        }
        let currentEpisode = PlaybackCollectionEpisodeResolver.resolve(
            episodes: episodes,
            explicitlySelectedID: explicitSelectionForContext,
            bvid: context.detail.bvid,
            cid: preferredCID ?? context.selectedPage.cid
        )
        selectedEpisode = currentEpisode?.id
        selectionIsExplicit = currentEpisode?.id == explicitSelectionForContext
        selectionHandler = nil
        guard let currentEpisode else { return }
        cacheAndMark(context.pages, bvid: context.detail.bvid, requested: currentEpisode.id)
    }

    private func contains(_ episode: VideoCollectionEpisode) -> Bool {
        self.episode(identity: episode.id) == episode
    }

    private func episode(identity: VideoCollectionEpisodeIdentity) -> VideoCollectionEpisode? {
        context?.detail.collection?.sections
            .flatMap(\.episodes)
            .first(where: { $0.id == identity })
    }

    private func storeInCache(_ pages: [VideoPage], for bvid: String) {
        cache[bvid] = pages
        touchCache(bvid)
        while cacheOrder.count > Self.maximumCachedPageSets {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
            let evictedIdentities = pageStates.compactMap { identity, state in
                state == .loaded(bvid: evicted) ? identity : nil
            }
            for identity in evictedIdentities {
                pageStates[identity] = .idle
            }
        }
    }

    private func touchCache(_ bvid: String) {
        cacheOrder.removeAll(where: { $0 == bvid })
        cacheOrder.append(bvid)
    }

    private func clearSelectedRequest(preservingRequestForBVID preservedBVID: String?) {
        guard let selectedEpisode, let episode = episode(identity: selectedEpisode) else {
            self.selectedEpisode = nil
            selectionIsExplicit = false
            selectionHandler = nil
            return
        }
        if episode.bvid == preservedBVID,
            let bvid = episode.bvid,
            activeRequest?.bvid == bvid
        {
            pageStates[episode.id] = .idle
            waitersByBVID[bvid]?.remove(episode.id)
        } else {
            removeWaiter(episode)
        }
        self.selectedEpisode = nil
        selectionIsExplicit = false
        selectionHandler = nil
    }

    private func completeSelectionIfPossible(_ resolvedEpisode: VideoCollectionEpisode? = nil) {
        guard let selectedEpisode,
            let episode = resolvedEpisode ?? episode(identity: selectedEpisode),
            episode.id == selectedEpisode,
            episode.isIdentityConsistent,
            let bvid = episode.bvid,
            case .loaded(let loadedBVID) = pageStates[episode.id],
            loadedBVID == bvid,
            let pages = cache[bvid],
            !pages.isEmpty
        else { return }
        if let defaultCID = episode.defaultCID,
            !pages.contains(where: { $0.cid == defaultCID })
        {
            pageStates[episode.id] = .failed(.invalidResponse)
            return
        }
        let handler = selectionHandler
        selectionHandler = nil
        handler?(bvid, episode.defaultCID ?? pages.first?.cid)
    }
}

private struct PageRequest: Sendable, Equatable {
    let seasonID: Int64
    let bvid: String
    let generation: Int
}

private enum PageResult: Sendable {
    case success([VideoPage])
    case failure(GuestApplicationError)
    case cancelled
}
