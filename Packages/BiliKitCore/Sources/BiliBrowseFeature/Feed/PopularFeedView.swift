import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

public struct PopularFeedView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let model: GuestBrowseViewModel
    private let request: GuestFeedRequest
    @Binding private var scrollOffsetY: CGFloat
    private let makeLoadedContent:
        (
            [PopularVideo],
            Binding<CGFloat>,
            @escaping (String) -> Void
        ) -> AnyView
    private let onSelect: (String) -> Void

    public init(
        model: GuestBrowseViewModel,
        page: Int = 1,
        pageSize: Int = 50,
        scrollOffsetY: Binding<CGFloat>,
        makeLoadedContent:
            @escaping (
                [PopularVideo],
                Binding<CGFloat>,
                @escaping (String) -> Void
            ) -> AnyView,
        onSelect: @escaping (String) -> Void
    ) {
        self.model = model
        request = .popular(page: page, pageSize: pageSize)
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
    }

    @ViewBuilder
    private func content(for presentation: GuestFeedPresentation) -> some View {
        switch presentation.state {
        case .idle, .loading:
            VideoCardGridSkeleton(loadingLabel: "正在加载热门视频")
        case .loaded(.popular(let page)) where page.videos.isEmpty:
            ContentUnavailableView(
                "暂无热门视频",
                systemImage: "rectangle.stack",
                description: Text("稍后重试或检查网络连接。")
            )
        case .loaded(.popular(let page)):
            PopularGrid(
                model: model,
                page: page,
                scrollOffsetY: $scrollOffsetY,
                makeLoadedContent: makeLoadedContent,
                onSelect: onSelect
            )
        case .failed(request: .popular(_, _), let error):
            BrowseFailureView(
                title: error.guestTitle,
                message: error.guestMessage,
                retry: { model.retry(request) }
            )
        default:
            VideoCardGridSkeleton(loadingLabel: "正在切换到热门视频")
        }
    }

    private func visualPhase(for state: GuestFeedState) -> LoadingVisualPhase {
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

private struct PopularGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: GuestBrowseViewModel
    let page: PopularPage
    @Binding var scrollOffsetY: CGFloat
    let makeLoadedContent:
        (
            [PopularVideo],
            Binding<CGFloat>,
            @escaping (String) -> Void
        ) -> AnyView
    let onSelect: (String) -> Void
    let request: GuestFeedRequest

    init(
        model: GuestBrowseViewModel,
        page: PopularPage,
        scrollOffsetY: Binding<CGFloat>,
        makeLoadedContent:
            @escaping (
                [PopularVideo],
                Binding<CGFloat>,
                @escaping (String) -> Void
            ) -> AnyView,
        onSelect: @escaping (String) -> Void
    ) {
        let request = GuestFeedRequest.popular(
            page: page.pageNumber,
            pageSize: page.pageSize
        )
        self.model = model
        self.page = page
        _scrollOffsetY = scrollOffsetY
        self.makeLoadedContent = makeLoadedContent
        self.onSelect = onSelect
        self.request = request
    }

    var body: some View {
        makeLoadedContent(page.videos, $scrollOffsetY, onSelect)
            .overlay(alignment: .top) {
                ZStack {
                    refreshStatus
                }
                .animation(
                    LoadingStateTransition.animation(
                        reduceMotion: reduceMotion
                    ),
                    value: refreshVisualPhase
                )
            }
    }

    @ViewBuilder
    private var refreshStatus: some View {
        let presentation = model.presentation(for: request)
        if presentation.isRefreshing {
            ProgressView()
                .controlSize(.small)
                .padding(8)
                .background(.regularMaterial, in: Capsule())
                .accessibilityLabel("正在刷新热门视频")
                .transition(.opacity)
        } else if let error = presentation.refreshError {
            Text(error.guestMessage)
                .font(.caption)
                .padding(8)
                .background(.regularMaterial, in: Capsule())
                .transition(.opacity)
        }
    }

    private var refreshVisualPhase: LoadingVisualPhase {
        let presentation = model.presentation(for: request)
        if presentation.isRefreshing { return .loading }
        if presentation.refreshError != nil { return .failure }
        return .idle
    }
}
