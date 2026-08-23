import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

public struct RecommendedFeedView<LoadedContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let model: GuestBrowseViewModel
    private let request = GuestFeedRequest.recommendation(continuation: nil)
    @Binding private var scrollOffsetY: CGFloat
    private let makeLoadedContent:
        (
            [RecommendedVideo],
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
        scrollOffsetY: Binding<CGFloat>,
        makeLoadedContent:
            @escaping (
                [RecommendedVideo],
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
        _scrollOffsetY = scrollOffsetY
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
                    model.refreshRecommendation()
                } label: {
                    Label(BrowseFeatureStrings.localized("刷新首页推荐"), systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshDisabled(presentation))
            }
        }
    }

    @ViewBuilder
    private func content(for presentation: GuestFeedPresentation) -> some View {
        switch presentation.state {
        case .idle, .loading:
            VideoCardGridSkeleton(loadingLabel: BrowseFeatureStrings.localized("正在加载首页推荐"))
        case .loaded(.recommendation(let page)) where page.videos.isEmpty:
            emptyResults(presentation: presentation)
        case .loaded(.recommendation(let page)):
            loadedResults(page: page, presentation: presentation)
        case .failed(request: .recommendation, let error):
            BrowseFailureView(
                title: error.guestTitle,
                message: error.guestMessage,
                retry: { model.retry(request) }
            )
        default:
            VideoCardGridSkeleton(loadingLabel: BrowseFeatureStrings.localized("正在切换到首页推荐"))
        }
    }

    private func emptyResults(
        presentation: GuestFeedPresentation
    ) -> some View {
        ContentUnavailableView(
            BrowseFeatureStrings.localized("暂无首页推荐"),
            systemImage: "house",
            description: Text(BrowseFeatureStrings.localized("稍后重试或检查网络连接。"))
        )
        .overlay(alignment: .top) {
            refreshStatus(presentation)
        }
    }

    private func loadedResults(
        page: RecommendationPage,
        presentation: GuestFeedPresentation
    ) -> some View {
        let pagination = model.recommendationPagination()
        return makeLoadedContent(
            page.videos,
            $scrollOffsetY,
            pagination.canLoadMore,
            pagination.tailIdentity,
            pagination.isLoadingMore,
            model.loadMoreRecommendations,
            onSelect
        )
        .overlay(alignment: .top) {
            refreshStatus(presentation)
        }
        .overlay(alignment: .bottom) {
            if pagination.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityLabel(BrowseFeatureStrings.localized("正在加载更多首页推荐"))
            } else if let error = pagination.loadMoreError {
                HStack(spacing: 8) {
                    Text(error.guestMessage)
                        .lineLimit(2)
                    Button(BrowseFeatureStrings.localized("重试")) {
                        model.retryRecommendationLoadMore()
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
        _ presentation: GuestFeedPresentation
    ) -> some View {
        if presentation.isRefreshing {
            ProgressView()
                .controlSize(.small)
                .padding(8)
                .background(.regularMaterial, in: Capsule())
                .accessibilityLabel(BrowseFeatureStrings.localized("正在刷新首页推荐"))
        } else if let error = presentation.refreshError {
            Text(error.guestMessage)
                .font(.caption)
                .padding(8)
                .background(.regularMaterial, in: Capsule())
        }
    }

    private func isRefreshDisabled(
        _ presentation: GuestFeedPresentation
    ) -> Bool {
        if presentation.isRefreshing { return true }
        if case .loading = presentation.state { return true }
        return false
    }

    private func visualPhase(for state: GuestFeedState) -> LoadingVisualPhase {
        switch state {
        case .idle, .loading:
            .loading
        case .loaded(.recommendation(let page)) where page.videos.isEmpty:
            .empty
        case .loaded(.recommendation):
            .content
        case .failed(request: .recommendation, error: _):
            .failure
        default:
            .transitioning
        }
    }
}
