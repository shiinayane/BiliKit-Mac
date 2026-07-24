import BiliUI
import SwiftUI

public struct VideoSearchView: View {
    private let model: GuestFeedViewModel
    private let selectedBVID: String?
    private let onSelect: (String) -> Void

    public init(
        model: GuestFeedViewModel,
        selectedBVID: String? = nil,
        onSelect: @escaping (String) -> Void
    ) {
        self.model = model
        self.selectedBVID = selectedBVID
        self.onSelect = onSelect
    }

    public var body: some View {
        results
    }

    @ViewBuilder
    private var results: some View {
        switch model.state {
        case let .loading(.search(query, _)):
            ProgressView("正在搜索“\(query)”…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("search.loading")
        case let .loaded(.search(query, page)) where page.videos.isEmpty:
            ContentUnavailableView.search(text: query)
                .accessibilityIdentifier("search.empty")
        case let .loaded(.search(query, page)):
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
                                    GuestVideoCard(
                                        video: video,
                                        isSelected: selectedBVID == video.bvid
                                    )
                                }
                                .buttonStyle(
                                    VideoCardButtonStyle(
                                        isSelected:
                                            selectedBVID == video.bvid
                                    )
                                )
                                .accessibilityHint("播放视频")
                                .accessibilityIdentifier(
                                    "search.item.\(video.bvid)"
                                )
                            }
                        }
                        .padding(VideoCardGridLayout.contentPadding)
                    }
                    .accessibilityIdentifier("search.grid")
                    .refreshable {
                        model.search(query, page: page.pageNumber)
                        await model.waitForCurrentTask()
                    }
                }
            }
            .accessibilityIdentifier("search.results")
        case let .failed(request: .search(_, _), error: error):
            BrowseFailureView(
                title: error.guestTitle,
                message: error.guestMessage,
                retry: model.retry
            )
            .accessibilityIdentifier("search.failure")
        default:
            ContentUnavailableView(
                "搜索视频",
                systemImage: "magnifyingglass",
                description: Text("输入关键词后按下 Return 或点击搜索。")
            )
            .accessibilityIdentifier("search.prompt")
        }
    }

}
