import BiliApplication
import BiliModels
import Foundation
import Observation

public enum FeedState: Sendable, Equatable {
    case idle
    case loading(FeedRequest)
    case loaded(FeedContent)
    case failed(request: FeedRequest, error: ContentApplicationError)
}

struct FeedPresentation: Sendable, Equatable {
    let state: FeedState
    let isRefreshing: Bool
    let refreshError: ContentApplicationError?
}

/// 推荐、热门与搜索共用的分页 footer 投影。
struct FeedPaginationPresentation: Sendable, Equatable {
    static let unavailable = FeedPaginationPresentation(
        canLoadMore: false,
        tailIdentity: nil,
        isLoadingMore: false,
        loadMoreError: nil
    )

    let canLoadMore: Bool
    let tailIdentity: String?
    let isLoadingMore: Bool
    let loadMoreError: ContentApplicationError?
}

@MainActor
@Observable
/// 拥有首页推荐、热门与最后一次搜索三份独立工作集，以及当前路由的请求 Task。
///
/// `LatestTask` 与 `activeRequestIdentity` 共同阻止已取消或已切路由的结果写回；进入播放页时
/// 普通 deactivate 会保留当前三份工作集，`reset` 则清空它们；不同请求会替换对应工作集。
public final class BrowseViewModel {
    static let maximumRetainedRecommendationVideos = 1_000

    public private(set) var state: FeedState = .idle
    public private(set) var authenticationRevalidationGeneration = 0
    public private(set) var recommendationSuccessfulRefreshGeneration: UInt64 = 0
    public private(set) var popularSuccessfulRefreshGeneration: UInt64 = 0
    public private(set) var searchSuccessfulRefreshGeneration: UInt64 = 0
    private(set) var activeRequestIdentity: FeedRequest?
    private(set) var isRefreshing = false
    private(set) var refreshError: ContentApplicationError?

    @ObservationIgnored private let useCase: FeedUseCase
    @ObservationIgnored private let loadTask = LatestTask()
    @ObservationIgnored private var authenticationSessionGeneration: UInt64?
    private var recommendationWorkset = FeedWorkset()
    private var popularWorkset = FeedWorkset()
    private var searchWorkset = FeedWorkset()

    public init(useCase: FeedUseCase) {
        self.useCase = useCase
    }

    public func activateRecommendation() {
        activateWorkset(.recommendation(continuation: nil))
    }

    /// App 热门 Tab 使用的分页大小；`PopularFeedView` 按同一请求匹配 presentation。
    public static let popularPageSize = 50

    public func activatePopular(page: Int = 1, pageSize: Int = 20) {
        activateWorkset(.popular(page: page, pageSize: pageSize))
    }

    public func activateSearch(_ criteria: VideoSearchCriteria) {
        let request = FeedRequest.search(
            VideoSearchRequest(criteria: criteria, page: 1)
        )
        guard criteria.isValid else {
            fail(request: request, error: .invalidRequest)
            return
        }
        activateWorkset(request)
    }

    func refreshPopular(page: Int = 1, pageSize: Int = 20) {
        refresh(.popular(page: page, pageSize: pageSize))
    }

    func refreshRecommendation() {
        refresh(.recommendation(continuation: nil))
    }

    public func loadMoreRecommendations() {
        let baseRequest = FeedRequest.recommendation(continuation: nil)
        guard
            activeRequestIdentity == baseRequest,
            case .loaded(.recommendation(let page)) = state,
            let nextContinuation = page.nextContinuation,
            !page.videos.isEmpty,
            !isRefreshing,
            !recommendationWorkset.isLoadingMore,
            !loadTask.isRunning
        else {
            return
        }

        startAppend(
            .recommendation(continuation: nextContinuation),
            baseRequest: baseRequest
        )
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
            !loadTask.isRunning
        else {
            return
        }

        startAppend(
            .popular(page: page.pageNumber + 1, pageSize: pageSize),
            baseRequest: .popular(page: basePage, pageSize: pageSize)
        )
    }

    public func retryPopularLoadMore() {
        guard popularWorkset.loadMoreError != nil else { return }
        loadMorePopular()
    }

