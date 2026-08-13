import BiliApplication
import BiliModels
import Foundation
import Observation

public enum GuestFeedState: Sendable, Equatable {
    case idle
    case loading(GuestFeedRequest)
    case loaded(GuestFeedContent)
    case failed(request: GuestFeedRequest, error: GuestApplicationError)
}

struct GuestFeedPresentation: Sendable, Equatable {
    let state: GuestFeedState
    let isRefreshing: Bool
    let refreshError: GuestApplicationError?
}

struct SearchPaginationPresentation: Sendable, Equatable {
    let canLoadMore: Bool
    let tailIdentity: String?
    let isLoadingMore: Bool
    let loadMoreError: GuestApplicationError?
}

@MainActor
@Observable
/// 拥有热门与最后一次搜索两份独立工作集，以及当前路由的请求 Task。
///
/// `generation + activeRequestIdentity` 共同阻止已取消或已切路由的结果写回；进入播放页时
/// 普通 deactivate 会保留当前两份工作集，`reset` 则清空两者；不同请求会替换对应工作集。
public final class GuestBrowseViewModel {
    public private(set) var state: GuestFeedState = .idle
    private(set) var activeRequestIdentity: GuestFeedRequest?
    private(set) var isRefreshing = false
    private(set) var refreshError: GuestApplicationError?

    @ObservationIgnored private let useCase: GuestFeedUseCase
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    private var popularWorkset = FeedWorkset()
    private var searchWorkset = FeedWorkset()

    public init(useCase: GuestFeedUseCase) {
        self.useCase = useCase
    }

    public func activatePopular(page: Int = 1, pageSize: Int = 20) {
        let request = GuestFeedRequest.popular(page: page, pageSize: pageSize)
        let workset =
            popularWorkset.request == request
            ? popularWorkset
            : FeedWorkset(request: request)
        if popularWorkset.request != request {
            popularWorkset = workset
        }
        activateWorkset(request, workset: workset)
    }

    public func activateSearch(_ query: String) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = GuestFeedRequest.search(query: normalizedQuery, page: 1)
        guard isValidSearch(normalizedQuery) else {
            fail(request: request, error: .invalidRequest)
            return
        }

