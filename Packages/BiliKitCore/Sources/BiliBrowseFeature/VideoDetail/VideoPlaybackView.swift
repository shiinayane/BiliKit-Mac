import BiliApplication
import SwiftUI

/// 把视频准备状态连接到字幕与弹幕的播放 identity 生命周期。
///
/// 详情上下文一旦可用就选择同一 BVID/CID；状态回到 idle/loading/failed 时 identity 变为
/// `nil`，由 `.task(id:)` 完整 reset 两条支线。网络任务仍由各 ViewModel 自己拥有。
public struct VideoPlaybackView<PlayerContent: View>: View {
    private let model: GuestVideoViewModel
    private let subtitleModel: SubtitleViewModel
    private let danmakuModel: DanmakuControlsViewModel
    private let onRetry: () -> Void
    private let playerContent: () -> PlayerContent

    public init(
        model: GuestVideoViewModel,
        subtitleModel: SubtitleViewModel,
        danmakuModel: DanmakuControlsViewModel,
        onRetry: @escaping () -> Void,
        @ViewBuilder playerContent: @escaping () -> PlayerContent
    ) {
        self.model = model
        self.subtitleModel = subtitleModel
        self.danmakuModel = danmakuModel
        self.onRetry = onRetry
        self.playerContent = playerContent
    }

    @ViewBuilder
    public var body: some View {
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
            case .preparingPlayback(let context):
                GuestVideoDetailView(
                    context: context,
                    isPreparingPlayback: true,
                    subtitleModel: subtitleModel,
                    danmakuModel: danmakuModel,
                    playerContent: playerContent
                )
            case .ready(let context):
                GuestVideoDetailView(
                    context: context,
                    isPreparingPlayback: false,
                    subtitleModel: subtitleModel,
                    danmakuModel: danmakuModel,
                    playerContent: playerContent
                )
            case .failed(_, let failure):
                BrowseFailureView(
                    title: failure.title,
                    message: failure.message,
                    retry: onRetry
                )
            }
        }
        .task(id: playbackIdentity) {
            guard let playbackIdentity else {
                subtitleModel.reset()
                danmakuModel.reset()
                return
            }
            subtitleModel.selectVideo(playbackIdentity)
            danmakuModel.selectVideo(playbackIdentity)
        }
    }

    private var playbackIdentity: PlaybackItemIdentity? {
        switch model.state {
        case .preparingPlayback(let context), .ready(let context):
            PlaybackItemIdentity(
                bvid: context.detail.bvid,
                cid: context.selectedPage.cid
            )
        case .idle, .loading, .failed:
            nil
        }
    }
}