    public func search(_ criteria: VideoSearchCriteria) {
        let request = FeedRequest.search(
            VideoSearchRequest(criteria: criteria, page: 1)
        )
        guard criteria.isValid else {
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
            !loadTask.isRunning
        else {
            return
        }

        startAppend(
            .search(
                VideoSearchRequest(
                    criteria: baseSearchRequest.criteria,
                    page: page.pageNumber + 1
                )
            ),
            baseRequest: .search(baseSearchRequest)
        )
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
        loadTask.cancel()
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

    func retry(_ request: FeedRequest) {
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
        loadTask.cancel()
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
        for request: FeedRequest
    ) -> FeedPresentation {
        guard let workset = workset(for: request) else {
            return FeedPresentation(
                state: .idle,
                isRefreshing: false,
                refreshError: nil
            )
        }
        return FeedPresentation(
            state: workset.state,
            isRefreshing: workset.isRefreshing,
            refreshError: workset.refreshError
        )
    }

    func popularPagination(
        for request: FeedRequest
    ) -> FeedPaginationPresentation {
        guard
            case .popular(let basePage, let pageSize) = request,
            popularWorkset.request == request,
            case .loaded(.popular(let page)) = popularWorkset.state,
            page.pageNumber >= basePage,
            page.pageSize == pageSize
        else {
            return .unavailable
        }
        return pagination(
            of: popularWorkset,
            hasMore: page.hasMore && !page.videos.isEmpty,
            tailIdentity: page.videos.last.map {
                "popular|\(basePage)|\(pageSize)|\(page.pageNumber)|\($0.bvid)"
            }
        )
    }

    func recommendationPagination() -> FeedPaginationPresentation {
        let request = FeedRequest.recommendation(continuation: nil)
        guard
            recommendationWorkset.request == request,
            case .loaded(.recommendation(let page)) = recommendationWorkset.state
        else {
            return .unavailable
        }
        return pagination(
            of: recommendationWorkset,
            hasMore: page.nextContinuation != nil && !page.videos.isEmpty,
            tailIdentity: page.videos.last.map {
                "recommendation|\(page.continuation.freshIndex)|\($0.bvid)"
            }
        )
    }

    func searchPagination(
        for criteria: VideoSearchCriteria
    ) -> FeedPaginationPresentation {
        let request = FeedRequest.search(
            VideoSearchRequest(criteria: criteria, page: 1)
        )
        guard
            searchWorkset.request == request,
            case .loaded(.search(let loadedQuery, let page)) = searchWorkset.state,
            loadedQuery == criteria.query
        else {
            return .unavailable
        }
        return pagination(
            of: searchWorkset,
            hasMore: page.pageNumber < page.totalPages,
            tailIdentity: page.videos.last.map {
                "\(criteria.identityComponent)|\(page.pageNumber)|\($0.bvid)"
            }
        )
    }

    public func waitForCurrentTask() async {
        await loadTask.wait()
    }

    private func pagination(
        of workset: FeedWorkset,
        hasMore: Bool,
        tailIdentity: String?
    ) -> FeedPaginationPresentation {
        let canLoadMore = workset.loadMoreError == nil && hasMore
        return FeedPaginationPresentation(
            canLoadMore: canLoadMore,
            tailIdentity: canLoadMore ? tailIdentity : nil,
            isLoadingMore: workset.isLoadingMore,
            loadMoreError: workset.loadMoreError
        )
    }

    /// 相同请求沿用已保存的工作集，否则以新请求替换同类工作集后再切换路由。
    private func activateWorkset(_ request: FeedRequest) {
        let workset: FeedWorkset
        if let stored = self.workset(for: request) {
            workset = stored
        } else {
            workset = FeedWorkset(request: request)
            updateWorkset(for: request) { $0 = workset }
        }
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

    private func refresh(_ request: FeedRequest) {
        if activeRequestIdentity != request {
            deactivateRoute()
            activeRequestIdentity = request
            apply(workset(for: request) ?? FeedWorkset(request: request))
        }

        refreshError = nil
        updateWorkset(for: request) {
            $0.isLoadingMore = false
            $0.loadMoreError = nil
        }

        if case .loaded = state {
            isRefreshing = true
        } else {
            state = .loading(request)
            isRefreshing = false
        }
        storeActiveWorkset()
        loadTask.replace { [weak self] isCurrent in
            await self?.performLoad(request, isCurrent: isCurrent)
        }
    }

    private func fail(
        request: FeedRequest,
        error: ContentApplicationError
    ) {
        deactivateRoute()
        activeRequestIdentity = request
        state = .failed(request: request, error: error)
        storeActiveWorkset()
    }

    private func performLoad(
        _ request: FeedRequest,
        isCurrent: LatestTask.IsCurrent
    ) async {
        do {
            let content = try await useCase.execute(request)
            try Task.checkCancellation()
            guard isCurrent(), activeRequestIdentity == request else { return }
            guard contentMatches(content, request: request) else {
                throw ContentApplicationError.invalidResponse
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
            guard isCurrent(), activeRequestIdentity == request else { return }
            normalizeInterruptedLoad()
        } catch {
            guard isCurrent(), activeRequestIdentity == request else { return }
            handleFailure(error as? ContentApplicationError ?? .unavailable, request: request)
        }

        if isCurrent(), activeRequestIdentity == request {
            storeActiveWorkset()
        }
    }

    private func startAppend(
        _ request: FeedRequest,
        baseRequest: FeedRequest
    ) {
        updateWorkset(for: baseRequest) {
            $0.isLoadingMore = true
            $0.loadMoreError = nil
        }
        storeActiveWorkset()
        loadTask.replace { [weak self] isCurrent in
            await self?.performAppend(
                request,
                baseRequest: baseRequest,
                isCurrent: isCurrent
            )
        }
    }

    /// 下一页只在仍属于当前路由、且与已加载页衔接时并入；否则按无效响应记为加载更多失败。
    private func performAppend(
        _ request: FeedRequest,
        baseRequest: FeedRequest,
        isCurrent: LatestTask.IsCurrent
    ) async {
        do {
            let content = try await useCase.execute(request)
            try Task.checkCancellation()
            guard
                isCurrent(),
                activeRequestIdentity == baseRequest,
                case .loaded(let loaded) = state,
                let appended = Self.appending(content, to: loaded, for: request)
            else {
                throw ContentApplicationError.invalidResponse
            }
            state = .loaded(appended)
            updateWorkset(for: baseRequest) {
                $0.isLoadingMore = false
                $0.loadMoreError = nil
            }
        } catch is CancellationError {
            guard isCurrent(), activeRequestIdentity == baseRequest else { return }
            updateWorkset(for: baseRequest) { $0.isLoadingMore = false }
        } catch {
            guard isCurrent(), activeRequestIdentity == baseRequest else { return }
            let error = error as? ContentApplicationError ?? .unavailable
            updateWorkset(for: baseRequest) {
                $0.isLoadingMore = false
                $0.loadMoreError = error
            }
            recordAuthenticationInvalidationIfNeeded(error)
        }

        if isCurrent(), activeRequestIdentity == baseRequest {
            storeActiveWorkset()
        }
    }

    private static func appending(
        _ response: FeedContent,
        to loaded: FeedContent,
        for request: FeedRequest
    ) -> FeedContent? {
        switch (request, response, loaded) {
        case (
            .recommendation(let requestedContinuation?),
            .recommendation(let responsePage),
            .recommendation(let loadedPage)
        ):
            guard responsePage.continuation == requestedContinuation,
                loadedPage.nextContinuation == requestedContinuation
            else { return nil }
            let appended = uniqueVideos(responsePage.videos, after: loadedPage.videos, bvid: \.bvid)
            let remainingCapacity = max(
                0,
                maximumRetainedRecommendationVideos - loadedPage.videos.count
            )
            let retainedAppend = Array(appended.prefix(remainingCapacity))
            let madeProgress = !retainedAppend.isEmpty
            let hasCapacity =
                loadedPage.videos.count + retainedAppend.count
                < maximumRetainedRecommendationVideos
            return .recommendation(
                RecommendationPage(
                    videos: loadedPage.videos + retainedAppend,
                    continuation: responsePage.continuation,
                    nextContinuation: madeProgress && hasCapacity
                        ? responsePage.nextContinuation
                        : nil
                )
            )
        case (
            .popular(let requestedPage, let requestedPageSize),
            .popular(let responsePage),
            .popular(let loadedPage)
        ):
            guard requestedPage == responsePage.pageNumber,
                requestedPageSize == responsePage.pageSize,
                loadedPage.pageSize == requestedPageSize,
                loadedPage.pageNumber + 1 == responsePage.pageNumber
            else { return nil }
            let appended = uniqueVideos(responsePage.videos, after: loadedPage.videos, bvid: \.bvid)
            return .popular(
                PopularPage(
                    videos: loadedPage.videos + appended,
                    pageNumber: responsePage.pageNumber,
                    pageSize: responsePage.pageSize,
                    hasMore: responsePage.hasMore && !appended.isEmpty
                )
            )
        case (
            .search(let requestedRequest),
            .search(let responseQuery, let responsePage),
            .search(let loadedQuery, let loadedPage)
        ):
            guard requestedRequest.criteria.query == responseQuery,
                requestedRequest.page == responsePage.pageNumber,
                requestedRequest.criteria.pageSize == responsePage.pageSize,
                responsePage.pageNumber <= responsePage.totalPages,
                loadedQuery == requestedRequest.criteria.query,
                loadedPage.pageNumber + 1 == responsePage.pageNumber
            else { return nil }
            let appended = uniqueVideos(responsePage.videos, after: loadedPage.videos, bvid: \.bvid)
            return .search(
                query: requestedRequest.criteria.query,
                page: SearchPage(
                    videos: loadedPage.videos + appended,
                    pageNumber: responsePage.pageNumber,
                    pageSize: responsePage.pageSize,
                    totalResults: responsePage.totalResults,
                    totalPages: appended.isEmpty
                        ? responsePage.pageNumber
                        : responsePage.totalPages
                )
            )
        default:
            return nil
        }
    }

    /// 按 BVID 去重：丢弃与 `existing` 或自身前文重复的视频，保持原顺序。
    private static func uniqueVideos<Video>(
        _ videos: [Video],
        after existing: [Video] = [],
        bvid: (Video) -> String
    ) -> [Video] {
        var seen = Set(existing.map(bvid))
        return videos.filter { seen.insert(bvid($0)).inserted }
    }

    private func handleFailure(
        _ error: ContentApplicationError,
        request: FeedRequest
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
        _ content: FeedContent,
        request: FeedRequest
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
        _ content: FeedContent
    ) -> FeedContent {
        switch content {
        case .recommendation(let page):
            let videos = Array(
                Self.uniqueVideos(page.videos, bvid: \.bvid)
                    .prefix(Self.maximumRetainedRecommendationVideos)
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
            let videos = Self.uniqueVideos(page.videos, bvid: \.bvid)
            return .popular(
                PopularPage(
                    videos: videos,
                    pageNumber: page.pageNumber,
                    pageSize: page.pageSize,
                    hasMore: page.hasMore && !videos.isEmpty
                )
            )
        case .search(let query, let page):
            let videos = Self.uniqueVideos(page.videos, bvid: \.bvid)
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
        if let activeRequestIdentity {
            updateWorkset(for: activeRequestIdentity) { $0.isLoadingMore = false }
        }
    }

    private func recordAuthenticationInvalidationIfNeeded(
        _ error: ContentApplicationError
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
        // 加载更多标记已直接写在同类工作集上，这里只同步路由级状态。
        updateWorkset(for: activeRequestIdentity) {
            $0.request = activeRequestIdentity
            $0.state = state
            $0.isRefreshing = isRefreshing
            $0.refreshError = refreshError
        }
    }

    private func updateWorkset(
        for request: FeedRequest,
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

    private func workset(for request: FeedRequest) -> FeedWorkset? {
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
    var request: FeedRequest?
    var state: FeedState = .idle
    var isRefreshing = false
    var refreshError: ContentApplicationError?
    var isLoadingMore = false
    var loadMoreError: ContentApplicationError?
}
