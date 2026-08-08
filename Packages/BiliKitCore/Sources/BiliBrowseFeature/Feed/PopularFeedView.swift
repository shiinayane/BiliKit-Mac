import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

public struct PopularFeedView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let model: GuestBrowseViewModel
    private let request: GuestFeedRequest
    @Binding private var scrollPosition: ScrollPosition
    private let onSelect: (String) -> Void

    public init(
        model: GuestBrowseViewModel,
        page: Int = 1,
        pageSize: Int = 50,
        scrollPosition: Binding<ScrollPosition>,
        onSelect: @escaping (String) -> Void
    ) {
        self.model = model
        request = .popular(page: page, pageSize: pageSize)
        _scrollPosition = scrollPosition
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
                .accessibilityIdentifier("feed.loading")
        case .loaded(.popular(let page)) where page.videos.isEmpty:
            ContentUnavailableView(
                "暂无热门视频",
                systemImage: "rectangle.stack",
                description: Text("稍后重试或检查网络连接。")
            )
            .accessibilityIdentifier("feed.empty")
        case .loaded(.popular(let page)):
            PopularGrid(
                model: model,
                page: page,
                scrollPosition: $scrollPosition,
                onSelect: onSelect
            )
        case .failed(request: .popular(_, _), let error):
            BrowseFailureView(
                title: error.guestTitle,
                message: error.guestMessage,
                retry: { model.retry(request) }
            )
            .accessibilityIdentifier("feed.failure")
        default:
            VideoCardGridSkeleton(loadingLabel: "正在切换到热门视频")
                .accessibilityIdentifier("feed.transitioning")
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
    @Binding var scrollPosition: ScrollPosition
    let onSelect: (String) -> Void
    let request: GuestFeedRequest

    init(
        model: GuestBrowseViewModel,
        page: PopularPage,
        scrollPosition: Binding<ScrollPosition>,
        onSelect: @escaping (String) -> Void
    ) {
        let request = GuestFeedRequest.popular(
            page: page.pageNumber,
            pageSize: page.pageSize
        )
        self.model = model
        self.page = page
        _scrollPosition = scrollPosition
        self.onSelect = onSelect
        self.request = request
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(
                    columns: VideoCardGridLayout.columns(
                        for: geometry.size.width
                    ),
                    alignment: .leading,
                    spacing: VideoCardGridLayout.verticalSpacing
                ) {
                    ForEach(page.videos) { video in
                        Button {
                            onSelect(video.bvid)
                        } label: {
                            GuestVideoCard(video: video)
                        }
                        .buttonStyle(VideoCardButtonStyle())
                        .focusable(false)
                        .accessibilityHint("播放视频")
                        .accessibilityIdentifier("feed.item.\(video.bvid)")
                    }
                }
                .padding(VideoCardGridLayout.contentPadding)
                .scrollTargetLayout()
            }
            .scrollPosition($scrollPosition)
            .accessibilityIdentifier("feed.grid")
            .refreshable {
                model.refreshPopular(
                    page: page.pageNumber,
                    pageSize: page.pageSize
                )
                await model.waitForCurrentTask()
            }
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
                .accessibilityIdentifier("feed.refresh-failure")
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
