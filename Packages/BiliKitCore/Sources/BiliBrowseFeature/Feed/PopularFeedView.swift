import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

public struct PopularFeedView<LoadedContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let model: BrowseViewModel
    private let request: FeedRequest
    private let initialPage: Int
    private let pageSize: Int
    private let makeLoadedContent: (LoadedFeedContent<PopularVideo>) -> LoadedContent
    private let onSelect: (String) -> Void

    public init(
        model: BrowseViewModel,
        page: Int = 1,
        pageSize: Int = BrowseViewModel.popularPageSize,
        makeLoadedContent:
            @escaping (LoadedFeedContent<PopularVideo>) -> LoadedContent,
        onSelect: @escaping (String) -> Void
    ) {
        self.model = model
        request = .popular(page: page, pageSize: pageSize)
        initialPage = page
        self.pageSize = pageSize
        self.makeLoadedContent = makeLoadedContent
        self.onSelect = onSelect
    }

    public var body: some View {
        let presentation = model.presentation(for: request)
        ZStack {
            content(for: presentation)
                .transition(.opacity)
        }
        .animation(
            LoadingStateTransition.animation(reduceMotion: reduceMotion),
            value: visualPhase(for: presentation.state)
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refreshPopular(
                        page: initialPage,
                        pageSize: pageSize
                    )
                } label: {
                    Label(BrowseFeatureStrings.localized("刷新热门视频"), systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshDisabled(presentation))
            }
        }
    }

    @ViewBuilder
    private func content(for presentation: FeedPresentation) -> some View {
        switch presentation.state {
        case .idle, .loading:
            VideoCardGridSkeleton(loadingLabel: BrowseFeatureStrings.localized("正在加载热门视频"))
        case .loaded(.popular(let page)) where page.videos.isEmpty:
            emptyResults(presentation: presentation)
        case .loaded(.popular(let page)):
            loadedResults(page: page, presentation: presentation)
        case .failed(request: .popular(_, _), let error):
            BrowseFailureView(
                title: error.displayTitle,
                message: error.displayMessage,
                retry: { model.retry(request) }
            )
        default:
            VideoCardGridSkeleton(loadingLabel: BrowseFeatureStrings.localized("正在切换到热门视频"))
        }
    }

    private func emptyResults(
        presentation: FeedPresentation
    ) -> some View {
        ContentUnavailableView(
            BrowseFeatureStrings.localized("暂无热门视频"),
            systemImage: "rectangle.stack",
            description: Text(BrowseFeatureStrings.localized("稍后重试或检查网络连接。"))
        )
        .overlay(alignment: .top) {
            ZStack {
                refreshStatus(presentation)
            }
            .animation(
                LoadingStateTransition.animation(reduceMotion: reduceMotion),
                value: refreshVisualPhase(presentation)
            )
        }
    }

    private func loadedResults(
        page: PopularPage,
        presentation: FeedPresentation
    ) -> some View {
        let pagination = model.pagination(for: request)
        return makeLoadedContent(
            LoadedFeedContent(
                items: page.videos,
                canLoadMore: pagination.canLoadMore,
                tailIdentity: pagination.tailIdentity,
                isLoadingMore: pagination.isLoadingMore,
                loadMore: { model.loadMore(.popular) },
                select: onSelect
            )
        )
        .overlay(alignment: .top) {
            ZStack {
                refreshStatus(presentation)
            }
            .animation(
                LoadingStateTransition.animation(reduceMotion: reduceMotion),
                value: refreshVisualPhase(presentation)
            )
        }
        .overlay(alignment: .bottom) {
            if pagination.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityLabel(BrowseFeatureStrings.localized("正在加载更多热门视频"))
            } else if let error = pagination.loadMoreError {
                HStack(spacing: 8) {
                    Text(error.displayMessage)
                        .lineLimit(2)
                    Button(BrowseFeatureStrings.localized("重试")) {
                        model.retryLoadMore(.popular)
                    }
                }
                .font(.caption)
                .padding(8)
                .background(.regularMaterial, in: Capsule())
            }
        }
    }

    @ViewBuilder
    private func refreshStatus(
        _ presentation: FeedPresentation
    ) -> some View {
        if presentation.isRefreshing {
            ProgressView()
                .controlSize(.small)
                .padding(8)
                .background(.regularMaterial, in: Capsule())
                .accessibilityLabel(BrowseFeatureStrings.localized("正在刷新热门视频"))
                .transition(.opacity)
        } else if let error = presentation.refreshError {
            Text(error.displayMessage)
                .font(.caption)
                .padding(8)
                .background(.regularMaterial, in: Capsule())
                .transition(.opacity)
        }
    }

    private func isRefreshDisabled(
        _ presentation: FeedPresentation
    ) -> Bool {
        if presentation.isRefreshing { return true }
        if case .loading = presentation.state { return true }
        return false
    }

    private func refreshVisualPhase(
        _ presentation: FeedPresentation
    ) -> LoadingVisualPhase {
        if presentation.isRefreshing { return .loading }
        if presentation.refreshError != nil { return .failure }
        return .idle
    }

    private func visualPhase(for state: FeedState) -> LoadingVisualPhase {
        switch state {
        case .idle, .loading:
            .loading
        case .loaded(.popular(let page)) where page.videos.isEmpty:
            .empty
        case .loaded(.popular(_)):
            .content
        case .failed(request: .popular(_, _), error: _):
            .failure
        default:
            .transitioning
        }
    }
}
