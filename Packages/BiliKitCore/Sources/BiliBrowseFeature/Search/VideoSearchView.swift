import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

public struct VideoSearchView<LoadedContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    private let model: BrowseViewModel
    private let submittedSearchCriteria: VideoSearchCriteria?
    private let hasActiveFilters: Bool
    private let makeLoadedContent: (LoadedFeedContent<SearchVideoCardPresentation>) -> LoadedContent
    private let onSelect: (String) -> Void
    private let onClearFilters: () -> Void

    public init(
        model: BrowseViewModel,
        submittedSearchCriteria: VideoSearchCriteria?,
        hasActiveFilters: Bool,
        makeLoadedContent:
            @escaping (LoadedFeedContent<SearchVideoCardPresentation>) -> LoadedContent,
        onSelect: @escaping (String) -> Void,
        onClearFilters: @escaping () -> Void
    ) {
        self.model = model
        self.submittedSearchCriteria = submittedSearchCriteria
        self.hasActiveFilters = hasActiveFilters
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
        let request = FeedRequest.search(
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
            let request = FeedRequest.search(
                VideoSearchRequest(criteria: submittedSearchCriteria, page: 1)
            )
            searchResults(for: request)
        } else {
            searchPrompt
        }
    }

    @ViewBuilder
    private func searchResults(for request: FeedRequest) -> some View {
        let presentation = model.presentation(for: request)
        switch presentation.state {
        case .idle, .loading:
            let query = request.searchQuery ?? ""
            SearchResultsSkeleton(query: query)
        case .loaded(.search(let query, let page)) where page.videos.isEmpty:
            VStack(spacing: 12) {
                ContentUnavailableView.search(text: query)
                if hasActiveFilters {
                    Button(
                        BrowseFeatureStrings.localized("清除筛选", locale: locale),
                        action: onClearFilters
                    )
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
                            .accessibilityLabel(
                                BrowseFeatureStrings.localized(
                                    "正在刷新搜索结果",
                                    locale: locale
                                )
                            )
                    } else if let error = presentation.refreshError {
                        Text(error.displayMessage)
                            .font(.caption)
                            .padding(8)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
        case .failed(request: .search, let error):
            BrowseFailureView(
                title: error.displayTitle,
                message: error.displayMessage,
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
        let pagination = criteria.map(model.searchPagination(for:)) ?? .unavailable
        return makeLoadedContent(
            LoadedFeedContent(
                items: page.videos.map { SearchVideoCardPresentation(video: $0, locale: locale) },
                canLoadMore: pagination.canLoadMore,
                tailIdentity: pagination.tailIdentity,
                isLoadingMore: pagination.isLoadingMore,
                loadMore: model.loadMoreSearch,
                select: onSelect
            )
        )
        .overlay(alignment: .bottom) {
            if pagination.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityLabel(
                        BrowseFeatureStrings.localized("正在加载更多搜索结果", locale: locale)
                    )
            } else if let error = pagination.loadMoreError {
                HStack(spacing: 8) {
                    Text(error.displayMessage)
                        .lineLimit(2)
                    Button(BrowseFeatureStrings.localized("重试", locale: locale)) {
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
            BrowseFeatureStrings.localized("搜索视频", locale: locale),
            systemImage: "magnifyingglass",
            description: Text(
                BrowseFeatureStrings.localized("输入关键词后按下 Return 或点击搜索。", locale: locale)
            )
        )
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
