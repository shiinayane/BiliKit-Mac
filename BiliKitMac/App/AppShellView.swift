import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import SwiftUI

/// 描述窗口的原生 NavigationSplitView/NavigationStack 外壳，并保留来源状态与滚动位置。
///
/// 系统返回通过 path Binding 回写 coordinator，使播放停止与视觉导航保持同一事实来源；
/// SwiftUI `body` 与普通样式 modifier 不承担资源生命周期。
struct AppShellView: View {
    @Environment(\.openURL) private var openURL
    let navigationCoordinator: AppNavigationCoordinator
    let browseModel: GuestBrowseViewModel
    let videoModel: GuestVideoViewModel
    let commentsModel: PlaybackCommentsViewModel?
    let danmakuModel: DanmakuControlsViewModel
    let authenticationModel: AuthenticationViewModel
    let historyModel: WatchHistoryViewModel
    let playerContent: AnyView
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentVideoLinkResolver: CommentVideoLinkResolver
    let commentLinkURLResolver: CommentLinkURLResolver
    let commentImagePipeline: NativeVideoImagePipeline
    @Binding var isAuthenticationPresented: Bool
    @Binding var searchFilterSelection: SearchFilterSelection
    let submittedSearchCriteria: VideoSearchCriteria?
    let onSubmitSearch: () -> Void
    let onSelectSearchOrder: (VideoSearchOrder) -> Void
    let onApplySearchFilters: (SearchFilterSelection) -> Void
    let onClearSearchFilters: () -> Void
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var homeScrollOffsetY: CGFloat = 0
    @State private var popularScrollOffsetY: CGFloat = 0
    @State private var searchScrollOffsetY: CGFloat = 0
    @State private var historyScrollOffsetY: CGFloat = 0
    @State private var homeScrollReset = NativeVideoGridScrollResetState()
    @State private var popularScrollReset = NativeVideoGridScrollResetState()
    @State private var searchScrollReset = NativeVideoGridScrollResetState()
    @State private var historyScrollReset = NativeVideoGridScrollResetState()
    @State private var commentImagePreview: NativeCommentImagePreviewRequest?

