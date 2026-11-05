import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 热门来源的根视图：按 `BrowseViewModel` 的状态显示骨架、空页、失败页或原生网格，叠加刷新与分页状态
/// 胶囊，并在工具栏提供刷新。
///
/// 拥有呈现与网格渲染；不拥有请求、分页与 generation（`BrowseViewModel`），也不拥有滚动位置、回顶请求与
/// 图片管线——它们属于 App 窗口，经 `NativeVideoGridHostContext` 原样交给网格，App 据此在刷新与账户变化时
/// 让网格回到顶部。
public struct PopularFeedView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    private let model: BrowseViewModel
    private let request: FeedRequest
    private let initialPage: Int
    private let pageSize: Int
    private let gridHost: NativeVideoGridHostContext
    private let onSelect: (String) -> Void

    public init(
        model: BrowseViewModel,
        page: Int = 1,
        pageSize: Int = BrowseViewModel.popularPageSize,
        gridHost: NativeVideoGridHostContext,
        onSelect: @escaping (String) -> Void
    ) {
        self.model = model
        request = .popular(page: page, pageSize: pageSize)
        initialPage = page
        self.pageSize = pageSize
        self.gridHost = gridHost
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
        case .loaded(.popular(let list)) where list.items.isEmpty:
            emptyResults(presentation: presentation)
        case .loaded(.popular(let list)):
            loadedResults(videos: list.items, presentation: presentation)
        case .failed(request: .popular(_, _), let error):
            BrowseFailureView(
                error: error,
                isAwaitingRevalidation: model.isAwaitingAuthenticationRevalidation,
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
            refreshStatus(presentation)
        }
    }

    private func loadedResults(
        videos: [PopularVideo],
        presentation: FeedPresentation
    ) -> some View {
        let pagination = model.pagination(for: request)
        return PopularNativeGridView(
            content: LoadedFeedContent(
                items: videos,
                tailState: pagination.gridTailState,
                loadMore: { model.loadMore(.popular) },
                select: onSelect
            ),
            host: gridHost
        )
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) {
            refreshStatus(presentation)
        }
        .overlay(alignment: .bottom) {
            PaginationStatusOverlay(
                pagination.overlayStatus(
                    loadingMoreLabel: BrowseFeatureStrings.localized("正在加载更多热门视频", locale: locale),
                    locale: locale,
                    retry: { model.loadMore(.popular) }
                )
            )
        }
    }

    private func refreshStatus(
        _ presentation: FeedPresentation
    ) -> some View {
        RefreshStatusCapsule(
            isRefreshing: presentation.isRefreshing,
            refreshingLabel: BrowseFeatureStrings.localized("正在刷新热门视频"),
            errorMessage: presentation.refreshError.map {
                ContentFailureText.message(for: $0, locale: locale)
            }
        )
    }

    private func isRefreshDisabled(
        _ presentation: FeedPresentation
    ) -> Bool {
        if presentation.isRefreshing { return true }
        if case .loading = presentation.state { return true }
        return false
    }

    private func visualPhase(for state: FeedState) -> LoadingVisualPhase {
        switch state {
        case .idle, .loading:
            .loading
        case .loaded(.popular(let list)) where list.items.isEmpty:
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
