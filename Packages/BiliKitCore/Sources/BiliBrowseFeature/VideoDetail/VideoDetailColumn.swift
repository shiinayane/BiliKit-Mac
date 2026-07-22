import BiliApplication
import SwiftUI

struct VideoDetailColumn<PlayerContent: View>: View {
    let model: GuestVideoViewModel
    let subtitleModel: SubtitleViewModel
    let playerContent: () -> PlayerContent

    @ViewBuilder
    var body: some View {
        Group {
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
                    subtitleModel: subtitleModel,
                    playerContent: playerContent
                )
            case let .ready(context):
                GuestVideoDetailView(
                    context: context,
                    isPreparingPlayback: false,
                    subtitleModel: subtitleModel,
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
        .task(id: playbackIdentity) {
            guard let playbackIdentity else {
                subtitleModel.reset()
                return
            }
            subtitleModel.selectVideo(playbackIdentity)
            await subtitleModel.waitForCurrentTask()
        }
        .onDisappear {
            subtitleModel.reset()
        }
    }

    private var playbackIdentity: PlaybackItemIdentity? {
        switch model.state {
        case let .preparingPlayback(context), let .ready(context):
            PlaybackItemIdentity(
                bvid: context.detail.bvid,
                cid: context.selectedPage.cid
            )
        case .idle, .loading, .failed:
            nil
        }
    }
}
