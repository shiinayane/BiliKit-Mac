import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 把视频准备状态连接到弹幕的播放 identity 生命周期。
///
/// 详情上下文一旦可用就选择同一 BVID/CID；状态回到 idle/loading/failed 时 identity 变为
/// `nil`，由 `.task(id:)` 完整 reset 弹幕支线。原生字幕由 AVPlayerEngine 随媒体 load 拥有。
/// 只负责播放页的视频区；相关推荐竖列与评论由 App 按 `PlaybackPageView` 分栏摆放。展示的详情变化时交给
/// `VideoEngagementModel` 重读互动状态（窗口账户变化由 App 另行交给它）。
public struct VideoPlaybackView<PlayerContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let model: VideoViewModel
    private let danmakuModel: DanmakuControlsViewModel
    private let engagementModel: VideoEngagementModel
    private let onRetry: () -> Void
    private let playerContent: () -> PlayerContent

    public init(
        model: VideoViewModel,
        danmakuModel: DanmakuControlsViewModel,
        engagementModel: VideoEngagementModel,
        onRetry: @escaping () -> Void,
        @ViewBuilder playerContent: @escaping () -> PlayerContent
    ) {
        self.model = model
        self.danmakuModel = danmakuModel
        self.engagementModel = engagementModel
        self.onRetry = onRetry
        self.playerContent = playerContent
    }

    @ViewBuilder
    public var body: some View {
        Group {
            if usesDetailSurface {
                detailSurface
            } else {
                emptyState
                    .transition(.opacity)
            }
        }
        .animation(
            LoadingStateTransition.animation(reduceMotion: reduceMotion),
            value: visualPhase
        )
        .task(id: playbackIdentity) {
            guard let playbackIdentity else {
                danmakuModel.reset()
                return
            }
            danmakuModel.selectVideo(playbackIdentity)
        }
        .onChange(of: currentContext?.detail, initial: true) { _, detail in
            engagementModel.present(detail)
        }
    }

    private var usesDetailSurface: Bool {
        if currentContext != nil {
            return true
        }

        switch model.state {
        case .loading, .loadingPage:
            return true
        case .idle, .preparingPlayback, .ready, .failed, .failedPage:
            return false
        }
    }

    private var detailSurface: some View {
        detailSurfaceContent
            .overlay {
                replacementFailureOverlay
            }
    }

    @ViewBuilder
    private var detailSurfaceContent: some View {
        if let currentContext {
            VideoDetailView(
                context: currentContext,
                danmakuModel: danmakuModel,
                engagementModel: engagementModel,
                playerContent: playerContent
            )
            .disabled(blocksRetainedContext)
            .allowsHitTesting(!blocksRetainedContext)
            .accessibilityHidden(blocksRetainedContext)
        } else {
            VideoDetailSkeleton(loadingLabel: initialLoadingLabel)
        }
    }

    private var initialLoadingLabel: String {
        if case .loadingPage = model.state {
            return VideoDetailFeatureStrings.localized("正在加载所选分 P")
        }
        return VideoDetailFeatureStrings.localized("正在加载视频详情")
    }

    private var currentContext: VideoContext? {
        model.presentedContext
    }

    private var blocksRetainedContext: Bool {
        model.blocksPresentedContext
    }

    private var visualPhase: LoadingVisualPhase {
        if currentContext != nil {
            switch model.state {
            case .loading:
                return .replacementLoading
            case .failed, .failedPage:
                return .failure
            case .idle, .loadingPage, .preparingPlayback, .ready:
                return .content
            }
        }

        switch model.state {
        case .idle:
            return .idle
        case .loading, .loadingPage:
            return .loading
        case .failed, .failedPage:
            return .failure
        case .preparingPlayback, .ready:
            return .content
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.state {
        case .idle:
            ContentUnavailableView(
                VideoDetailFeatureStrings.localized("选择一个视频"),
                systemImage: "play.rectangle",
                description: Text(
                    VideoDetailFeatureStrings.localized("从热门或搜索结果中选择视频后，这里会显示详情与播放器。")
                )
            )
        case .loading:
            EmptyView()
        case .loadingPage:
            EmptyView()
        case .failed(_, let failure), .failedPage(_, _, let failure):
            failureView(failure)
        case .preparingPlayback, .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var replacementFailureOverlay: some View {
        if currentContext != nil {
            switch model.state {
            case .failed(_, let failure), .failedPage(_, _, let failure):
                failureView(failure)
                    .frame(maxWidth: 420)
                    .padding(24)
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            case .idle, .loading, .loadingPage, .preparingPlayback, .ready:
                EmptyView()
            }
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

    private func failureView(_ failure: VideoLoadFailure) -> ContentFailureView {
        let retry: () -> Void = retryAction
        return ContentFailureView(
            title: failure.title,
            message: failure.message,
            retry: failure.isRetryable ? retry : nil
        )
    }

    private func retryAction() {
        if case .failedPage = model.state {
            model.retry()
        } else {
            onRetry()
        }
    }
}
