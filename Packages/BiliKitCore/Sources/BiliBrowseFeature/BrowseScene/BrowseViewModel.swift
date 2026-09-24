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

/// 首页推荐、热门与搜索三个来源；各自拥有独立工作集，互不共享可被污染的状态。
public enum FeedSource: Sendable, Hashable, CaseIterable {
    case recommendation
    case popular
    case search
}

extension FeedRequest {
    var source: FeedSource {
        switch self {
        case .recommendation: .recommendation
        case .popular: .popular
        case .search: .search
        }
    }
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
    private var successfulRefreshGenerations: [FeedSource: UInt64] = [:]
    private(set) var activeRequestIdentity: FeedRequest?
    private(set) var isRefreshing = false
    private(set) var refreshError: ContentApplicationError?

    @ObservationIgnored private let useCase: FeedUseCase
    @ObservationIgnored private let loadTask = LatestTask()
    @ObservationIgnored private var authenticationSessionGeneration: UInt64?
    private var worksets: [FeedSource: FeedWorkset] = [:]

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

    /// 该来源刷新成功的次数；App 只在它前进时把对应网格滚回顶部。
    public func successfulRefreshGeneration(for source: FeedSource) -> UInt64 {
        successfulRefreshGenerations[source, default: 0]
    }

    /// 为当前路由的来源加载下一页；只在已加载内容仍能衔接且没有其他请求时发出。
    public func loadMore(_ source: FeedSource) {
        guard
            let baseRequest = activeRequestIdentity,
            baseRequest.source == source,
            case .loaded(let content) = state,
            !isRefreshing,
            worksets[source]?.isLoadingMore != true,
            !loadTask.isRunning,
            let nextRequest = Self.nextPageRequest(after: content, base: baseRequest)
        else {
            return
        }
        startAppend(nextRequest, baseRequest: baseRequest)
    }

    public func retryLoadMore(_ source: FeedSource) {
        guard worksets[source]?.loadMoreError != nil else { return }
        loadMore(source)
    }

    public func search(_ criteria: VideoSearchCriteria) {
        let request = FeedRequest.search(
            VideoSearchRequest(criteria: criteria, page: 1)
        )
        guard criteria.isValid else {
            fail(request: request, error: .invalidRequest)
            return
        }
        if worksets[.search]?.request != request {
            worksets[.search] = FeedWorkset(request: request)
        }
        refresh(request)
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
        worksets = [:]
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
        worksets = [:]
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

    /// 分页 footer 投影；`request` 是该来源工作集的第一页请求。
    func pagination(for request: FeedRequest) -> FeedPaginationPresentation {
        guard let workset = workset(for: request),
            case .loaded(let content) = workset.state
        else {
            return .unavailable
        }
        switch (request, content) {
        case (.recommendation, .recommendation(let page)):
            return pagination(
                of: workset,
                hasMore: page.nextContinuation != nil && !page.videos.isEmpty,
                tailIdentity: page.videos.last.map {
                    "recommendation|\(page.continuation.freshIndex)|\($0.bvid)"
                }
            )
        case (.popular(let basePage, let pageSize), .popular(let page)):
            guard page.pageNumber >= basePage, page.pageSize == pageSize else {
                return .unavailable
            }
            return pagination(
                of: workset,
                hasMore: page.hasMore && !page.videos.isEmpty,
                tailIdentity: page.videos.last.map {
                    "popular|\(basePage)|\(pageSize)|\(page.pageNumber)|\($0.bvid)"
                }
            )
        case (.search(let searchRequest), .search(let loadedQuery, let page)):
            guard loadedQuery == searchRequest.criteria.query else { return .unavailable }
            return pagination(
                of: workset,
                hasMore: page.pageNumber < page.totalPages,
                tailIdentity: page.videos.last.map {
                    "\(searchRequest.criteria.identityComponent)|\(page.pageNumber)|\($0.bvid)"
                }
            )
        default:
            return .unavailable
        }
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
                successfulRefreshGenerations[request.source, default: 0] &+= 1
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

    /// 各来源只在"下一页请求怎样构造"上不同：推荐沿 continuation，热门与搜索按页码递增。
    private static func nextPageRequest(
        after content: FeedContent,
        base: FeedRequest
    ) -> FeedRequest? {
        switch (base, content) {
        case (.recommendation(.none), .recommendation(let page)):
            guard let nextContinuation = page.nextContinuation, !page.videos.isEmpty else {
                return nil
            }
            return .recommendation(continuation: nextContinuation)
        case (.popular(let basePage, let pageSize), .popular(let page)):
            guard page.pageNumber >= basePage,
                page.pageSize == pageSize,
                page.hasMore,
                !page.videos.isEmpty
            else { return nil }
            return .popular(page: page.pageNumber + 1, pageSize: pageSize)
        case (.search(let searchRequest), .search(let loadedQuery, let page)):
            guard searchRequest.page == 1,
                loadedQuery == searchRequest.criteria.query,
                page.pageNumber < page.totalPages
            else { return nil }
            return .search(
                VideoSearchRequest(
                    criteria: searchRequest.criteria,
                    page: page.pageNumber + 1
                )
            )
        default:
            return nil
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
            let appended = responsePage.videos.uniquedByBVID(after: loadedPage.videos, \.bvid)
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
            let appended = responsePage.videos.uniquedByBVID(after: loadedPage.videos, \.bvid)
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
            let appended = responsePage.videos.uniquedByBVID(after: loadedPage.videos, \.bvid)
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
                page.videos.uniquedByBVID(\.bvid)
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
            let videos = page.videos.uniquedByBVID(\.bvid)
            return .popular(
                PopularPage(
                    videos: videos,
                    pageNumber: page.pageNumber,
                    pageSize: page.pageSize,
                    hasMore: page.hasMore && !videos.isEmpty
                )
            )
        case .search(let query, let page):
            let videos = page.videos.uniquedByBVID(\.bvid)
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
        update(&worksets[request.source, default: FeedWorkset()])
    }

    private func workset(for request: FeedRequest) -> FeedWorkset? {
        guard let workset = worksets[request.source], workset.request == request else {
            return nil
        }
        return workset
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
