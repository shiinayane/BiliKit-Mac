import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 搜索来源的主区：未提交搜索时显示起始页（本机搜索历史与 B 站热搜），提交后按 `BrowseViewModel` 的状态
/// 显示骨架、空结果、失败页或原生网格，叠加刷新与分页状态胶囊。
///
/// 拥有呈现与网格渲染；不拥有请求、分页与 generation（`BrowseViewModel`）、起始页的输入（App 经
/// `SearchStartPageContext` 给出）。滚动位置、回顶请求与图片管线属于 App 窗口，经 `NativeVideoGridHostContext`
/// 原样交给网格。草稿、筛选与提交在 `VideoSearchSession`，工具栏搜索框与筛选控件的宿主在 App。
public struct VideoSearchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    private let model: BrowseViewModel
    private let submittedSearchCriteria: VideoSearchCriteria?
    private let hasActiveFilters: Bool
    private let gridHost: NativeVideoGridHostContext
    private let startPageContext: SearchStartPageContext?
    private let onSelect: (String) -> Void
    private let onClearFilters: () -> Void

    /// `startPageContext` 为 nil 时起始页留空。
    public init(
        model: BrowseViewModel,
        submittedSearchCriteria: VideoSearchCriteria?,
        hasActiveFilters: Bool,
        gridHost: NativeVideoGridHostContext,
        startPageContext: SearchStartPageContext?,
        onSelect: @escaping (String) -> Void,
        onClearFilters: @escaping () -> Void
    ) {
        self.model = model
        self.submittedSearchCriteria = submittedSearchCriteria
        self.hasActiveFilters = hasActiveFilters
        self.gridHost = gridHost
        self.startPageContext = startPageContext
        self.onSelect = onSelect
        self.onClearFilters = onClearFilters
    }

    public var body: some View {
        ZStack {
            results
                .transition(.opacity)
        }
        .animation(
            LoadingStateTransition.animation(reduceMotion: reduceMotion),
            value: visualPhase
        )
    }

    private var visualPhase: LoadingVisualPhase {
        guard let submittedSearchCriteria else { return .idle }
        let request = FeedRequest.search(
            VideoSearchRequest(criteria: submittedSearchCriteria, page: 1)
        )
        switch model.presentation(for: request).state {
        case .idle, .loading:
            return .loading
        case .loaded(.search(_, let list)) where list.items.isEmpty:
            return .empty
        case .loaded(.search(_, _)):
            return .content
        case .failed(request: .search, error: _):
            return .failure
        default:
            return .transitioning
        }
    }

    @ViewBuilder
    private var results: some View {
        if let submittedSearchCriteria {
            let request = FeedRequest.search(
                VideoSearchRequest(criteria: submittedSearchCriteria, page: 1)
            )
            searchResults(for: request)
        } else {
            startPage
        }
    }

    @ViewBuilder
    private var startPage: some View {
        if let startPageContext {
            SearchStartView(context: startPageContext)
        }
    }

    @ViewBuilder
    private func searchResults(for request: FeedRequest) -> some View {
        let presentation = model.presentation(for: request)
        switch presentation.state {
        case .idle, .loading:
            let query = request.searchQuery ?? ""
            SearchResultsSkeleton(query: query)
        case .loaded(.search(let query, let list)) where list.items.isEmpty:
            VStack(spacing: 12) {
                ContentUnavailableView.search(text: query)
                if hasActiveFilters {
                    Button(
                        BrowseFeatureStrings.localized("清除筛选", locale: locale),
                        action: onClearFilters
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                refreshStatus(presentation)
            }
        case .loaded(.search(_, let list)):
            loadedResults(criteria: request.searchCriteria, videos: list.items)
                .overlay(alignment: .top) {
                    refreshStatus(presentation)
                }
        case .failed(request: .search, let error):
            BrowseFailureView(
                error: error,
                isAwaitingRevalidation: model.isAwaitingAuthenticationRevalidation,
                retry: { model.retry(request) }
            )
        default:
            startPage
        }
    }

    /// 同条件再次提交是原地刷新；结果为空时也要显示刷新中与刷新失败。
    private func refreshStatus(_ presentation: FeedPresentation) -> some View {
        RefreshStatusCapsule(
            isRefreshing: presentation.isRefreshing,
            refreshingLabel: BrowseFeatureStrings.localized(
                "正在刷新搜索结果",
                locale: locale
            ),
            errorMessage: presentation.refreshError.map {
                ContentFailureText.message(for: $0, locale: locale)
            }
        )
    }

    private func loadedResults(
        criteria: VideoSearchCriteria?,
        videos: [SearchVideo]
    ) -> some View {
        let pagination =
            criteria.map {
                model.pagination(for: .search(VideoSearchRequest(criteria: $0, page: 1)))
            } ?? .unavailable
        return SearchNativeGridView(
            content: LoadedFeedContent(
                items: videos.map { SearchVideoCardPresentation(video: $0) },
                tailState: pagination.gridTailState,
                loadMore: { model.loadMore(.search) },
                select: onSelect
            ),
            host: gridHost
        )
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) {
            PaginationStatusOverlay(
                pagination.overlayStatus(
                    loadingMoreLabel: BrowseFeatureStrings.localized("正在加载更多搜索结果", locale: locale),
                    locale: locale,
                    retry: { model.loadMore(.search) }
                )
            )
        }
    }
}

private struct SearchResultsSkeleton: View {
    let query: String

    var body: some View {
        VideoCardGridSkeleton(
            loadingLabel: BrowseFeatureStrings.localized("正在搜索“\(query)”")
        )
    }
}

extension FeedRequest {
    fileprivate var searchQuery: String? {
        searchCriteria?.query
    }

    fileprivate var searchCriteria: VideoSearchCriteria? {
        guard case .search(let request) = self else { return nil }
        return request.criteria
    }
}
