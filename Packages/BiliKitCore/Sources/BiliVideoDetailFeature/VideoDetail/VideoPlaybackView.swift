import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 把视频准备状态连接到弹幕、分段章节与「正在看」人数的播放 identity 生命周期。
///
/// 详情上下文一旦可用就为同一 BVID/CID 选择弹幕、章节与人数；状态回到 idle/loading/failed 时 identity 变为
/// `nil`，由 `.task(id:)` 完整 reset 这三者。原生字幕由 AVPlayerEngine 随媒体 load 拥有。
/// 下方横排（相关视频、刚才看过、章节、合集）由本 Feature 直接渲染，App 只注入窗口图片管线（经卡片取图 port）、「刚才看过」
/// 列表、选择与跳转回调。展示的详情变化时交给
/// `VideoEngagementModel` 重读互动状态（窗口账户变化由 App 另行交给它）。
public struct VideoPlaybackView<PlayerContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let model: VideoViewModel
    private let danmakuModel: DanmakuControlsViewModel
    private let chapterModel: VideoChapterModel
    private let onlineViewerModel: VideoOnlineViewerModel
    private let danmakuComposer: DanmakuComposerModel?
    private let engagementModel: VideoEngagementModel
    private let onRetry: () -> Void
    /// 选中一条相关推荐：BV 号与相关推荐给的第一个分 P 的 CID（没有时为 nil），后者交给播放页提前请求播放清单。
    private let onSelectRelatedVideo: (String, Int64?) -> Void
    private let onSelectPlayback: (String, Int64?) -> Void
    private let recentlyWatched: [RecentlyWatchedVideo]
    private let onSelectRecentlyWatched: (PlaybackSelectionIntent) -> Void
    private let relatedImageLoader: any NativeVideoImageLoading
    /// 在播放器里跳到当前视频的某一秒（「章节」分页）；参数是 BV 号与秒数，播放器 item 不属于该视频时由实现忽略。
    private let onSeek: @MainActor (String, Int) -> Void
    private let playerContent: () -> PlayerContent

    public init(
        model: VideoViewModel,
        danmakuModel: DanmakuControlsViewModel,
        chapterModel: VideoChapterModel,
        onlineViewerModel: VideoOnlineViewerModel,
        danmakuComposer: DanmakuComposerModel? = nil,
        engagementModel: VideoEngagementModel,
        onRetry: @escaping () -> Void,
        onSelectRelatedVideo: @escaping (String, Int64?) -> Void = { _, _ in },
        onSelectPlayback: @escaping (String, Int64?) -> Void = { _, _ in },
        recentlyWatched: [RecentlyWatchedVideo] = [],
        onSelectRecentlyWatched: @escaping (PlaybackSelectionIntent) -> Void = { _ in },
        relatedImageLoader: any NativeVideoImageLoading,
        onSeek: @escaping @MainActor (String, Int) -> Void = { _, _ in },
        @ViewBuilder playerContent: @escaping () -> PlayerContent
    ) {
        self.model = model
        self.danmakuModel = danmakuModel
        self.chapterModel = chapterModel
        self.onlineViewerModel = onlineViewerModel
        self.danmakuComposer = danmakuComposer
        self.engagementModel = engagementModel
        self.onRetry = onRetry
        self.onSelectRelatedVideo = onSelectRelatedVideo
        self.onSelectPlayback = onSelectPlayback
        self.recentlyWatched = recentlyWatched
        self.onSelectRecentlyWatched = onSelectRecentlyWatched
        self.relatedImageLoader = relatedImageLoader
        self.onSeek = onSeek
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
            // 换视频或分 P 时收起弹幕输入胶囊：草稿是对着上一个视频写的，不能回车发到这一个上。
            danmakuComposer?.dismiss()
            guard let playbackIdentity else {
                danmakuModel.reset()
                chapterModel.reset()
                onlineViewerModel.reset()
                return
            }
            danmakuModel.selectVideo(playbackIdentity)
            chapterModel.select(playbackIdentity)
            onlineViewerModel.select(playbackIdentity)
        }
        .onChange(of: currentContext?.detail, initial: true) { _, detail in
            engagementModel.present(detail)
        }
        .onDisappear {
            danmakuComposer?.dismiss()
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

    private func chapterShelfInput(_ context: VideoContext) -> ChapterShelfInput? {
        let identity = PlaybackItemIdentity(
            bvid: context.detail.bvid,
            cid: context.selectedPage.cid
        )
        guard let list = chapterModel.chapters, list.identity == identity, !list.chapters.isEmpty
        else { return nil }
        let onSeek = onSeek
        return ChapterShelfInput(
            list: list,
            model: chapterModel,
            onSeek: { onSeek(identity.bvid, $0) }
        )
    }

    private func collectionShelfInput(_ context: VideoContext) -> PlaybackSelectionProjection? {
        let projection = model.selectionProjection(for: context)
        return projection.showsCollection ? projection : nil
    }

    private func selectRelatedVideo(_ bvid: String) {
        guard case .loaded(_, let videos) = model.relatedVideoState else {
            onSelectRelatedVideo(bvid, nil)
            return
        }
        onSelectRelatedVideo(bvid, videos.first(where: { $0.bvid == bvid })?.firstPageCID)
    }

    private func selectCollectionEpisode(_ identity: VideoCollectionEpisodeIdentity) {
        let onSelectPlayback = onSelectPlayback
        guard let episode = model.presentedCollectionEpisode(identity) else { return }
        model.selectCollectionEpisode(episode) { bvid, preferredCID in
            onSelectPlayback(bvid, preferredCID)
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
                accessNotice: model.playableVideo?.accessNotice,
                danmakuModel: danmakuModel,
                danmakuComposer: danmakuComposer,
                engagementModel: engagementModel,
                relatedVideoState: model.relatedVideoState,
                onSelectRelatedVideo: selectRelatedVideo,
                onRetryRelatedVideos: model.retryRelatedVideos,
                collectionShelf: collectionShelfInput(currentContext),
                chapterShelf: chapterShelfInput(currentContext),
                onlineViewerText: onlineViewerModel.text(
                    for: PlaybackItemIdentity(
                        bvid: currentContext.detail.bvid,
                        cid: currentContext.selectedPage.cid
                    )
                ),
                // 正在播放的排最前；「返回」回到列表里的视频时它不会从协调器的列表移出，这里去掉重复的那一项。
                recentlyWatched: [RecentlyWatchedVideo(nowPlaying: currentContext.detail)]
                    + recentlyWatched.filter { $0.id != currentContext.detail.bvid },
                isReplacingVideo: model.requestedSelectionBVID.map {
                    $0 != currentContext.detail.bvid
                } ?? false,
                onSelectRecentlyWatched: onSelectRecentlyWatched,
                onSelectCollectionEpisode: selectCollectionEpisode,
                relatedImageLoader: relatedImageLoader,
                blocksPlayerHitTesting: blocksRetainedContext,
                playerContent: playerContent
            )
            .disabled(blocksRetainedContext)
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
        let context: VideoContext
        switch model.state {
        case .preparingPlayback(let preparing):
            context = preparing
        case .ready(let playable):
            context = playable.context
        case .idle, .loading, .loadingPage, .failed, .failedPage:
            return nil
        }
        return PlaybackItemIdentity(
            bvid: context.detail.bvid,
            cid: context.selectedPage.cid
        )
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
