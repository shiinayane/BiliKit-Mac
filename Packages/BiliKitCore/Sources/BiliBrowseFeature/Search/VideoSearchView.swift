import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

public struct VideoSearchView<LoadedContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let model: GuestBrowseViewModel
    private let submittedSearchCriteria: VideoSearchCriteria?
    private let hasActiveFilters: Bool
    @Binding private var scrollOffsetY: CGFloat
    private let makeLoadedContent:
        (
            [SearchVideoCardPresentation],
            Binding<CGFloat>,
            Bool,
            String?,
            Bool,
            @escaping () -> Void,
            @escaping (String) -> Void
        ) -> LoadedContent
    private let onSelect: (String) -> Void
    private let onClearFilters: () -> Void

    public init(
        model: GuestBrowseViewModel,
        submittedSearchCriteria: VideoSearchCriteria?,
        hasActiveFilters: Bool,
        scrollOffsetY: Binding<CGFloat>,
        makeLoadedContent:
            @escaping (
                [SearchVideoCardPresentation],
                Binding<CGFloat>,
                Bool,
                String?,
                Bool,
                @escaping () -> Void,
                @escaping (String) -> Void
            ) -> LoadedContent,
        onSelect: @escaping (String) -> Void,
        onClearFilters: @escaping () -> Void
    ) {
        self.model = model
        self.submittedSearchCriteria = submittedSearchCriteria
        self.hasActiveFilters = hasActiveFilters
        _scrollOffsetY = scrollOffsetY
        self.makeLoadedContent = makeLoadedContent
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
        let request = GuestFeedRequest.search(
            VideoSearchRequest(criteria: submittedSearchCriteria, page: 1)
        )
        switch model.presentation(for: request).state {
        case .idle, .loading:
            return .loading
        case .loaded(.search(_, let page)) where page.videos.isEmpty:
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
            let request = GuestFeedRequest.search(
                VideoSearchRequest(criteria: submittedSearchCriteria, page: 1)
            )
            searchResults(for: request)
        } else {
            searchPrompt
        }
    }

    @ViewBuilder
    private func searchResults(for request: GuestFeedRequest) -> some View {
        let presentation = model.presentation(for: request)
        switch presentation.state {
        case .idle, .loading:
            let query = request.searchQuery ?? ""
            SearchResultsSkeleton(query: query)
        case .loaded(.search(let query, let page)) where page.videos.isEmpty:
            VStack(spacing: 12) {
                ContentUnavailableView.search(text: query)
                if hasActiveFilters {
                    Button("清除筛选", action: onClearFilters)
                }
            }
        case .loaded(.search(_, let page)):
            loadedResults(criteria: request.searchCriteria, page: page)
                .overlay(alignment: .top) {
                    if presentation.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                            .background(.regularMaterial, in: Capsule())
                            .accessibilityLabel("正在刷新搜索结果")
                    } else if let error = presentation.refreshError {
                        Text(error.guestMessage)
                            .font(.caption)
                            .padding(8)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
        case .failed(request: .search, let error):
            BrowseFailureView(
                title: error.guestTitle,
                message: error.guestMessage,
                retry: { model.retry(request) }
            )
        default:
            searchPrompt
        }
    }

    private func loadedResults(
        criteria: VideoSearchCriteria?,
        page: SearchPage
    ) -> some View {
        let pagination =
            criteria.map(model.searchPagination(for:))
            ?? SearchPaginationPresentation(
                canLoadMore: false,
                tailIdentity: nil,
                isLoadingMore: false,
                loadMoreError: nil
            )
        return makeLoadedContent(
            page.videos.map(SearchVideoCardPresentation.init),
            $scrollOffsetY,
            pagination.canLoadMore,
            pagination.tailIdentity,
            pagination.isLoadingMore,
            model.loadMoreSearch,
            onSelect
        )
        .overlay(alignment: .bottom) {
            if pagination.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityLabel("正在加载更多搜索结果")
            } else if let error = pagination.loadMoreError {
                HStack(spacing: 8) {
                    Text(error.guestMessage)
                        .lineLimit(2)
                    Button("重试") {
                        model.retrySearchLoadMore()
                    }
                }
                .font(.caption)
                .padding(8)
                .background(.regularMaterial, in: Capsule())
            }
        }
    }

    private var searchPrompt: some View {
        ContentUnavailableView(
            "搜索视频",
            systemImage: "magnifyingglass",
            description: Text("输入关键词后按下 Return 或点击搜索。")
        )
    }
}

private struct SearchResultsSkeleton: View {
    let query: String

    var body: some View {
        VideoCardGridSkeleton(loadingLabel: "正在搜索“\(query)”")
    }
}

extension GuestFeedRequest {
    fileprivate var searchQuery: String? {
        searchCriteria?.query
    }

    fileprivate var searchCriteria: VideoSearchCriteria? {
        guard case .search(let request) = self else { return nil }
        return request.criteria
    }
}
