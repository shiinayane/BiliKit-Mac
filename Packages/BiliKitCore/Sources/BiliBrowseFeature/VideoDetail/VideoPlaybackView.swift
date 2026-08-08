import BiliApplication
import SwiftUI

/// 把视频准备状态连接到弹幕的播放 identity 生命周期。
///
/// 详情上下文一旦可用就选择同一 BVID/CID；状态回到 idle/loading/failed 时 identity 变为
/// `nil`，由 `.task(id:)` 完整 reset 弹幕支线。原生字幕由 AVPlayerEngine 随媒体 load 拥有。
public struct VideoPlaybackView<PlayerContent: View>: View {
    private let model: GuestVideoViewModel
    private let danmakuModel: DanmakuControlsViewModel
    private let onRetry: () -> Void
    private let onSelectRelatedVideo: (String) -> Void
    private let playerContent: () -> PlayerContent

    public init(
        model: GuestVideoViewModel,
        danmakuModel: DanmakuControlsViewModel,
        onRetry: @escaping () -> Void,
        onSelectRelatedVideo: @escaping (String) -> Void = { _ in },
        @ViewBuilder playerContent: @escaping () -> PlayerContent
    ) {
        self.model = model
        self.danmakuModel = danmakuModel
        self.onRetry = onRetry
        self.onSelectRelatedVideo = onSelectRelatedVideo
        self.playerContent = playerContent
    }

    @ViewBuilder
    public var body: some View {
        Group {
            if let currentContext {
                ZStack {
                    GuestVideoDetailView(
                        context: currentContext,
                        isPreparingPlayback: showsPlaybackActivity,
                        danmakuModel: danmakuModel,
                        relatedVideoState: model.relatedVideoState,
                        onSelectRelatedVideo: onSelectRelatedVideo,
                        onRetryRelatedVideos: model.retryRelatedVideos,
                        playerContent: playerContent
                    )
                    .disabled(blocksRetainedContext)
                    .allowsHitTesting(!blocksRetainedContext)
                    .accessibilityHidden(blocksRetainedContext)

                    retainedContextOverlay
                }
            } else {
                emptyState
            }
        }
        .task(id: playbackIdentity) {
            guard let playbackIdentity else {
                danmakuModel.reset()
                return
            }
            danmakuModel.selectVideo(playbackIdentity)
        }
    }

    private var currentContext: GuestVideoContext? {
        model.presentedContext
    }

    private var showsPlaybackActivity: Bool {
        switch model.state {
        case .loadingPage, .preparingPlayback:
            true
        case .idle, .loading, .ready, .failed, .failedPage:
            false
        }
    }

    private var blocksRetainedContext: Bool {
        switch model.state {
        case .loading, .failed, .failedPage:
            true
        case .idle, .loadingPage, .preparingPlayback, .ready:
            false
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.state {
        case .idle:
            ContentUnavailableView(
                "选择一个视频",
                systemImage: "play.rectangle",
                description: Text("从热门或搜索结果中选择视频后，这里会显示详情与播放器。")
            )
            .accessibilityIdentifier("detail.empty")
        case .loading:
            VideoDetailSkeleton(loadingLabel: "正在加载视频详情")
                .accessibilityIdentifier("playback.loading")
        case .loadingPage:
            VideoDetailSkeleton(loadingLabel: "正在加载所选分 P")
                .accessibilityIdentifier("playback.loading")
        case .failed(_, let failure), .failedPage(_, _, let failure):
            BrowseFailureView(
                title: failure.title,
                message: failure.message,
                retry: retryAction
            )
            .accessibilityIdentifier("playback.failure")
        case .preparingPlayback, .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var retainedContextOverlay: some View {
        switch model.state {
        case .loading:
            VideoDetailSkeleton(loadingLabel: "正在加载所选视频")
                .accessibilityIdentifier("playback.replacement.loading")
        case .loadingPage:
            EmptyView()
        case .failed(_, let failure), .failedPage(_, _, let failure):
            BrowseFailureView(
                title: failure.title,
                message: failure.message,
                retry: retryAction
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .accessibilityIdentifier("playback.replacement.failure")
        case .idle, .preparingPlayback, .ready:
            EmptyView()
        }
    }

    private var playbackIdentity: PlaybackItemIdentity? {
        switch model.state {
        case .preparingPlayback(let context), .ready(let context):
            PlaybackItemIdentity(
                bvid: context.detail.bvid,
                cid: context.selectedPage.cid
            )
        case .idle, .loading, .loadingPage, .failed, .failedPage:
            nil
        }
    }

    private func retryAction() {
        if case .failedPage = model.state {
            model.retry()
        } else {
            onRetry()
        }
    }
}
