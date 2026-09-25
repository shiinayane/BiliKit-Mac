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
    let browseModel: BrowseViewModel
    let videoModel: VideoViewModel
    let commentsModel: PlaybackCommentsViewModel?
    let danmakuModel: DanmakuControlsViewModel
    let authenticationModel: AuthenticationViewModel
    let historyModel: WatchHistoryViewModel
    let playerContent: AnyView
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentVideoLinkResolver: CommentVideoLinkResolver
    let commentLinkURLResolver: CommentLinkURLResolver
    let imagePipeline: NativeVideoImagePipeline
    @Binding var isAuthenticationPresented: Bool
    @Binding var searchFilterSelection: SearchFilterSelection
    let submittedSearchCriteria: VideoSearchCriteria?
    let onSubmitSearch: () -> Void
    let onSelectSearchOrder: (VideoSearchOrder) -> Void
    let onApplySearchFilters: (SearchFilterSelection) -> Void
    let onClearSearchFilters: () -> Void
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var gridScroll = SourceGridScrollStates()
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
                            imagePipeline: imagePipeline,
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
                    imagePipeline: imagePipeline,
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
            scrollToTop(.search)
        }
        .onChange(of: successfulRefreshGenerations) { previousGenerations, generations in
            for (tab, generation) in generations where previousGenerations[tab] != generation {
                scrollToTop(tab)
            }
        }
        .onChange(of: historyAccountScope) { previousScope, scope in
            guard AccountSessionScope.isResolvedChange(from: previousScope, to: scope)
            else {
                return
            }
            scrollToTop(.home, .search, .history)
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

    /// 各来源最近一次刷新成功的代次；某来源前进时只把它自己的网格滚回顶部。
    private var successfulRefreshGenerations: [AppTab: UInt64] {
        [
            .home: browseModel.successfulRefreshGeneration(for: .recommendation),
            .popular: browseModel.successfulRefreshGeneration(for: .popular),
            .search: browseModel.successfulRefreshGeneration(for: .search),
            .history: historyModel.successfulReloadGeneration
        ]
    }

    private func gridScrollBinding(_ tab: AppTab) -> Binding<SourceGridScrollState> {
        $gridScroll[dynamicMember: \.[tab]]
    }

    /// 回顶只发 reset 请求：已挂载的网格立即滚到 0 并把位置同步回 offset binding，
    /// 未挂载的网格在下次挂载时消费同一请求。
    private func scrollToTop(_ tabs: AppTab...) {
        for tab in tabs {
            gridScroll[tab].reset.request()
        }
    }

    private var playbackSidebar: some View {
        NativePlaybackSidebarView(
            model: videoModel,
            commentsModel: commentsModel,
            commentAssetURLResolver: commentAssetURLResolver,
            commentImagePipeline: imagePipeline,
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
        navigationCoordinator.currentPlaybackBVID == nil ? 300 : 480
    }

    private var sidebarIdealWidth: CGFloat {
        navigationCoordinator.currentPlaybackBVID == nil ? 320 : 480
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
                scrollOffsetY: gridScrollBinding(.home).offsetY,
                scrollReset: gridScrollBinding(.home).reset,
                imagePipeline: imagePipeline,
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
                scrollOffsetY: gridScrollBinding(.search).offsetY,
                scrollReset: gridScrollBinding(.search).reset,
                imagePipeline: imagePipeline,
                onSelect: navigationCoordinator.openPlayback,
                onSubmit: onSubmitSearch,
                onSelectOrder: onSelectSearchOrder,
                onApplyFilters: onApplySearchFilters,
                onClearFilters: onClearSearchFilters
            )
        case .popular:
            PopularTabRoot(
                model: browseModel,
                scrollOffsetY: gridScrollBinding(.popular).offsetY,
                scrollReset: gridScrollBinding(.popular).reset,
                imagePipeline: imagePipeline,
                onSelect: navigationCoordinator.openPlayback
            )
        case .history:
            HistoryTabRoot(
                model: historyModel,
                accountState: authenticationModel.accountPresentationState,
                scrollOffsetY: gridScrollBinding(.history).offsetY,
                scrollReset: gridScrollBinding(.history).reset,
                imagePipeline: imagePipeline,
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

/// 单个来源网格的滚动位置与回顶请求。
private struct SourceGridScrollState {
    var offsetY: CGFloat = 0
    var reset = NativeVideoGridScrollResetState()
}

/// 四个来源各自独立的网格滚动状态；来源之间不共享可被互相覆盖的位置。
private struct SourceGridScrollStates {
    private var states: [AppTab: SourceGridScrollState] = [:]

    subscript(tab: AppTab) -> SourceGridScrollState {
        get { states[tab] ?? SourceGridScrollState() }
        set { states[tab] = newValue }
    }
}

private struct PlaybackDestinationView: View {
    let model: VideoViewModel
    let danmakuModel: DanmakuControlsViewModel
    let playerContent: AnyView
    let imagePipeline: NativeVideoImagePipeline
    let onRetry: () -> Void
    let onSelectRelatedVideo: (String) -> Void

    var body: some View {
        playbackDetail
            .navigationTitle("播放")
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    }

    private var playbackDetail: some View {
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
                        imagePipeline: imagePipeline,
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
