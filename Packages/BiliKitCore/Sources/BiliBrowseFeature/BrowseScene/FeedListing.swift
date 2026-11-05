import BiliApplication
import BiliModels

/// 一个 Feed 来源已加载的累积条目与分页状态；分页游标是该来源的下一页请求。
///
/// 只把远端页适配为 `VideoListPage` 并校验响应属于所请求的页；去重、上限、无进展停止、回环与尾标由
/// `PagedVideoList` 负责，请求、Task 与工作集由 `BrowseViewModel` 拥有。三个来源都用 `.stop`：
/// 热门与搜索再请求没有新条目的下一页也不会更有进展；App 推荐的游标每批都前进，但一批全是已显示过的视频时停下，
/// 免得服务端持续返回重复内容时无休止地自动请求，用户刷新即从新的一批开始。
enum FeedListing: Sendable, Equatable {
    case recommendation(PagedVideoList<RecommendedVideo, FeedRequest>)
    case popular(PagedVideoList<PopularVideo, FeedRequest>)
    case search(query: String, PagedVideoList<SearchVideo, FeedRequest>)

    /// 首次加载或刷新成功的第一页。
    ///
    /// `previous` 是同一工作集刷新前的列表，沿用它让尾标计数单调递增。响应不属于该请求时返回 nil，
    /// 调用方按无效响应处理。
    init?(
        firstPage content: FeedContent,
        for request: FeedRequest,
        replacing previous: FeedListing?
    ) {
        var listing = previous ?? FeedListing(emptyFor: request)
        guard listing.merge(content, for: request, isFirstPage: true) else { return nil }
        self = listing
    }

    private init(emptyFor request: FeedRequest) {
        switch request {
        case .recommendation:
            self = .recommendation(PagedVideoList(stallPolicy: .stop))
        case .popular:
            self = .popular(PagedVideoList(stallPolicy: .stop))
        case .search(let searchRequest):
            self = .search(query: searchRequest.criteria.query, PagedVideoList(stallPolicy: .stop))
        }
    }

    /// 近尾分页与底部胶囊的投影：尾标只在仍可自动加载时给出。
    var pagination: FeedPaginationPresentation {
        switch self {
        case .recommendation(let list): FeedPaginationPresentation(list)
        case .popular(let list): FeedPaginationPresentation(list)
        case .search(_, let list): FeedPaginationPresentation(list)
        }
    }

    var isRefreshing: Bool {
        switch self {
        case .recommendation(let list): list.isRefreshing
        case .popular(let list): list.isRefreshing
        case .search(_, let list): list.isRefreshing
        }
    }

    /// 返回应请求的下一页；正在加载、原地刷新或已到底时为 nil。
    ///
    /// 失败后的重试也走这里，请求同一页。
    mutating func beginLoadMore() -> FeedRequest? {
        switch self {
        case .recommendation(var list):
            defer { self = .recommendation(list) }
            return list.beginLoadMore()
        case .popular(var list):
            defer { self = .popular(list) }
            return list.beginLoadMore()
        case .search(let query, var list):
            defer { self = .search(query: query, list) }
            return list.beginLoadMore()
        }
    }

    /// 并入 `request` 对应的下一页；响应不属于该请求或与已加载页不衔接时记为无效响应的加载失败。
    mutating func append(_ content: FeedContent, for request: FeedRequest) {
        if !merge(content, for: request, isFirstPage: false) {
            failLoadMore(.invalidResponse)
        }
    }

    mutating func failLoadMore(_ error: ContentApplicationError) {
        switch self {
        case .recommendation(var list):
            list.failLoadMore(error)
            self = .recommendation(list)
        case .popular(var list):
            list.failLoadMore(error)
            self = .popular(list)
        case .search(let query, var list):
            list.failLoadMore(error)
            self = .search(query: query, list)
        }
    }

    /// 取消进行中的加载更多与原地刷新，分页回到开始前的样子；路由停用、请求被外部中断或刷新失败时调用。
    mutating func cancelPendingWork() {
        switch self {
        case .recommendation(var list):
            list.cancelPendingWork()
            self = .recommendation(list)
        case .popular(var list):
            list.cancelPendingWork()
            self = .popular(list)
        case .search(let query, var list):
            list.cancelPendingWork()
            self = .search(query: query, list)
        }
    }

    mutating func beginRefresh() {
        switch self {
        case .recommendation(var list):
            list.beginRefresh()
            self = .recommendation(list)
        case .popular(var list):
            list.beginRefresh()
            self = .popular(list)
        case .search(let query, var list):
            list.beginRefresh()
            self = .search(query: query, list)
        }
    }

