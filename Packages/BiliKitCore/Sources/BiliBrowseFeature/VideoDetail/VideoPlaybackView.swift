import BiliApplication
import BiliUI
import SwiftUI

/// 把视频准备状态连接到弹幕的播放 identity 生命周期。
///
/// 详情上下文一旦可用就选择同一 BVID/CID；状态回到 idle/loading/failed 时 identity 变为
/// `nil`，由 `.task(id:)` 完整 reset 弹幕支线。原生字幕由 AVPlayerEngine 随媒体 load 拥有。
public struct VideoPlaybackView<PlayerContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        ScrollViewReader { proxy in
            ScrollView {
                detailSurfaceContent
                    .id(PlaybackDetailScrollAnchor.top)
                    .overlay(alignment: .topLeading) {
                        if currentContext != nil, isLoadingReplacement {
                            replacementLoadingOverlay
                                .frame(
                                    maxWidth: .infinity,
                                    maxHeight: .infinity,
                                    alignment: .topLeading
                                )
                                .background(.background)
                                .transition(.opacity)
                        }
                    }
            }
            .onChange(of: presentedBVID) { previousBVID, bvid in
                guard
                    PlaybackDetailScrollResetPolicy.shouldReset(
                        from: previousBVID,
                        to: bvid
                    )
                else { return }
                proxy.scrollTo(PlaybackDetailScrollAnchor.top, anchor: .top)
            }
            .overlay {
                replacementFailureOverlay
            }
        }
    }

    private var presentedBVID: String? {
        currentContext?.detail.bvid
    }

    private var isLoadingReplacement: Bool {
        if case .loading = model.state {
            return true
        }
        return false
    }

    @ViewBuilder
    private var detailSurfaceContent: some View {
        if let currentContext {
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
        } else {
            VideoDetailSkeleton(loadingLabel: initialLoadingLabel)
        }
    }

    private var initialLoadingLabel: String {
        if case .loadingPage = model.state {
            return "正在加载所选分 P"
        }
        return "正在加载视频详情"
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
                "选择一个视频",
                systemImage: "play.rectangle",
                description: Text("从热门或搜索结果中选择视频后，这里会显示详情与播放器。")
            )
        case .loading:
            EmptyView()
        case .loadingPage:
            EmptyView()
        case .failed(_, let failure), .failedPage(_, _, let failure):
            BrowseFailureView(
                title: failure.title,
                message: failure.message,
                retry: retryAction
            )
        case .preparingPlayback, .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var replacementLoadingOverlay: some View {
        VideoDetailSkeleton(loadingLabel: "正在加载所选视频")
    }

    @ViewBuilder
    private var replacementFailureOverlay: some View {
        if currentContext != nil {
            switch model.state {
            case .failed(_, let failure), .failedPage(_, _, let failure):
                BrowseFailureView(
                    title: failure.title,
                    message: failure.message,
                    retry: retryAction
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
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

    private func retryAction() {
        if case .failedPage = model.state {
            model.retry()
        } else {
            onRetry()
        }
    }
}

enum PlaybackDetailScrollAnchor: Hashable {
    case top
}

enum PlaybackDetailScrollResetPolicy {
    static func shouldReset(from previousBVID: String?, to bvid: String?) -> Bool {
        guard let previousBVID, let bvid else { return false }
        return previousBVID != bvid
    }
}
