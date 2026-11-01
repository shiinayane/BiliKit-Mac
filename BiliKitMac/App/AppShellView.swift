import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import BiliUI
import BiliVideoCollectionUI
import BiliVideoDetailFeature
import SwiftUI

/// 描述窗口的原生 NavigationSplitView/NavigationStack 外壳，并保留来源状态与滚动位置。
///
/// 系统返回通过 path Binding 回写 coordinator，使播放停止与视觉导航保持同一事实来源；
/// SwiftUI `body` 与普通样式 modifier 不承担资源生命周期。
struct AppShellView: View {
    @Environment(\.openURL) private var openURL
    let navigationCoordinator: AppNavigationCoordinator
    let sources: AppSources
    let browseModel: BrowseViewModel
    let videoModel: VideoViewModel
    let commentsModel: PlaybackCommentsViewModel
    let danmakuModel: DanmakuControlsViewModel
    let authenticationModel: AuthenticationViewModel
    let watchLaterModel: WatchLaterViewModel
    let watchLaterSession: WatchLaterSession
    let historyModel: WatchHistoryViewModel
    let favoriteFolderList: FavoriteFolderListModel
    let favoriteFolders: FavoriteFolderViewModel
    let trendingSearchModel: TrendingSearchViewModel
    let searchSession: VideoSearchSession
    let searchHistory: SearchHistoryStore
    let searchSuggestionSource: SearchSuggestionSource
    let playerContent: AnyView
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentLinkRouter: CommentLinkRouter
    let commentShortLinks: CommentShortLinkResolution
    /// 窗口的评论图片预览面板；换视频与退出播放时关闭，关窗时由窗口组装关闭。
    let commentImagePreview: NativeCommentImagePreviewPresenter
    let seekPlayback: @MainActor (_ bvid: String, _ seconds: Int) -> Void
    let imagePipeline: NativeVideoImagePipeline
    /// 窗口的账户写入：经环境交给各来源的卡片菜单，结果胶囊盖在主区底部。
    let accountWrites: AccountWriteCoordinator
    /// 播放页点赞、投币、收藏按钮的状态；窗口写入账户变化时交给它重读。
    let engagementModel: VideoEngagementModel
    @Binding var isAuthenticationPresented: Bool
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var gridScroll = SourceGridScrollStates()
    /// 侧栏「收藏夹」组是否展开；只在窗口内存里，默认展开。
    @State private var isFavoritesExpanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 侧栏只负责导航，播放时也不替换：播放页整页压在 detail 列里，UP 主空间在播放页右栏打开。
            AppNavigationSidebar(
                sections: sources.sections,
                selection: sidebarSelection,
                favoriteFolderList: favoriteFolderList,
                isFavoritesExpanded: $isFavoritesExpanded,
                accountScope: historyAccountScope,
                accountState: authenticationModel.accountPresentationState,
                imagePipeline: imagePipeline,
                onPresentAuthentication: {
                    isAuthenticationPresented = true
                }
            )
            .navigationSplitViewColumnWidth(
                min: Self.sidebarMinimumWidth,
                ideal: Self.sidebarIdealWidth,
                max: Self.sidebarMaximumWidth
            )
        } detail: {
            NavigationStack(path: Bindable(navigationCoordinator).playbackPath) {
                selectedSourceRoot
                    // 写入结果胶囊挂在各页上而不是整个栈外：在 NavigationSplitView 的 detail 列里，挂在
                    // NavigationStack 上的修饰符实际归根页面所有，压栈后随根页面移除，播放页上就看不到。播放页打开时
                    // 这里不显示（根页面万一仍挂着，读屏也不会把同一条结果通告两次），播放页自己挂一份。
                    .overlay(alignment: .bottom) {
                        if navigationCoordinator.currentPlaybackBVID == nil {
                            AccountWriteStatusOverlay(accountWrites: accountWrites)
                        }
                    }
                    .navigationDestination(
                        for: PlaybackDestination.self
                    ) { _ in
                        playbackPage
                            .overlay(alignment: .bottom) {
                                AccountWriteStatusOverlay(accountWrites: accountWrites)
                            }
                    }
            }
        }
        // 来源网格、相关推荐横排与它们的卡片菜单都在这棵树里；写入口只转发意图，门槛与请求在 `AccountWriteCoordinator`。
        .environment(\.videoCardAccountWriting, accountWriting)
        .environment(\.videoEngagementActions, engagementActions)
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
        .sheet(isPresented: $isAuthenticationPresented) {
            AuthenticationView(model: authenticationModel)
        }
        .sheet(item: favoritePicker) { picker in
            FavoritePickerView(
                model: picker,
                onCancel: accountWrites.dismissFavoritePicker,
                onRetry: accountWrites.retryFavoritePicker,
                onConfirm: accountWrites.confirmFavoritePicker
            )
        }
        .onChange(of: accountWrites.currentWritableAccount) {
            // 登出、换号、其他窗口换号待复核：属于旧账户的「收藏到…」面板立即关闭，播放页按新账户重读互动状态。
            accountWrites.writableAccountDidChange()
            engagementModel.present(videoModel.presentedContext?.detail)
        }
        .onChange(of: searchSession.submittedCriteria) { previousCriteria, criteria in
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
            // 账户变化会替换每个来源的内容（Browse 丢弃全部工作集，稍后再看、观看历史与收藏夹随账户重载），所有网格都
            // 回到顶部。
            for tab in AppTab.allCases {
                scrollToTop(tab)
            }
        }
        .onChange(of: navigationCoordinator.currentPlaybackBVID) {
            previousBVID,
            currentBVID in
            guard previousBVID != currentBVID else { return }
            commentImagePreview.playbackDidChange(to: currentBVID)
        }
    }

    /// 卡片菜单的账户写入口：门槛在菜单构造时求值，动作转给窗口的写入协调者。
    private var accountWriting: VideoCardAccountWriting {
        let accountWrites = accountWrites
        return VideoCardAccountWriting(
            isAvailable: { accountWrites.isWritable },
            addToWatchLater: { accountWrites.addToWatchLater(bvid: $0) },
            removeFromWatchLater: { accountWrites.removeFromWatchLater(bvid: $0) },
            chooseFavoriteFolders: { accountWrites.chooseFavoriteFolders(bvid: $0) },
            removeFromFavoriteFolder: { accountWrites.removeFromFavoriteFolder($0) },
            dislikeRecommendation: { accountWrites.dislikeRecommendation($0) },
            cancelRecommendationDislike: { accountWrites.cancelRecommendationDislike($0) }
        )
    }

    /// 播放页点赞、投币、收藏按钮的写入口：门槛在按钮求值时读取，动作转给窗口的写入协调者。
    private var engagementActions: VideoEngagementActions {
        let accountWrites = accountWrites
        return VideoEngagementActions(
            isAvailable: { accountWrites.isWritable },
            setLiked: { accountWrites.setLiked($0, bvid: $1) },
            addCoins: { accountWrites.addCoins($0, alsoLike: $1, bvid: $2) },
            chooseFavoriteFolders: { accountWrites.chooseFavoriteFolders(bvid: $0) }
        )
    }

    /// 「收藏到…」面板的呈现：面板由写入协调者持有，sheet 被系统关闭（例如关窗）时交回协调者。
    private var favoritePicker: Binding<FavoritePickerModel?> {
        let accountWrites = accountWrites
        return Binding(
            get: { accountWrites.favoritePicker },
            set: { picker in
                if picker == nil { accountWrites.dismissFavoritePicker() }
            }
        )
    }

    /// 侧栏的选择值：读写都经来源描述映射，选中的条目记在来源自己的模型里，侧栏重建后照样恢复高亮。
    private var sidebarSelection: Binding<AppSidebarSelection> {
        Binding(
            get: { sources.sidebarSelection(for: navigationCoordinator.selectedTab) },
            set: { sources.select($0, in: navigationCoordinator) }
        )
    }

    private var historyAccountScope: AccountSessionScope {
        authenticationModel.sessionScope
    }

    /// 各来源内容整体替换的代次（语义见 `AppSourceDescriptor.refreshGeneration`）；某来源前进时只把它自己的网格
    /// 滚回顶部。
    private var successfulRefreshGenerations: [AppTab: UInt64] {
        Dictionary(
            uniqueKeysWithValues: sources.ordered.map { ($0.id, $0.refreshGeneration()) }
        )
    }

    /// 某个来源网格的窗口级依赖：本视图持有的滚动位置与回顶请求，加上窗口图片管线。
    private func gridHost(_ tab: AppTab) -> NativeVideoGridHostContext {
        let scroll = $gridScroll[dynamicMember: \.[tab]]
        return NativeVideoGridHostContext(
            scrollOffsetY: scroll.offsetY,
            scrollReset: scroll.reset,
            imageLoader: imagePipeline
        )
    }

    /// 回顶只发 reset 请求：已挂载的网格立即滚到 0 并把位置同步回 offset binding，
    /// 未挂载的网格在下次挂载时消费同一请求。
    private func scrollToTop(_ tabs: AppTab...) {
        for tab in tabs {
            gridScroll[tab].reset.request()
        }
    }

    /// 播放页：视频区、视频下方的详情与评论、右栏（相关推荐，空间打开时盖在上面），分栏规则在 `PlaybackPageView`。
    private var playbackPage: some View {
        PlaybackPageView(isSideContextOpen: isContextLayerOpen) {
            PlaybackDestinationView(
                model: videoModel,
                danmakuModel: danmakuModel,
                engagementModel: engagementModel,
                playerContent: playerContent,
                onRetry: retryPlayback
            )
        } details: { isVisible in
            NativePlaybackDetailsView(
                model: videoModel,
                commentsModel: commentsModel,
                commentAssetURLResolver: commentAssetURLResolver,
                commentImagePipeline: imagePipeline,
                onRetry: retryPlayback,
                onSelectPlayback: navigationCoordinator.openPlayback(_:preferredCID:),
                onOpenCommentLink: { commentLinkOpener.open(commentLinkRouter($0)) },
                onOpenCommentPictures: openCommentPictures,
                onOpenUploaderSpace: { navigationCoordinator.openUploaderSpace(owner: $0) },
                isObscured: !isVisible
            )
        } side: { isVisible in
            // 右栏 = 底层相关推荐 + 可选的上下文层（UP 主空间）。上下文层打开时底层保留状态但真正隐藏；只给上下文层
            // 自己的插入／移除加动画，底层的 AppKit 列表不参与这次 transaction，否则布局变化也会被做成动画而跳动。
            ZStack {
                RelatedVideoColumn(
                    model: videoModel,
                    imagePipeline: imagePipeline,
                    onSelect: navigationCoordinator.openPlayback,
                    isObscured: !isVisible || isContextLayerOpen
                )
                .opacity(isContextLayerOpen ? 0 : 1)
                .allowsHitTesting(!isContextLayerOpen)
                .accessibilityHidden(isContextLayerOpen)

                ZStack { contextLayer }
                    .animation(
                        reduceMotion
                            ? nil
                            : .snappy(duration: UploaderSpaceGeometry.layerTransitionDuration),
                        value: isContextLayerOpen
                    )
            }
            .clipped()
        }
        // macOS 没有给压栈页面设底色的接口，页面本身透明：不带动画压栈时根页面已移除，透出的是窗口底；带动画压栈时
        // 来源页留在下面继续绘制，会透出来。所以自铺不透明窗口背景，并延伸到工具栏下方（见 ARCHITECTURE「播放页布局」）。
        // 工具栏背景不强制显示：它会取紧贴下方的视频画面，整条变黑；保持自动，只在右栏列表滚到下面时出现边缘效果。
        .background {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
        }
        .navigationTitle("播放")
    }

    private var isContextLayerOpen: Bool {
        navigationCoordinator.isContextLayerOpen
    }

    @ViewBuilder
    private var contextLayer: some View {
        if isContextLayerOpen {
            UploaderSpaceLayerView(
                model: navigationCoordinator.uploaderSpace,
                currentBVID: navigationCoordinator.currentPlaybackBVID,
                imagePipeline: imagePipeline,
                onSelect: navigationCoordinator.openPlaybackFromContextLayer,
                onLogin: { isAuthenticationPresented = true }
            )
            .transition(
                reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }

    /// 导航侧栏的宽度范围：播放页的分栏按 detail 列的宽高比决定，侧栏越窄播放页越容易分栏（见 `PlaybackPageGeometry`）。
    private static let sidebarMinimumWidth: CGFloat = 220
    private static let sidebarIdealWidth: CGFloat = 260
    private static let sidebarMaximumWidth: CGFloat = 320

    private var commentLinkOpener: CommentLinkOpener {
        CommentLinkOpener(
            navigationCoordinator: navigationCoordinator,
            videoModel: videoModel,
            shortLinks: commentShortLinks,
            seekPlayback: seekPlayback,
            openURL: { openURL($0) }
        )
    }

    /// 播放失败后的重试交给视频模型；不在失败状态（例如已被重置）时重新发出当前导航意图。
    private func retryPlayback() {
        guard !videoModel.retryIfFailed() else { return }
        navigationCoordinator.retryPlayback()
    }

    private func openCommentPictures(
        _ gallery: NativePlaybackCommentPictureGallery
    ) {
        guard let bvid = navigationCoordinator.currentPlaybackBVID,
            let request = NativeCommentImagePreviewRequest(bvid: bvid, gallery: gallery)
        else { return }
        commentImagePreview.present(request)
    }

    @ViewBuilder
    private var selectedSourceRoot: some View {
        switch navigationCoordinator.selectedTab {
        case .home:
            RecommendedTabRoot(
                title: sources[.home].title,
                model: browseModel,
                gridHost: gridHost(.home),
                onSelect: navigationCoordinator.openPlayback
            )
        case .search:
            SearchTabRoot(
                title: sources[.search].title,
                session: searchSession,
                model: browseModel,
                gridHost: gridHost(.search),
                imagePipeline: imagePipeline,
                trendingSearchModel: trendingSearchModel,
                searchHistory: searchHistory,
                searchSuggestionSource: searchSuggestionSource,
                onSelect: navigationCoordinator.openPlayback
            )
        case .popular:
            PopularTabRoot(
                title: sources[.popular].title,
                model: browseModel,
                gridHost: gridHost(.popular),
                onSelect: navigationCoordinator.openPlayback
            )
        case .watchLater:
            WatchLaterTabRoot(
                title: sources[.watchLater].title,
                model: watchLaterModel,
                session: watchLaterSession,
                accountState: authenticationModel.accountPresentationState,
                gridHost: gridHost(.watchLater),
                onSelect: navigationCoordinator.openPlayback,
                onPresentAuthentication: {
                    isAuthenticationPresented = true
                }
            )
        case .history:
            HistoryTabRoot(
                title: sources[.history].title,
                model: historyModel,
                accountState: authenticationModel.accountPresentationState,
                gridHost: gridHost(.history),
                onSelect: navigationCoordinator.openPlayback,
                onPresentAuthentication: {
                    isAuthenticationPresented = true
                }
            )
        case .favorites:
            FavoritesTabRoot(
                title: sources[.favorites].title,
                model: favoriteFolders,
                accountState: authenticationModel.accountPresentationState,
                gridHost: gridHost(.favorites),
                onSelect: navigationCoordinator.openPlayback,
                onPresentAuthentication: {
                    isAuthenticationPresented = true
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

/// 各来源独立的网格滚动状态；来源之间不共享可被互相覆盖的位置。
private struct SourceGridScrollStates {
    private var states: [AppTab: SourceGridScrollState] = [:]

    subscript(tab: AppTab) -> SourceGridScrollState {
        get { states[tab] ?? SourceGridScrollState() }
        set { states[tab] = newValue }
    }
}

/// 播放页的视频区：把窗口的播放器接进 Feature 的 `VideoPlaybackView`（骨架、失败与播放器）。
private struct PlaybackDestinationView: View {
    let model: VideoViewModel
    let danmakuModel: DanmakuControlsViewModel
    let engagementModel: VideoEngagementModel
    let playerContent: AnyView
    let onRetry: () -> Void

    var body: some View {
        VideoPlaybackView(
            model: model,
            danmakuModel: danmakuModel,
            engagementModel: engagementModel,
            onRetry: onRetry
        ) {
            playerContent
        }
    }
}

/// 写入结果胶囊的宿主：单独成一个 View，只有它读取协调者的结果，结果变化时不让整个外壳重新求值。
private struct AccountWriteStatusOverlay: View {
    let accountWrites: AccountWriteCoordinator

    var body: some View {
        AccountWriteStatusCapsule(
            report: accountWrites.report,
            sequence: accountWrites.reportSequence
        )
    }
}
