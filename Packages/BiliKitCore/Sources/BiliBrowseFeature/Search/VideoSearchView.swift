import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

public struct VideoSearchView<LoadedContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let model: GuestBrowseViewModel
    private let submittedSearchQuery: String?
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

    public init(
        model: GuestBrowseViewModel,
        submittedSearchQuery: String?,
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
        onSelect: @escaping (String) -> Void
    ) {
        self.model = model
        self.submittedSearchQuery = submittedSearchQuery
        _scrollOffsetY = scrollOffsetY
        self.makeLoadedContent = makeLoadedContent
        self.onSelect = onSelect
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
        guard let submittedSearchQuery else { return .idle }
        let request = GuestFeedRequest.search(
            query: submittedSearchQuery,
            page: 1
        )
        switch model.presentation(for: request).state {
        case .idle, .loading:
            return .loading
        case .loaded(.search(_, let page)) where page.videos.isEmpty:
            return .empty
        case .loaded(.search(_, _)):
            return .content
        case .failed(request: .search(_, _), error: _):
            return .failure
        default:
            return .transitioning
        }
    }

    @ViewBuilder
    private var results: some View {
        if let submittedSearchQuery {
            let request = GuestFeedRequest.search(
                query: submittedSearchQuery,
                page: 1
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
            ContentUnavailableView.search(text: query)
        case .loaded(.search(let query, let page)):
            VStack(spacing: 0) {
                HStack {
                    Text("“\(query)”")
                    Spacer()
                    Text("约 \(page.totalResults.formatted()) 条结果")
                        .foregroundStyle(.secondary)
                    if presentation.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在刷新搜索结果")
                    } else {
                        Button {
                            model.search(query)
                        } label: {
                            Label("刷新搜索结果", systemImage: "arrow.clockwise")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityHint("从第 1 页重新加载当前搜索")
                    }
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                loadedResults(query: query, page: page)
            }
            .overlay(alignment: .top) {
                if let error = presentation.refreshError {
                    Text(error.guestMessage)
                        .font(.caption)
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                }
            }
        case .failed(request: .search(_, _), let error):
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
        query: String,
        page: SearchPage
    ) -> some View {
        let pagination = model.searchPagination(for: query)
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
        VStack(spacing: 0) {
            HStack {
                Text("“\(query)”")
                Spacer()
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quinary)
                    .frame(width: 96, height: 12)
                    .accessibilityHidden(true)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            VideoCardGridSkeleton(loadingLabel: "正在搜索“\(query)”")
        }
    }
}

extension GuestFeedRequest {
    fileprivate var searchQuery: String? {
        guard case .search(let query, _) = self else { return nil }
        return query
    }
}