    /// 把属于 `request` 的一页并入：第一页整体替换，加载更多按 `PagedVideoList.apply` 的衔接规则追加。
    ///
    /// 响应不属于该请求或来源不符时不改动并返回 false。
    private mutating func merge(
        _ content: FeedContent,
        for request: FeedRequest,
        isFirstPage: Bool
    ) -> Bool {
        guard request.accepts(content) else { return false }
        let requested = isFirstPage ? nil : request
        switch (self, request, content) {
        case (.recommendation(var list), _, .recommendation(let page)):
            list.merge(page.videoPage, requested: requested, bvid: \.bvid)
            self = .recommendation(list)
        case (.popular(var list), _, .popular(let page)):
            list.merge(page.videoPage, requested: requested, bvid: \.bvid)
            self = .popular(list)
        case (.search(let query, var list), .search(let searchRequest), .search(_, let page)):
            list.merge(
                page.videoPage(criteria: searchRequest.criteria),
                requested: requested,
                bvid: \.bvid
            )
            self = .search(query: query, list)
        default:
            return false
        }
        return true
    }
}

extension FeedPaginationPresentation {
    fileprivate init<Item>(_ list: PagedVideoList<Item, FeedRequest>) {
        self.init(
            tailIdentity: list.tailIdentity,
            isLoadingMore: list.isLoadingMore,
            loadMoreError: list.loadMoreError
        )
    }
}

extension PagedVideoList where Cursor == FeedRequest {
    /// `requested` 为 nil 时是第一页（首次加载或刷新成功），否则是加载更多请求的那一页。
    fileprivate mutating func merge(
        _ page: VideoListPage<Item, FeedRequest>,
        requested: FeedRequest?,
        bvid: (Item) -> String
    ) {
        if let requested {
            apply(page, requested: requested, bvid: bvid)
        } else {
            replaceFirstPage(page, bvid: bvid)
        }
    }

    fileprivate mutating func cancelPendingWork() {
        cancelLoadMore(requiringManualContinue: false)
        restoreAfterFailedRefresh()
    }
}

extension FeedRequest {
    /// 响应属于这次请求；首次加载与加载更多共用。
    ///
    /// 推荐批次、热门页码与页大小、搜索关键词与页码都与请求一致，且搜索页码不超过总页数（第一页另要求结果数
    /// 非负，并允许“0 页且没有条目”的空结果）。请求的正是已加载页给出的下一页这一衔接由 `PagedVideoList.apply` 校验。
    fileprivate func accepts(_ content: FeedContent) -> Bool {
        switch (self, content) {
        case (.recommendation(let requestedContinuation), .recommendation(let page)):
            page.continuation == requestedContinuation
        case (.popular(let requestedPage, let requestedSize), .popular(let page)):
            page.pageNumber == requestedPage && page.pageSize == requestedSize
        case (.search(let request), .search(let responseQuery, let page)):
            responseQuery == request.criteria.query
                && page.pageNumber == request.page
                && page.pageSize == request.criteria.pageSize
                && (request.page > 1 || page.totalResults >= 0)
                && (page.totalPages >= page.pageNumber
                    || (request.page == 1 && page.totalPages == 0 && page.videos.isEmpty))
        default:
            false
        }
    }
}

extension RecommendationPage {
    /// 推荐沿续传游标翻页：API 客户端在本批有条目时取最后一条的 `idx` 作为下一批的游标。
    fileprivate var videoPage: VideoListPage<RecommendedVideo, FeedRequest> {
        VideoListPage(
            items: videos,
            nextCursor: nextContinuation.map { .recommendation(continuation: $0) }
        )
    }
}

extension PopularPage {
    /// 热门按页码翻页：还有更多时下一页请求是同页大小的下一页码。
    fileprivate var videoPage: VideoListPage<PopularVideo, FeedRequest> {
        VideoListPage(
            items: videos,
            nextCursor: hasMore ? .popular(page: pageNumber + 1, pageSize: pageSize) : nil
        )
    }
}

extension SearchPage {
    /// 搜索按页码翻页：未到总页数时下一页请求沿用同一搜索条件。
    fileprivate func videoPage(
        criteria: VideoSearchCriteria
    ) -> VideoListPage<SearchVideo, FeedRequest> {
        VideoListPage(
            items: videos,
            nextCursor: pageNumber < totalPages
                ? .search(VideoSearchRequest(criteria: criteria, page: pageNumber + 1))
                : nil
        )
    }
}
