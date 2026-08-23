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

struct PopularPaginationPresentation: Sendable, Equatable {
    let canLoadMore: Bool
    let tailIdentity: String?
    let isLoadingMore: Bool
    let loadMoreError: GuestApplicationError?
}

struct RecommendationPaginationPresentation: Sendable, Equatable {
    let canLoadMore: Bool
    let tailIdentity: String?
    let isLoadingMore: Bool
    let loadMoreError: GuestApplicationError?
}

struct SearchPaginationPresentation: Sendable, Equatable {
    let canLoadMore: Bool
    let tailIdentity: String?
    let isLoadingMore: Bool
    let loadMoreError: GuestApplicationError?
}

@MainActor
@Observable
/// 拥有首页推荐、热门与最后一次搜索三份独立工作集，以及当前路由的请求 Task。
///
/// `generation + activeRequestIdentity` 共同阻止已取消或已切路由的结果写回；进入播放页时
/// 普通 deactivate 会保留当前三份工作集，`reset` 则清空它们；不同请求会替换对应工作集。
public final class GuestBrowseViewModel {
    static let maximumRetainedRecommendationVideos = 1_000

    public private(set) var state: GuestFeedState = .idle
    public private(set) var authenticationRevalidationGeneration = 0
    public private(set) var recommendationSuccessfulRefreshGeneration: UInt64 = 0
    public private(set) var popularSuccessfulRefreshGeneration: UInt64 = 0
    public private(set) var searchSuccessfulRefreshGeneration: UInt64 = 0
    private(set) var activeRequestIdentity: GuestFeedRequest?
    private(set) var isRefreshing = false
    private(set) var refreshError: GuestApplicationError?

    @ObservationIgnored private let useCase: GuestFeedUseCase
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var authenticationSessionGeneration: UInt64?
    private var recommendationWorkset = FeedWorkset()
    private var popularWorkset = FeedWorkset()
    private var searchWorkset = FeedWorkset()

    public init(useCase: GuestFeedUseCase) {
        self.useCase = useCase
    }

    public func activateRecommendation() {
        let request = GuestFeedRequest.recommendation(continuation: nil)
        let workset =
            recommendationWorkset.request == request
            ? recommendationWorkset
            : FeedWorkset(request: request)
        if recommendationWorkset.request != request {
            recommendationWorkset = workset
        }
        activateWorkset(request, workset: workset)
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
        activateSearch(VideoSearchCriteria(query: query))
    }