    var body: some View {
        @Bindable var navigationCoordinator = navigationCoordinator

        NavigationSplitView(columnVisibility: guardedColumnVisibility) {
            Group {
                if navigationCoordinator.currentPlaybackBVID != nil {
                    playbackSidebar
                } else {
                    AppNavigationSidebar(
                        selection: $navigationCoordinator.selectedTab,
                        accountState: authenticationModel.accountPresentationState,
                        onPresentAuthentication: {
                            isAuthenticationPresented = true
                        }
                    )
                }
            }
            .id(sidebarContextID)
            .navigationSplitViewColumnWidth(
                min: sidebarMinimumWidth,
                ideal: sidebarIdealWidth,
                max: sidebarMaximumWidth
            )
        } detail: {
            NavigationStack(path: guardedPlaybackPath) {
                selectedSourceRoot
                    .navigationDestination(
                        for: PlaybackDestination.self
                    ) { _ in
                        PlaybackDestinationView(
                            model: videoModel,
                            danmakuModel: danmakuModel,
                            playerContent: playerContent,
                            onRetry: navigationCoordinator.retryPlayback,
                            onSelectRelatedVideo:
                                navigationCoordinator.openPlayback
                        )
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarVisibility(
            isCommentImagePreviewPresented ? .hidden : .automatic,
            for: .windowToolbar
        )
        .frame(minWidth: 760, minHeight: 560)
        .overlay {
            if let commentImagePreview,
                commentImagePreview.bvid
                    == navigationCoordinator.currentPlaybackBVID
            {
                NativeCommentImagePreviewView(
                    request: commentImagePreview,
                    imagePipeline: commentImagePipeline,
                    resolveURL: commentAssetURLResolver,
                    onDismiss: {
                        dismissCommentImagePreview(restoringFocus: true)
                    }
                )
            }
        }
        .sheet(isPresented: $isAuthenticationPresented) {
            AuthenticationView(model: authenticationModel)
        }
        .onChange(of: submittedSearchCriteria) { previousCriteria, criteria in
            guard previousCriteria != criteria else { return }
            searchScrollOffsetY = 0
            searchScrollReset.request()
        }
        .onChange(of: browseModel.recommendationSuccessfulRefreshGeneration) {
            previousGeneration,
            generation in
            guard previousGeneration != generation else { return }
            homeScrollOffsetY = 0
            homeScrollReset.request()
        }
        .onChange(of: browseModel.popularSuccessfulRefreshGeneration) {
            previousGeneration,
            generation in
            guard previousGeneration != generation else { return }
            popularScrollOffsetY = 0
            popularScrollReset.request()
        }
        .onChange(of: browseModel.searchSuccessfulRefreshGeneration) {
            previousGeneration,
            generation in
            guard previousGeneration != generation else { return }
            searchScrollOffsetY = 0
            searchScrollReset.request()
        }
        .onChange(of: historyModel.successfulReloadGeneration) {
            previousGeneration,
            generation in
            guard previousGeneration != generation else { return }
            historyScrollOffsetY = 0
            historyScrollReset.request()
        }
        .onChange(of: historyAccountScope) { previousScope, scope in
            guard AccountSessionScope.isResolvedChange(from: previousScope, to: scope)
            else {
                return
            }
            homeScrollOffsetY = 0
            homeScrollReset.request()
            searchScrollOffsetY = 0
            searchScrollReset.request()
            historyScrollOffsetY = 0
            historyScrollReset.request()
        }
        .onChange(of: navigationCoordinator.currentPlaybackBVID) {
            previousBVID,
            currentBVID in
            guard previousBVID != currentBVID else { return }
            dismissCommentImagePreview(restoringFocus: false)
        }
    }

    private var sidebarContextID: String {
        navigationCoordinator.currentPlaybackBVID == nil
            ? "navigation"
            : "playback"
    }

    private var isCommentImagePreviewPresented: Bool {
        guard let commentImagePreview else { return false }
        return commentImagePreview.bvid
            == navigationCoordinator.currentPlaybackBVID
    }

    private var guardedColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { columnVisibility },
            set: { nextVisibility in
                guard !isCommentImagePreviewPresented else { return }
                columnVisibility = nextVisibility
            }
        )
    }

    private var guardedPlaybackPath: Binding<[PlaybackDestination]> {
        Binding(
            get: { navigationCoordinator.playbackPath },
            set: { path in
                guard !isCommentImagePreviewPresented else { return }
                navigationCoordinator.playbackPath = path
            }
        )
    }

    private var historyAccountScope: AccountSessionScope {
        authenticationModel.sessionScope
    }

    private var playbackSidebar: some View {
        NativePlaybackSidebarView(
            model: videoModel,
            commentsModel: commentsModel,
            commentAssetURLResolver: commentAssetURLResolver,
            commentImagePipeline: commentImagePipeline,
            onRetry: navigationCoordinator.retryPlayback,
            onSelectPlayback: { bvid, preferredCID in
                navigationCoordinator.openPlayback(
                    PlaybackSelectionIntent(
                        bvid: bvid,
                        preferredCID: preferredCID
                    )
                )
            },
            onOpenCommentLink: { target in
                if let bvid = commentVideoLinkResolver(target) {
                    navigationCoordinator.openPlayback(bvid)
                } else if let url = commentLinkURLResolver(target) {
                    openURL(url)
                }
            },
            onOpenCommentPictures: openCommentPictures
        )
        .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebarMinimumWidth: CGFloat {
        navigationCoordinator.currentPlaybackBVID == nil ? 300 : 440
    }

    private var sidebarIdealWidth: CGFloat {
        navigationCoordinator.currentPlaybackBVID == nil ? 320 : 440
    }

    private var sidebarMaximumWidth: CGFloat {
        navigationCoordinator.currentPlaybackBVID == nil ? 320 : 520
    }

    private func openCommentPictures(
        _ gallery: NativePlaybackCommentPictureGallery
    ) {
        guard let bvid = navigationCoordinator.currentPlaybackBVID,
            !gallery.references.isEmpty
        else { return }
        commentImagePreview = NativeCommentImagePreviewRequest(
            bvid: bvid,
            references: gallery.references,
            selectedIndex: gallery.selectedIndex,
            restoreFocus: gallery.restoreFocus
        )
    }

    private func dismissCommentImagePreview(restoringFocus: Bool) {
        guard let request = commentImagePreview else { return }
        commentImagePreview = nil
        guard restoringFocus else { return }
        Task { @MainActor in
            await Task.yield()
            request.restoreFocus()
        }
    }

    @ViewBuilder
    private var selectedSourceRoot: some View {
        switch navigationCoordinator.selectedTab {
        case .home:
            RecommendedTabRoot(
                model: browseModel,
                scrollOffsetY: $homeScrollOffsetY,
                scrollReset: $homeScrollReset,
                onSelect: navigationCoordinator.openPlayback
            )
        case .search:
            SearchTabRoot(
                filterSelection: $searchFilterSelection,
                model: browseModel,
                searchDraft: Binding(
                    get: { navigationCoordinator.searchDraft },
                    set: { navigationCoordinator.searchDraft = $0 }
                ),
                submittedSearchCriteria: submittedSearchCriteria,
                scrollOffsetY: $searchScrollOffsetY,
                scrollReset: $searchScrollReset,
                onSelect: navigationCoordinator.openPlayback,
                onSubmit: onSubmitSearch,
                onSelectOrder: onSelectSearchOrder,
                onApplyFilters: onApplySearchFilters,
                onClearFilters: onClearSearchFilters
            )
        case .popular:
            PopularTabRoot(
                model: browseModel,
                scrollOffsetY: $popularScrollOffsetY,
                scrollReset: $popularScrollReset,
                onSelect: navigationCoordinator.openPlayback
            )
        case .history:
            HistoryTabRoot(
                model: historyModel,
                accountState: authenticationModel.accountPresentationState,
                scrollOffsetY: $historyScrollOffsetY,
                scrollReset: $historyScrollReset,
                onSelect: navigationCoordinator.openPlayback,
                onPresentAuthentication: {
                    isAuthenticationPresented = true
                },
                onAuthenticationRequired: {
                    historyModel.reset()
                    authenticationModel.revalidate()
                }
            )
        }
    }
}

private struct PlaybackDestinationView: View {
    @State private var relatedImageOwner: NativeVideoImagePipelineOwner? =
        NativeVideoImagePipelineOwner()
    let model: GuestVideoViewModel
    let danmakuModel: DanmakuControlsViewModel
    let playerContent: AnyView
    let onRetry: () -> Void
    let onSelectRelatedVideo: (String) -> Void

    var body: some View {
        Group {
            if let relatedImageOwner {
                playbackDetail(imageOwner: relatedImageOwner)
            }
        }
        .onAppear {
            if relatedImageOwner == nil {
                relatedImageOwner = NativeVideoImagePipelineOwner()
            }
        }
        .onDisappear {
            relatedImageOwner?.shutdown()
            relatedImageOwner = nil
        }
        .navigationTitle("播放")
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    }

    private func playbackDetail(
        imageOwner: NativeVideoImagePipelineOwner
    ) -> some View {
        NativePlaybackDetailView(
            contentIdentity: model.presentedBVID
        ) {
            VideoPlaybackView(
                model: model,
                danmakuModel: danmakuModel,
                onRetry: onRetry,
                onSelectRelatedVideo: onSelectRelatedVideo,
                makeRelatedContent: {
                    contentIdentity,
                    presentations,
                    onSelect in
                    RelatedNativeShelfView(
                        contentIdentity: contentIdentity,
                        presentations: presentations,
                        imagePipeline: imageOwner.pipeline,
                        onSelect: onSelect
                    )
                }
            ) {
                playerContent
            }
        }
        .ignoresSafeArea(.container, edges: [.top, .horizontal])
    }
}
