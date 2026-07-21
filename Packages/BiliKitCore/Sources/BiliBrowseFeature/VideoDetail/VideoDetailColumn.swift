import SwiftUI

struct VideoDetailColumn<PlayerContent: View>: View {
    let model: GuestVideoViewModel
    let playerContent: () -> PlayerContent

    @ViewBuilder
    var body: some View {
        switch model.state {
        case .idle:
            ContentUnavailableView(
                "选择一个视频",
                systemImage: "play.rectangle",
                description: Text("从热门或搜索结果中选择视频后，这里会显示详情与播放器。")
            )
            .accessibilityIdentifier("detail.empty")
        case .loading:
            ProgressView("正在加载视频详情…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .preparingPlayback(context):
            GuestVideoDetailView(
                context: context,
                isPreparingPlayback: true,
                playerContent: playerContent
            )
        case let .ready(context):
            GuestVideoDetailView(
                context: context,
                isPreparingPlayback: false,
                playerContent: playerContent
            )
        case let .failed(bvid, failure):
            BrowseFailureView(
                title: failure.title,
                message: failure.message,
                retry: { model.selectVideo(bvid) }
            )
        }
    }
}