    public func activateSearch(_ criteria: VideoSearchCriteria) {
        let request = GuestFeedRequest.search(
            VideoSearchRequest(criteria: criteria, page: 1)
        )
        guard isValidSearch(criteria) else {
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

    func refreshRecommendation() {
        refresh(.recommendation(continuation: nil))
    }

    public func loadMoreRecommendations() {
        let baseRequest = GuestFeedRequest.recommendation(continuation: nil)
        guard
            activeRequestIdentity == baseRequest,
            case .loaded(.recommendation(let page)) = state,
            let nextContinuation = page.nextContinuation,
            !page.videos.isEmpty,
            !isRefreshing,
            !recommendationWorkset.isLoadingMore,
            loadTask == nil
        else {
            return
        }

        let nextRequest = GuestFeedRequest.recommendation(
            continuation: nextContinuation
        )
        generation += 1
        let currentGeneration = generation
        recommendationWorkset.isLoadingMore = true
        recommendationWorkset.loadMoreError = nil
        storeActiveWorkset()
        loadTask = Task { [weak self] in
            await self?.performRecommendationAppend(
                nextRequest,
                baseRequest: baseRequest,
                generation: currentGeneration
            )
        }
    }

    public func retryRecommendationLoadMore() {
        guard recommendationWorkset.loadMoreError != nil else { return }
        loadMoreRecommendations()
    }

    public func loadMorePopular() {
        guard
            case .popular(let basePage, let pageSize) = activeRequestIdentity,
            case .loaded(.popular(let page)) = state,
            page.pageNumber >= basePage,
            page.pageSize == pageSize,
            page.hasMore,
            !page.videos.isEmpty,
            !isRefreshing,
            !popularWorkset.isLoadingMore,
            loadTask == nil
        else {
            return
        }

        let baseRequest = GuestFeedRequest.popular(
            page: basePage,
            pageSize: pageSize
        )
        let nextRequest = GuestFeedRequest.popular(
            page: page.pageNumber + 1,
            pageSize: pageSize
        )
        generation += 1
        let currentGeneration = generation
        popularWorkset.isLoadingMore = true
        popularWorkset.loadMoreError = nil
        storeActiveWorkset()
        loadTask = Task { [weak self] in
            await self?.performPopularAppend(
                nextRequest,
                baseRequest: baseRequest,
                generation: currentGeneration
            )
        }
    }

    public func retryPopularLoadMore() {
        guard popularWorkset.loadMoreError != nil else { return }
        loadMorePopular()
    }

    public func search(_ query: String) {
        search(VideoSearchCriteria(query: query))
    }

    public func search(_ criteria: VideoSearchCriteria) {
        let request = GuestFeedRequest.search(
            VideoSearchRequest(criteria: criteria, page: 1)
        )
        guard isValidSearch(criteria) else {
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
            case .search(let baseSearchRequest) = activeRequestIdentity,
            baseSearchRequest.page == 1,
            case .loaded(.search(let loadedQuery, let page)) = state,
            loadedQuery == baseSearchRequest.criteria.query,
            page.pageNumber < page.totalPages,
            !isRefreshing,
            !searchWorkset.isLoadingMore,
            loadTask == nil
        else {
            return
        }

        let baseRequest = GuestFeedRequest.search(baseSearchRequest)
        let nextRequest = GuestFeedRequest.search(
            VideoSearchRequest(
                criteria: baseSearchRequest.criteria,
                page: page.pageNumber + 1
            )
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

    /// 丢弃上一账户范围的推荐、热门与搜索工作集；当前路由会以同一请求重新开始。
    public func synchronizeAuthenticationSession(generation newGeneration: UInt64) {
        guard authenticationSessionGeneration != newGeneration else { return }
        authenticationSessionGeneration = newGeneration

        let activeRequest = activeRequestIdentity
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        activeRequestIdentity = nil
        state = .idle
        isRefreshing = false
        refreshError = nil
        recommendationWorkset = FeedWorkset()
        popularWorkset = FeedWorkset()
        searchWorkset = FeedWorkset()
        switch activeRequest {
        case .recommendation:
            activateRecommendation()
        case .popular(let page, let pageSize):
            activatePopular(page: page, pageSize: pageSize)
        case .search(let request):
            activateSearch(request.criteria)
        case nil:
            break
        }
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

    /// 取消请求并丢弃三份内存工作集，适用于窗口关闭而非普通页面 push/pop。
    public func reset() {
        deactivateRoute()
        recommendationWorkset = FeedWorkset()
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

    func popularPagination(
        for request: GuestFeedRequest
    ) -> PopularPaginationPresentation {
        guard
            case .popular(let basePage, let pageSize) = request,
            popularWorkset.request == request,
            case .loaded(.popular(let page)) = popularWorkset.state,
            page.pageNumber >= basePage,
            page.pageSize == pageSize
        else {
            return PopularPaginationPresentation(
                canLoadMore: false,
                tailIdentity: nil,
                isLoadingMore: false,
                loadMoreError: nil
            )
        }
        let canLoadMore =
            popularWorkset.loadMoreError == nil
            && page.hasMore
            && !page.videos.isEmpty
        let tailIdentity = page.videos.last.map {
            "popular|\(basePage)|\(pageSize)|\(page.pageNumber)|\($0.bvid)"
        }
        return PopularPaginationPresentation(
            canLoadMore: canLoadMore,
            tailIdentity: canLoadMore ? tailIdentity : nil,
            isLoadingMore: popularWorkset.isLoadingMore,
            loadMoreError: popularWorkset.loadMoreError
        )
    }

    func recommendationPagination() -> RecommendationPaginationPresentation {
        let request = GuestFeedRequest.recommendation(continuation: nil)
        guard
            recommendationWorkset.request == request,
            case .loaded(.recommendation(let page)) = recommendationWorkset.state
        else {
            return RecommendationPaginationPresentation(
                canLoadMore: false,
                tailIdentity: nil,
                isLoadingMore: false,
                loadMoreError: nil
            )
        }
        let canLoadMore =
            recommendationWorkset.loadMoreError == nil
            && page.nextContinuation != nil
            && !page.videos.isEmpty
        let tailIdentity = page.videos.last.map {
            "recommendation|\(page.continuation.freshIndex)|\($0.bvid)"
        }
        return RecommendationPaginationPresentation(
            canLoadMore: canLoadMore,
            tailIdentity: canLoadMore ? tailIdentity : nil,
            isLoadingMore: recommendationWorkset.isLoadingMore,
            loadMoreError: recommendationWorkset.loadMoreError
        )
    }

    func searchPagination(
        for query: String
    ) -> SearchPaginationPresentation {
        searchPagination(for: VideoSearchCriteria(query: query))
    }

    func searchPagination(
        for criteria: VideoSearchCriteria
    ) -> SearchPaginationPresentation {
        let request = GuestFeedRequest.search(
            VideoSearchRequest(criteria: criteria, page: 1)
        )
        guard
            searchWorkset.request == request,
            case .loaded(.search(let loadedQuery, let page)) = searchWorkset.state,
            loadedQuery == criteria.query
        else {
            return SearchPaginationPresentation(
                canLoadMore: false,
                tailIdentity: nil,
                isLoadingMore: false,
                loadMoreError: nil
            )
        }
        let canLoadMore =
            searchWorkset.loadMoreError == nil
            && page.pageNumber < page.totalPages
        let tailIdentity = page.videos.last.map {
            "\(criteria.identityComponent)|\(page.pageNumber)|\($0.bvid)"
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
        switch request {
        case .recommendation:
            recommendationWorkset.isLoadingMore = false
            recommendationWorkset.loadMoreError = nil
        case .popular:
            popularWorkset.isLoadingMore = false
            popularWorkset.loadMoreError = nil
        case .search:
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
            let recordsSuccessfulRefresh = isRefreshing
            state = .loaded(normalizedContent(content))
            isRefreshing = false
            refreshError = nil
            if recordsSuccessfulRefresh {
                switch request {
                case .recommendation:
                    recommendationSuccessfulRefreshGeneration &+= 1
                case .popular:
                    popularSuccessfulRefreshGeneration &+= 1
                case .search:
                    searchSuccessfulRefreshGeneration &+= 1
                }
            }
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
                case .search(let requestedRequest) = request,
                case .search(let responseQuery, let responsePage) = content,
                requestedRequest.criteria.query == responseQuery,
                requestedRequest.page == responsePage.pageNumber,
                requestedRequest.criteria.pageSize == responsePage.pageSize,
                responsePage.pageNumber <= responsePage.totalPages,
                case .loaded(.search(let loadedQuery, let loadedPage)) = state,
                loadedQuery == requestedRequest.criteria.query,
                loadedPage.pageNumber + 1 == responsePage.pageNumber
            else {
                throw GuestApplicationError.invalidResponse
            }

            var seen = Set(loadedPage.videos.map(\.bvid))
            let appended = responsePage.videos.filter {
                seen.insert($0.bvid).inserted
            }
            let totalPages =
                appended.isEmpty
                ? responsePage.pageNumber
                : responsePage.totalPages
            state = .loaded(
                .search(
                    query: requestedRequest.criteria.query,
                    page: SearchPage(
                        videos: loadedPage.videos + appended,
                        pageNumber: responsePage.pageNumber,
                        pageSize: responsePage.pageSize,
                        totalResults: responsePage.totalResults,
                        totalPages: totalPages
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

    private func performRecommendationAppend(
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
                case .recommendation(let requestedContinuation) = request,
                let requestedContinuation,
                case .recommendation(let responsePage) = content,
                responsePage.continuation == requestedContinuation,
                case .loaded(.recommendation(let loadedPage)) = state,
                loadedPage.nextContinuation == requestedContinuation
            else {
                throw GuestApplicationError.invalidResponse
            }

            var seen = Set(loadedPage.videos.map(\.bvid))
            let appended = responsePage.videos.filter {
                seen.insert($0.bvid).inserted
            }
            let remainingCapacity = max(
                0,
                Self.maximumRetainedRecommendationVideos - loadedPage.videos.count
            )
            let retainedAppend = Array(appended.prefix(remainingCapacity))
            let madeProgress = !retainedAppend.isEmpty
            let hasCapacity =
                loadedPage.videos.count + retainedAppend.count
                < Self.maximumRetainedRecommendationVideos
            state = .loaded(
                .recommendation(
                    RecommendationPage(
                        videos: loadedPage.videos + retainedAppend,
                        continuation: responsePage.continuation,
                        nextContinuation: madeProgress && hasCapacity
                            ? responsePage.nextContinuation
                            : nil
                    )
                )
            )
            recommendationWorkset.isLoadingMore = false
            recommendationWorkset.loadMoreError = nil
        } catch is CancellationError {
            guard generation == currentGeneration, activeRequestIdentity == baseRequest else {
                return
            }
            recommendationWorkset.isLoadingMore = false
        } catch let error as GuestApplicationError {
            guard generation == currentGeneration, activeRequestIdentity == baseRequest else {
                return
            }
            recommendationWorkset.isLoadingMore = false
            recommendationWorkset.loadMoreError = error
            recordAuthenticationInvalidationIfNeeded(error)
        } catch {
            guard generation == currentGeneration, activeRequestIdentity == baseRequest else {
                return
            }
            recommendationWorkset.isLoadingMore = false
            recommendationWorkset.loadMoreError = .unavailable
        }

        if generation == currentGeneration, activeRequestIdentity == baseRequest {
            loadTask = nil
            storeActiveWorkset()
        }
    }

    private func performPopularAppend(
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
                case .popular(let requestedPage, let requestedPageSize) = request,
                case .popular(let responsePage) = content,
                requestedPage == responsePage.pageNumber,
                requestedPageSize == responsePage.pageSize,
                case .loaded(.popular(let loadedPage)) = state,
                loadedPage.pageSize == requestedPageSize,
                loadedPage.pageNumber + 1 == responsePage.pageNumber
            else {
                throw GuestApplicationError.invalidResponse
            }

            var seen = Set(loadedPage.videos.map(\.bvid))
            let appended = responsePage.videos.filter {
                seen.insert($0.bvid).inserted
            }
            let madeProgress = !appended.isEmpty
            state = .loaded(
                .popular(
                    PopularPage(
                        videos: loadedPage.videos + appended,
                        pageNumber: responsePage.pageNumber,
                        pageSize: responsePage.pageSize,
                        hasMore: responsePage.hasMore && madeProgress
                    )
                )
            )
            popularWorkset.isLoadingMore = false
            popularWorkset.loadMoreError = nil
        } catch is CancellationError {
            guard generation == currentGeneration, activeRequestIdentity == baseRequest else {
                return
            }
            popularWorkset.isLoadingMore = false
        } catch let error as GuestApplicationError {
            guard generation == currentGeneration, activeRequestIdentity == baseRequest else {
                return
            }
            popularWorkset.isLoadingMore = false
            popularWorkset.loadMoreError = error
        } catch {
            guard generation == currentGeneration, activeRequestIdentity == baseRequest else {
                return
            }
            popularWorkset.isLoadingMore = false
            popularWorkset.loadMoreError = .unavailable
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
        recordAuthenticationInvalidationIfNeeded(error)
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
        case (
            .recommendation(let requestedContinuation),
            .recommendation(let page)
        ):
            page.continuation
                == (requestedContinuation ?? RecommendationContinuation(freshIndex: 1))
        case (.popular(let requestedPage, let requestedSize), .popular(let page)):
            page.pageNumber == requestedPage && page.pageSize == requestedSize
        case (
            .search(let requestedRequest),
            .search(let responseQuery, let page)
        ):
            responseQuery == requestedRequest.criteria.query
                && page.pageNumber == requestedRequest.page
                && page.pageSize == requestedRequest.criteria.pageSize
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
        switch content {
        case .recommendation(let page):
            var seen: Set<String> = []
            let uniqueVideos = page.videos.filter {
                seen.insert($0.bvid).inserted
            }
            let videos = Array(
                uniqueVideos.prefix(Self.maximumRetainedRecommendationVideos)
            )
            return .recommendation(
                RecommendationPage(
                    videos: videos,
                    continuation: page.continuation,
                    nextContinuation:
                        videos.isEmpty
                        || videos.count == Self.maximumRetainedRecommendationVideos
                        ? nil
                        : page.nextContinuation
                )
            )
        case .popular(let page):
            var seen: Set<String> = []
            let videos = page.videos.filter { seen.insert($0.bvid).inserted }
            return .popular(
                PopularPage(
                    videos: videos,
                    pageNumber: page.pageNumber,
                    pageSize: page.pageSize,
                    hasMore: page.hasMore && !videos.isEmpty
                )
            )
        case .search(let query, let page):
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
    }

    private func normalizeInterruptedLoad() {
        isRefreshing = false
        refreshError = nil
        if case .loading = state {
            state = .idle
        }
        switch activeRequestIdentity {
        case .recommendation:
            recommendationWorkset.isLoadingMore = false
        case .popular:
            popularWorkset.isLoadingMore = false
        case .search:
            searchWorkset.isLoadingMore = false
        case nil:
            break
        }
    }

    private func recordAuthenticationInvalidationIfNeeded(
        _ error: GuestApplicationError
    ) {
        guard error == .authenticationInvalid else { return }
        authenticationRevalidationGeneration &+= 1
    }

    private func apply(_ workset: FeedWorkset) {
        state = workset.state
        isRefreshing = workset.isRefreshing
        refreshError = workset.refreshError
    }

    private func storeActiveWorkset() {
        guard let activeRequestIdentity else { return }
        let isLoadingMore: Bool
        let loadMoreError: GuestApplicationError?
        switch activeRequestIdentity {
        case .recommendation:
            isLoadingMore = recommendationWorkset.isLoadingMore
            loadMoreError = recommendationWorkset.loadMoreError
        case .popular:
            isLoadingMore = popularWorkset.isLoadingMore
            loadMoreError = popularWorkset.loadMoreError
        case .search:
            isLoadingMore = searchWorkset.isLoadingMore
            loadMoreError = searchWorkset.loadMoreError
        }
        updateWorkset(for: activeRequestIdentity) {
            $0.request = activeRequestIdentity
            $0.state = state
            $0.isRefreshing = isRefreshing
            $0.refreshError = refreshError
            $0.isLoadingMore = isLoadingMore
            $0.loadMoreError = loadMoreError
        }
    }

    private func updateWorkset(
        for request: GuestFeedRequest,
        _ update: (inout FeedWorkset) -> Void
    ) {
        switch request {
        case .recommendation:
            update(&recommendationWorkset)
        case .popular:
            update(&popularWorkset)
        case .search:
            update(&searchWorkset)
        }
    }

    private func workset(for request: GuestFeedRequest) -> FeedWorkset? {
        switch request {
        case .recommendation:
            guard recommendationWorkset.request == request else { return nil }
            return recommendationWorkset
        case .popular:
            guard popularWorkset.request == request else { return nil }
            return popularWorkset
        case .search:
            guard searchWorkset.request == request else { return nil }
            return searchWorkset
        }
    }

    private func isValidSearch(_ criteria: VideoSearchCriteria) -> Bool {
        guard !criteria.query.isEmpty,
            criteria.query.count <= 100,
            criteria.pageSize == VideoSearchCriteria.pageSize
        else { return false }
        guard let range = criteria.publicationRange else { return true }
        return range.beginTimestamp >= 0
            && range.beginTimestamp <= range.endTimestamp
    }
}

extension VideoSearchCriteria {
    fileprivate var identityComponent: String {
        let range =
            publicationRange.map {
                "\($0.beginTimestamp)-\($0.endTimestamp)"
            } ?? "all"
        return "\(query)|\(order.rawValue)|\(duration.rawValue)|\(range)|\(pageSize)"
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
