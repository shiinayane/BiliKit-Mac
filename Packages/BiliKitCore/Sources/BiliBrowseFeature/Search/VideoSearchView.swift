import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

public struct VideoSearchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let model: GuestBrowseViewModel
    private let submittedSearchQuery: String?
    @Binding private var scrollPosition: ScrollPosition
    private let onSelect: (String) -> Void

    public init(
        model: GuestBrowseViewModel,
        submittedSearchQuery: String?,
        scrollPosition: Binding<ScrollPosition>,
        onSelect: @escaping (String) -> Void
    ) {
        self.model = model
        self.submittedSearchQuery = submittedSearchQuery
        _scrollPosition = scrollPosition
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
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                SearchResultsGrid(
                    model: model,
                    query: query,
                    page: page,
                    scrollPosition: $scrollPosition,
                    onSelect: onSelect
                )
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

private struct SearchResultsGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: GuestBrowseViewModel
    let query: String
    let page: SearchPage
    @Binding var scrollPosition: ScrollPosition
    let onSelect: (String) -> Void
    let request: GuestFeedRequest

    init(
        model: GuestBrowseViewModel,
        query: String,
        page: SearchPage,
        scrollPosition: Binding<ScrollPosition>,
        onSelect: @escaping (String) -> Void
    ) {
        let request = GuestFeedRequest.search(
            query: query,
            page: page.pageNumber
        )
        self.model = model
        self.query = query
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
                        .accessibilityHint("播放视频")
                    }
                }
                .padding(VideoCardGridLayout.contentPadding)
                .scrollTargetLayout()
            }
            .scrollPosition($scrollPosition)
            .refreshable {
                model.search(query, page: page.pageNumber)
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
                .accessibilityLabel("正在刷新搜索结果")
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