        let workset =
            searchWorkset.request == request
            ? searchWorkset
            : FeedWorkset(request: request)
        if searchWorkset.request != request {
            searchWorkset = workset
        }
        activateWorkset(request, workset: workset)
    }

    func refreshPopular(page: Int = 1, pageSize: Int = 20) {
        refresh(.popular(page: page, pageSize: pageSize))
    }

    public func search(_ query: String) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = GuestFeedRequest.search(query: normalizedQuery, page: 1)
        guard isValidSearch(normalizedQuery) else {
            fail(request: request, error: .invalidRequest)
            return
        }
        if searchWorkset.request != request {
            searchWorkset = FeedWorkset(request: request)
        }
        refresh(request)
    }

    public func loadMoreSearch() {
        guard
            case .search(let query, 1) = activeRequestIdentity,
            case .loaded(.search(let loadedQuery, let page)) = state,
            loadedQuery == query,
            page.pageNumber < page.totalPages,
            !isRefreshing,
            !searchWorkset.isLoadingMore,
            loadTask == nil
        else {
            return
        }

        let baseRequest = GuestFeedRequest.search(query: query, page: 1)
        let nextRequest = GuestFeedRequest.search(
            query: query,
            page: page.pageNumber + 1
        )
        generation += 1
        let currentGeneration = generation
        searchWorkset.isLoadingMore = true
        searchWorkset.loadMoreError = nil
        storeActiveWorkset()
        loadTask = Task { [weak self] in
            await self?.performSearchAppend(
                nextRequest,
                baseRequest: baseRequest,
                generation: currentGeneration
            )
        }
    }

    public func retrySearchLoadMore() {
        guard searchWorkset.loadMoreError != nil else { return }
        loadMoreSearch()
    }

    func retry(_ request: GuestFeedRequest) {
        guard
            case .failed(let failedRequest, _) =
                presentation(for: request).state,
            failedRequest == request
        else {
            return
        }
        refresh(request)
    }

    /// 停止当前路由工作，但把规范化后的状态保存回对应工作集供返回时恢复。
    public func deactivateRoute() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        normalizeInterruptedLoad()
        storeActiveWorkset()
        activeRequestIdentity = nil
        state = .idle
        isRefreshing = false
        refreshError = nil
    }

    /// 取消请求并丢弃两份内存工作集，适用于窗口关闭而非普通页面 push/pop。
    public func reset() {
        deactivateRoute()
        popularWorkset = FeedWorkset()
        searchWorkset = FeedWorkset()
    }

    func presentation(
        for request: GuestFeedRequest
    ) -> GuestFeedPresentation {
        guard let workset = workset(for: request) else {
            return GuestFeedPresentation(
                state: .idle,
                isRefreshing: false,
                refreshError: nil
            )
        }
        return GuestFeedPresentation(
            state: workset.state,
            isRefreshing: workset.isRefreshing,
            refreshError: workset.refreshError
        )
    }

    func searchPagination(
        for query: String
    ) -> SearchPaginationPresentation {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = GuestFeedRequest.search(query: normalizedQuery, page: 1)
        guard
            searchWorkset.request == request,
            case .loaded(.search(let loadedQuery, let page)) = searchWorkset.state,
            loadedQuery == normalizedQuery
        else {
            return SearchPaginationPresentation(
                canLoadMore: false,
                tailIdentity: nil,
                isLoadingMore: false,
                loadMoreError: nil
            )
        }
        let canLoadMore = page.pageNumber < page.totalPages
        let tailIdentity = page.videos.last.map {
            "\(normalizedQuery)|\(page.pageNumber)|\($0.bvid)"
        }
        return SearchPaginationPresentation(
            canLoadMore: canLoadMore,
            tailIdentity: canLoadMore ? tailIdentity : nil,
            isLoadingMore: searchWorkset.isLoadingMore,
            loadMoreError: searchWorkset.loadMoreError
        )
    }

    public func waitForCurrentTask() async {
        await loadTask?.value
    }

    func taskSnapshotForTesting() -> Task<Void, Never>? {
        loadTask
    }

    private func activateWorkset(
        _ request: GuestFeedRequest,
        workset: FeedWorkset
    ) {
        if activeRequestIdentity == request {
            if case .idle = state {
                refresh(request)
            }
            return
        }

        deactivateRoute()
        activeRequestIdentity = request
        apply(workset)
        if case .idle = state {
            refresh(request)
        }
    }

    private func refresh(_ request: GuestFeedRequest) {
        if activeRequestIdentity != request {
            deactivateRoute()
            activeRequestIdentity = request
            apply(workset(for: request) ?? FeedWorkset(request: request))
        }

        generation += 1
        let currentGeneration = generation
        loadTask?.cancel()
        refreshError = nil
        if case .search = request {
            searchWorkset.isLoadingMore = false
            searchWorkset.loadMoreError = nil
        }

        if case .loaded = state {
            isRefreshing = true
        } else {
            state = .loading(request)
            isRefreshing = false
        }
        storeActiveWorkset()
        loadTask = Task { [weak self] in
            await self?.performLoad(request, generation: currentGeneration)
        }
    }

    private func fail(
        request: GuestFeedRequest,
        error: GuestApplicationError
    ) {
        deactivateRoute()
        activeRequestIdentity = request
        state = .failed(request: request, error: error)
        storeActiveWorkset()
    }

    private func performLoad(
        _ request: GuestFeedRequest,
        generation currentGeneration: Int
    ) async {
        do {
            let content = try await useCase.execute(request)
            try Task.checkCancellation()
            guard generation == currentGeneration, activeRequestIdentity == request else {
                return
            }
            guard contentMatches(content, request: request) else {
                throw GuestApplicationError.invalidResponse
            }
            state = .loaded(normalizedContent(content))
            isRefreshing = false
            refreshError = nil
        } catch is CancellationError {
            guard generation == currentGeneration, activeRequestIdentity == request else {
                return
            }
            normalizeInterruptedLoad()
        } catch let error as GuestApplicationError {
            guard generation == currentGeneration, activeRequestIdentity == request else {
                return
            }
            handleFailure(error, request: request)
        } catch {
            guard generation == currentGeneration, activeRequestIdentity == request else {
                return
            }
            handleFailure(.unavailable, request: request)
        }

        if generation == currentGeneration, activeRequestIdentity == request {
            loadTask = nil
            storeActiveWorkset()
        }
    }

    private func performSearchAppend(
        _ request: GuestFeedRequest,
        baseRequest: GuestFeedRequest,
        generation currentGeneration: Int
    ) async {
        do {
            let content = try await useCase.execute(request)
            try Task.checkCancellation()
            guard
                generation == currentGeneration,
                activeRequestIdentity == baseRequest,
                case .search(let requestedQuery, let requestedPage) = request,
                case .search(let responseQuery, let responsePage) = content,
                requestedQuery == responseQuery,
                requestedPage == responsePage.pageNumber,
                responsePage.pageNumber <= responsePage.totalPages,
                case .loaded(.search(let loadedQuery, let loadedPage)) = state,
                loadedQuery == requestedQuery,
                loadedPage.pageNumber + 1 == responsePage.pageNumber
            else {
                throw GuestApplicationError.invalidResponse
            }

            var seen = Set(loadedPage.videos.map(\.bvid))
            let appended = responsePage.videos.filter {
                seen.insert($0.bvid).inserted
            }
            state = .loaded(
                .search(
                    query: requestedQuery,
                    page: SearchPage(
                        videos: loadedPage.videos + appended,
                        pageNumber: responsePage.pageNumber,
                        pageSize: responsePage.pageSize,
                        totalResults: responsePage.totalResults,
                        totalPages: responsePage.totalPages
                    )
                )
            )
            searchWorkset.isLoadingMore = false
            searchWorkset.loadMoreError = nil
        } catch is CancellationError {
            guard generation == currentGeneration, activeRequestIdentity == baseRequest else {
                return
            }
            searchWorkset.isLoadingMore = false
        } catch let error as GuestApplicationError {
            guard generation == currentGeneration, activeRequestIdentity == baseRequest else {
                return
            }
            searchWorkset.isLoadingMore = false
            searchWorkset.loadMoreError = error
        } catch {
            guard generation == currentGeneration, activeRequestIdentity == baseRequest else {
                return
            }
            searchWorkset.isLoadingMore = false
            searchWorkset.loadMoreError = .unavailable
        }

        if generation == currentGeneration, activeRequestIdentity == baseRequest {
            loadTask = nil
            storeActiveWorkset()
        }
    }

    private func handleFailure(
        _ error: GuestApplicationError,
        request: GuestFeedRequest
    ) {
        if case .loaded = state {
            isRefreshing = false
            refreshError = error
        } else {
            state = .failed(request: request, error: error)
        }
    }

    private func contentMatches(
        _ content: GuestFeedContent,
        request: GuestFeedRequest
    ) -> Bool {
        switch (request, content) {
        case (.popular(let requestedPage, let requestedSize), .popular(let page)):
            page.pageNumber == requestedPage && page.pageSize == requestedSize
        case (
            .search(let requestedQuery, let requestedPage),
            .search(let responseQuery, let page)
        ):
            responseQuery == requestedQuery
                && page.pageNumber == requestedPage
                && page.pageSize > 0
                && page.totalResults >= 0
                && (page.totalPages >= page.pageNumber
                    || (page.totalPages == 0 && page.videos.isEmpty))
        default:
            false
        }
    }

    private func normalizedContent(
        _ content: GuestFeedContent
    ) -> GuestFeedContent {
        guard case .search(let query, let page) = content else {
            return content
        }
        var seen: Set<String> = []
        let videos = page.videos.filter { seen.insert($0.bvid).inserted }
        return .search(
            query: query,
            page: SearchPage(
                videos: videos,
                pageNumber: page.pageNumber,
                pageSize: page.pageSize,
                totalResults: page.totalResults,
                totalPages: page.totalPages
            )
        )
    }

    private func normalizeInterruptedLoad() {
        isRefreshing = false
        refreshError = nil
        if case .loading = state {
            state = .idle
        }
        searchWorkset.isLoadingMore = false
    }

    private func apply(_ workset: FeedWorkset) {
        state = workset.state
        isRefreshing = workset.isRefreshing
        refreshError = workset.refreshError
    }

    private func storeActiveWorkset() {
        guard let activeRequestIdentity else { return }
        let searchIsLoadingMore = searchWorkset.isLoadingMore
        let searchLoadMoreError = searchWorkset.loadMoreError
        updateWorkset(for: activeRequestIdentity) {
            $0.request = activeRequestIdentity
            $0.state = state
            $0.isRefreshing = isRefreshing
            $0.refreshError = refreshError
            if case .search = activeRequestIdentity {
                $0.isLoadingMore = searchIsLoadingMore
                $0.loadMoreError = searchLoadMoreError
            }
        }
    }

    private func updateWorkset(
        for request: GuestFeedRequest,
        _ update: (inout FeedWorkset) -> Void
    ) {
        switch request {
        case .popular:
            update(&popularWorkset)
        case .search:
            update(&searchWorkset)
        }
    }

    private func workset(for request: GuestFeedRequest) -> FeedWorkset? {
        switch request {
        case .popular:
            guard popularWorkset.request == request else { return nil }
            return popularWorkset
        case .search:
            guard searchWorkset.request == request else { return nil }
            return searchWorkset
        }
    }

    private func isValidSearch(_ query: String) -> Bool {
        !query.isEmpty && query.count <= 100
    }
}

private struct FeedWorkset {
    var request: GuestFeedRequest?
    var state: GuestFeedState = .idle
    var isRefreshing = false
    var refreshError: GuestApplicationError?
    var isLoadingMore = false
    var loadMoreError: GuestApplicationError?
}
