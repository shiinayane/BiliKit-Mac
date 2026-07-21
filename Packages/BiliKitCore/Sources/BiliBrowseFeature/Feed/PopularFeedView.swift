import SwiftUI

struct PopularFeedView: View {
    let model: GuestFeedViewModel
    @Binding var selectedBVID: String?

    @ViewBuilder
    var body: some View {
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
            List(page.videos, selection: $selectedBVID) { video in
                GuestVideoRow(video: video)
                    .tag(video.bvid)
            }
            .listStyle(.inset)
            .accessibilityIdentifier("feed.list")
            .refreshable {
                model.loadPopular(
                    page: page.pageNumber,
                    pageSize: page.pageSize
                )
                await model.waitForCurrentTask()
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
