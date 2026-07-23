import SwiftUI

public struct PopularFeedView: View {
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

    @ViewBuilder
    public var body: some View {
        switch model.state {
        case .idle, .loading(.popular(_, _)):
            ProgressView("正在加载热门视频…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("feed.loading")
        case let .loaded(.popular(page)) where page.videos.isEmpty:
            ContentUnavailableView(
                "暂无热门视频",
                systemImage: "rectangle.stack",
                description: Text("稍后重试或检查网络连接。")
            )
        case let .loaded(.popular(page)):
            GeometryReader { geometry in
                ScrollView {
                    LazyVGrid(
                        columns: GuestVideoGridLayout.columns(
                            for: geometry.size.width
                        ),
                        alignment: .leading,
                        spacing: GuestVideoGridLayout.verticalSpacing
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
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("feed.item.\(video.bvid)")
                        }
                    }
                    .padding(GuestVideoGridLayout.contentPadding)
                }
                .accessibilityIdentifier("feed.grid")
                .refreshable {
                    model.loadPopular(
                        page: page.pageNumber,
                        pageSize: page.pageSize
                    )
                    await model.waitForCurrentTask()
                }
            }
        case let .failed(request: .popular(_, _), error: error):
            BrowseFailureView(
                title: error.guestTitle,
                message: error.guestMessage,
                retry: model.retry
            )
            .accessibilityIdentifier("feed.failure")
        default:
            ProgressView("正在切换到热门视频…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
