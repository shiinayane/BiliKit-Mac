import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import BiliUI
import BiliVideoCollectionUI
import BiliVideoDetailFeature
import SwiftUI

/// 描述窗口的原生 NavigationSplitView 外壳，并保留来源状态与滚动位置。
///
/// 右侧只渲染历史栈顶（`AppDetailColumn`），工具栏「返回｜回到来源根页」经 coordinator 改变历史，使播放停止与视觉导航
/// 保持同一事实来源；SwiftUI `body` 与普通样式 modifier 不承担资源生命周期。
struct AppShellView: View {
    @Environment(\.openURL) private var openURL
    let navigationCoordinator: AppNavigationCoordinator
    let sources: AppSources
    let browseModel: BrowseViewModel
    let videoModel: VideoViewModel
    let commentsModel: PlaybackCommentsViewModel
    let danmakuModel: DanmakuControlsViewModel
    /// 播放页的分段章节；呈现的分 P 由播放页选择，停止播放时由窗口组装 reset。
    let chapterModel: VideoChapterModel
    /// 播放页的「正在看」人数；与章节同样由播放页选择分 P、停止播放时由窗口组装 reset。
    let onlineViewerModel: VideoOnlineViewerModel
    let danmakuComposer: DanmakuComposerModel
    let commentWrite: PlaybackCommentWriteModel
    let authenticationModel: AuthenticationViewModel
    let watchLaterModel: WatchLaterViewModel
    let watchLaterSession: WatchLaterSession
    let historyModel: WatchHistoryViewModel
    let favoriteFolderList: FavoriteFolderListModel
    let favoriteFolders: FavoriteFolderViewModel
    let followGroupList: FollowGroupListModel
    let followSession: FollowListSession
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
    /// 各来源网格的保活，按 `AppTab` 留住；账户变化时由本视图丢弃，关窗由窗口组装丢弃。
    let gridRetainer: NativeVideoGridRetainer
    /// 右侧换页的转场；detail 列把自己登记为它的锚点。
    let pageTransitions: NavigationPageTransitions
    /// 窗口的账户写入：经环境交给各来源的卡片菜单，结果胶囊盖在主区底部。
    let accountWrites: AccountWriteCoordinator
    /// 播放页点赞、投币、收藏按钮的状态；窗口写入账户变化时交给它重读。
    let engagementModel: VideoEngagementModel
    @Binding var isAuthenticationPresented: Bool
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var gridScroll = SourceGridScrollStates()
    /// 整页空间页网格的滚动位置；换空间项、换排序或搜索时回顶。
    @State private var spaceGridScroll = SourceGridScrollState()
    /// 压栈搜索页的网格滚动位置与回顶请求，与侧栏「搜索」的分开。
    @State private var searchPageGridScroll = SourceGridScrollState()
    /// 侧栏「收藏夹」组是否展开；只在窗口内存里，默认展开。
    ///
    /// 放在这里而不是侧栏里：进入、退出播放时导航侧栏会重建。
    @State private var isFavoritesExpanded = true
    /// 侧栏「关注」组是否展开；同收藏夹组。
    @State private var isFollowsExpanded = true
    /// 播放页被浏览类页面盖住时播放侧栏随导航侧栏替换而拆除；这一格留住评论的阅读位置，返回同一播放项时恢复。
    @State private var playbackSidebarReadingPosition = NativePlaybackSidebarReadingPosition()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 侧栏 = 底层（导航或播放详情）+ 可选的上下文层（UP 主空间）。两层并列叠放，
            // 各自按安全区布局；上下文层打开时底层保留状态（关闭后评论位置还在），但不可见、
            // 不可点、对辅助功能隐藏。播放详情是 AppKit，另经 `isObscured` 设 `isHidden`：
            // 只设透明度与 hit testing 管不到 cursor rect 和 tracking area。
            ZStack {
                Group {
                    if navigationCoordinator.currentPlaybackBVID != nil {
                        playbackSidebar
                    } else {
                        AppNavigationSidebar(
                            sections: sources.sections,
                            selection: sidebarSelection,
                            favoriteFolderList: favoriteFolderList,
                            isFavoritesExpanded: $isFavoritesExpanded,
                            followGroupList: followGroupList,
                            isFollowsExpanded: $isFollowsExpanded,
                            // 点当前来源的行回到它的根页；已在根页时 `goHome` 不动作。
                            onReselect: navigationCoordinator.goHome,
                            accountScope: historyAccountScope,
                            accountState: authenticationModel.accountPresentationState,
                            imagePipeline: imagePipeline,
                            onPresentAuthentication: {
                                isAuthenticationPresented = true
                            }
                        )
                    }
                }
                .id(sidebarContextID)
                .opacity(isSidebarContextOpen ? 0 : 1)
                .allowsHitTesting(!isSidebarContextOpen)
                .accessibilityHidden(isSidebarContextOpen)

                // 进出动画由侧栏图层上的 `push` 转场负责（`NavigationPageTransitions.performSidebarContext`），
                // 这里不加 SwiftUI 动画。
                sidebarContextLayer
            }
            // 浏览与播放各自记住用户拖出的宽度；挂在 ZStack 上而不是随进出播放重建的 Group 里。
            .background(SidebarWidthRestorer(mode: sidebarColumnMode))
            .navigationSplitViewColumnWidth(
                min: sidebarColumnMode.minimumWidth,
                ideal: sidebarColumnMode.idealWidth,
                max: sidebarColumnMode.maximumWidth
            )
        } detail: {
            AppDetailColumn(
                navigationCoordinator: navigationCoordinator,
                accountWrites: accountWrites,
                pageTransitions: pageTransitions,
                rootTitle: sources[navigationCoordinator.selectedTab].title,
                root: { selectedSourceRoot },
                playback: { playbackDestination },
                space: { spacePage },
                search: { searchPage }
            )
        }
        // 来源网格、相关推荐横排与它们的卡片菜单都在这棵树里；写入口只转发意图，门槛与请求在 `AccountWriteCoordinator`。
        .environment(\.videoCardAccountWriting, accountWriting)
        .environment(\.videoEngagementActions, engagementActions)
        .environment(\.uploaderFollowingMenu, followingMenu)
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(
            \.appNavigation,
            AppNavigationMenuTarget(
                coordinator: navigationCoordinator,
                rootTitle: sources[navigationCoordinator.selectedTab].title,
                canNavigateBack: navigationCoordinator.canNavigateBack,
                canGoHome: navigationCoordinator.canGoBack
            )
        )
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
        .sheet(item: followGroupPicker) { picker in
            FollowGroupPickerView(
                model: picker,
                onCancel: accountWrites.dismissFollowGroupPicker,
                onRetry: accountWrites.retryFollowGroupPicker,
                onConfirm: accountWrites.confirmFollowGroupPicker
            )
        }
        .onChange(of: accountWrites.currentWritableAccount) {
            // 登出、换号、其他窗口换号待复核：属于旧账户的「收藏到…」与「设置分组…」面板立即关闭、关系存储丢弃上一账户的
            // 关系，播放页按新账户重读互动状态。
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
            // 账户变化会替换每个来源的内容（Browse 丢弃全部工作集，稍后再看、观看历史、关注与收藏夹随账户重载），所有网格都
            // 回到顶部；留住的网格还持有旧账户的卡片，一并丢弃。
            gridRetainer.discardAll()
            for tab in AppTab.allCases {
                scrollToTop(tab)
            }
        }
        .onChange(of: navigationCoordinator.liveSpaceEntryID) { _, entryID in
            // 挂在外壳上而不是空间页上：空间项总在换页的同一次更新里换掉，空间页那时还没挂上。新的一项不沿用上一项的
            // 滚动位置；空间页已关闭（占用它的那一项不在历史里了）时它的网格不会再挂回，不留在保活里。
            spaceGridScroll = SourceGridScrollState()
            if entryID == nil { gridRetainer.discard(key: Self.spaceGridRetentionKey) }
        }
        .onChange(of: navigationCoordinator.liveSearchEntryID) { _, entryID in
            // 同空间项：新的搜索项不沿用上一项的滚动位置，搜索页关闭时它的网格不留在保活里。
            searchPageGridScroll = SourceGridScrollState()
            if entryID == nil { gridRetainer.discard(key: Self.searchPageGridRetentionKey) }
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
            cancelRecommendationDislike: { accountWrites.cancelRecommendationDislike($0) },
            followSpecialState: { accountWrites.followRelations.specialState(of: $0) },
            setFollowSpecial: { accountWrites.setFollowSpecial($1, mid: $0) },
            chooseFollowGroups: { accountWrites.chooseFollowGroups(mid: $0) },
            unfollow: { accountWrites.unfollow(mid: $0) }
        )
    }

    /// 空间页头部与播放页侧栏「已关注」菜单的写入口：状态取窗口的关系存储，动作转给窗口的写入协调者。
    private var followingMenu: UploaderFollowingMenu {
        let accountWrites = accountWrites
        return UploaderFollowingMenu(
            isSpecial: { accountWrites.followRelations.specialState(of: $0) },
            isWritable: { accountWrites.isWritable },
            prefetch: { accountWrites.followRelations.prefetch($0) },
            setSpecial: { _ = accountWrites.setFollowSpecial($0, mid: $1) },
            chooseGroups: { accountWrites.chooseFollowGroups(mid: $0) }
        )
    }

    /// 播放页点赞、投币、收藏按钮与侧栏关注按钮的写入口：门槛在按钮求值时读取，动作转给窗口的写入协调者。
    private var engagementActions: VideoEngagementActions {
        let accountWrites = accountWrites
        return VideoEngagementActions(
            isAvailable: { accountWrites.isWritable },
            setLiked: { accountWrites.setLiked($0, bvid: $1) },
            addCoins: { accountWrites.addCoins($0, alsoLike: $1, bvid: $2) },
            chooseFavoriteFolders: { accountWrites.chooseFavoriteFolders(bvid: $0) },
            setFollowing: { accountWrites.setFollowing($0, bvid: $1) }
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

    /// 「设置分组…」面板的呈现：同「收藏到…」。
    private var followGroupPicker: Binding<FollowGroupPickerModel?> {
        let accountWrites = accountWrites
        return Binding(
            get: { accountWrites.followGroupPicker },
            set: { picker in
                if picker == nil { accountWrites.dismissFollowGroupPicker() }
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

    private var sidebarContextID: String {
        navigationCoordinator.currentPlaybackBVID == nil
            ? "navigation"
            : "playback"
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

    /// 整页空间页：内容归协调器的整页空间模型；网格保活按占用它的空间项区分，换项、换排序或搜索时回顶。
    private var spacePage: some View {
        let page = navigationCoordinator.uploaderSpacePage
        return UploaderSpacePageView(
            model: page,
            imagePipeline: imagePipeline,
            gridHost: NativeVideoGridHostContext(
                scrollOffsetY: $spaceGridScroll.offsetY,
                scrollReset: $spaceGridScroll.reset,
                imageLoader: imagePipeline,
                retention: NativeVideoGridRetention(
                    retainer: gridRetainer,
                    key: Self.spaceGridRetentionKey,
                    contentIdentity: navigationCoordinator.liveSpaceEntryID
                )
            ),
            follow: page.followButton(isWritable: accountWrites.isWritable),
            onToggleFollow: {
                accountWrites.setFollowing(!(page.viewerFollows ?? false), onSpacePage: page)
            },
            onUnfollow: { accountWrites.setFollowing(false, onSpacePage: page) },
            onSelect: navigationCoordinator.openPlayback
        )
        .historyPageBackground()
        .onChange(of: page.order) { spaceGridScroll.reset.request() }
        .onChange(of: page.searchKeyword) { spaceGridScroll.reset.request() }
        .onChange(of: page.owner == nil) { _, isClosed in
            if isClosed { navigationCoordinator.restoreTopPageIfClosed() }
        }
    }

    /// 压栈搜索页：与侧栏「搜索」是同一个 `SearchTabRoot`，会话与 Browse 模型取自协调器的那一份；网格保活按占用它的
    /// 搜索项区分，换项或换条件时回顶。
    ///
    /// 激活挂在页面上：被盖住时页面移除、任务取消，Browse 模型保留工作集（与侧栏来源被播放页盖住时一样）；回来时以同一
    /// 条件再激活不会重新请求。
    private var searchPage: some View {
        let page = navigationCoordinator.searchPage
        return SearchTabRoot(
            title: sources[.search].title,
            session: page.session,
            model: page.browseModel,
            gridHost: NativeVideoGridHostContext(
                scrollOffsetY: $searchPageGridScroll.offsetY,
                scrollReset: $searchPageGridScroll.reset,
                imageLoader: imagePipeline,
                retention: NativeVideoGridRetention(
                    retainer: gridRetainer,
                    key: Self.searchPageGridRetentionKey,
                    contentIdentity: navigationCoordinator.liveSearchEntryID
                )
            ),
            imagePipeline: imagePipeline,
            trendingSearchModel: trendingSearchModel,
            searchHistory: searchHistory,
            searchSuggestionSource: searchSuggestionSource,
            onSelect: navigationCoordinator.openPlayback
        )
        .historyPageBackground()
        .task(id: page.session.browseActivation) {
            await page.browseModel.activate(page.session.browseActivation)
        }
        // 换条件与同条件原地刷新成功都回顶，与侧栏「搜索」相同（侧栏经 `successfulRefreshGenerations`）。
        .onChange(of: page.session.submittedCriteria) { searchPageGridScroll.reset.request() }
        .onChange(of: page.browseModel.successfulRefreshGeneration(for: .search)) {
            searchPageGridScroll.reset.request()
        }
    }

    /// 压栈搜索页的网格在窗口保活里只占一个位置，规则同空间页。
    private static let searchPageGridRetentionKey = "searchPage"

    /// 整页空间页的网格在窗口保活里只占一个位置：内容身份是空间项，新的一项出现时旧的那份被替换，最多留一个；空间页
    /// 关闭时丢弃。
    private static let spaceGridRetentionKey = "uploaderSpacePage"

    /// 某个来源网格的窗口级依赖：本视图持有的滚动位置与回顶请求，加上窗口图片管线。
    private func gridHost(_ tab: AppTab) -> NativeVideoGridHostContext {
        let scroll = $gridScroll[dynamicMember: \.[tab]]
        return NativeVideoGridHostContext(
            scrollOffsetY: scroll.offsetY,
            scrollReset: scroll.reset,
            imageLoader: imagePipeline,
            retention: NativeVideoGridRetention(
                retainer: gridRetainer,
                key: tab,
                // 收藏夹按夹重建内容视图（换夹等同换来源），新夹不沿用旧夹的网格。
                contentIdentity: tab == .favorites ? favoriteFolders.selectedFolderID : nil
            )
        )
    }

    /// 回顶只发 reset 请求：已挂载的网格立即滚到 0 并把位置同步回 offset binding，
    /// 未挂载的网格在下次挂载时消费同一请求。
    private func scrollToTop(_ tabs: AppTab...) {
        for tab in tabs {
            gridScroll[tab].reset.request()
        }
    }

    /// 栈顶播放项的历史项标识；栈顶不是播放页时为 nil（侧栏拆除前的最后一次更新不会拿到盖上来的那一项）。
    private var playbackEntryID: UInt64? {
        guard navigationCoordinator.currentPlaybackIntent != nil else { return nil }
        return navigationCoordinator.history.last?.id
    }

    private var playbackSidebar: some View {
        NativePlaybackSidebarView(
            model: videoModel,
            engagementModel: engagementModel,
            commentsModel: commentsModel,
            commentWrite: commentWrite,
            commentAssetURLResolver: commentAssetURLResolver,
            commentImagePipeline: imagePipeline,
            onRetry: retryPlayback,
            onSelectPlayback: navigationCoordinator.openPlayback(_:preferredCID:),
            onOpenCommentLink: { commentLinkOpener.open(commentLinkRouter($0)) },
            onOpenCommentPictures: openCommentPictures,
            onOpenUploaderSpace: { navigationCoordinator.openUploaderSpace(owner: $0) },
            isObscured: isSidebarContextOpen,
            readingPosition: playbackSidebarReadingPosition,
            readingPositionPlacement: playbackEntryID
        )
        .ignoresSafeArea(.container, edges: .top)
    }

    private var playbackDestination: PlaybackDestinationView {
        PlaybackDestinationView(
            model: videoModel,
            danmakuModel: danmakuModel,
            chapterModel: chapterModel,
            onlineViewerModel: onlineViewerModel,
            danmakuComposer: danmakuComposer,
            engagementModel: engagementModel,
            playerContent: playerContent,
            imagePipeline: imagePipeline,
            onRetry: retryPlayback,
            onSelectRelatedVideo: navigationCoordinator.openPlayback(_:firstPageCIDHint:),
            onSelectPlayback: navigationCoordinator.openPlayback(_:preferredCID:),
            recentlyWatched: { navigationCoordinator.recentlyWatched },
            onSelectRecentlyWatched: navigationCoordinator.openPlayback,
            onSeek: seekPlayback
        )
    }

    private func openFullSpaceFromPreview() {
        guard let owner = navigationCoordinator.uploaderSpace.owner else { return }
        navigationCoordinator.openUploaderSpacePage(owner: owner)
    }

    private var isSidebarContextOpen: Bool {
        navigationCoordinator.isSidebarContextOpen
    }

    @ViewBuilder
    private var sidebarContextLayer: some View {
        if isSidebarContextOpen {
            UploaderSpaceSidebarView(
                model: navigationCoordinator.uploaderSpace,
                currentBVID: navigationCoordinator.currentPlaybackBVID,
                imagePipeline: imagePipeline,
                onSelect: navigationCoordinator.openPlaybackFromSidebarContext,
                onOpenFullSpace: openFullSpaceFromPreview,
                onClose: navigationCoordinator.dismissSidebarContext
            )
        }
    }

    // 浏览态与播放态共用一列：ideal 只在首次布局生效，切换状态时宽度被夹进新范围，
    // 因此进入播放时侧栏宽度等于播放态最小值；更宽由用户自行拖动。
    private var sidebarColumnMode: SidebarColumnMode {
        navigationCoordinator.currentPlaybackBVID == nil ? .browsing : .playback
    }

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
                onSelect: navigationCoordinator.openPlayback(_:firstPageCIDHint:)
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
                onSelect: navigationCoordinator.openPlayback(_:firstPageCIDHint:)
            )
        case .watchLater:
            WatchLaterTabRoot(
                title: sources[.watchLater].title,
                model: watchLaterModel,
                session: watchLaterSession,
                accountState: authenticationModel.accountPresentationState,
                gridHost: gridHost(.watchLater),
                onSelect: navigationCoordinator.openPlayback(_:firstPageCIDHint:),
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
                onSelect: navigationCoordinator.openPlayback(_:firstPageCIDHint:),
                onPresentAuthentication: {
                    isAuthenticationPresented = true
                }
            )
        case .follows:
            FollowsTabRoot(
                title: sources[.follows].title,
                session: followSession,
                groupList: followGroupList,
                accountState: authenticationModel.accountPresentationState,
                gridHost: gridHost(.follows),
                onSelect: navigationCoordinator.openUploaderSpacePage,
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

private struct PlaybackDestinationView: View {
    let model: VideoViewModel
    let danmakuModel: DanmakuControlsViewModel
    let chapterModel: VideoChapterModel
    let onlineViewerModel: VideoOnlineViewerModel
    let danmakuComposer: DanmakuComposerModel
    let engagementModel: VideoEngagementModel
    let playerContent: AnyView
    let imagePipeline: NativeVideoImagePipeline
    let onRetry: () -> Void
    let onSelectRelatedVideo: (String, Int64?) -> Void
    let onSelectPlayback: (String, Int64?) -> Void
    /// 在本视图的 body 里读，让「刚才看过」的变化只刷新播放页（见 ARCHITECTURE「播放页」对 detail 观察的要求）。
    let recentlyWatched: () -> [RecentlyWatchedVideo]
    let onSelectRecentlyWatched: (PlaybackSelectionIntent) -> Void
    let onSeek: @MainActor (String, Int) -> Void

    var body: some View {
        VideoPlaybackView(
            model: model,
            danmakuModel: danmakuModel,
            chapterModel: chapterModel,
            onlineViewerModel: onlineViewerModel,
            danmakuComposer: danmakuComposer,
            engagementModel: engagementModel,
            onRetry: onRetry,
            onSelectRelatedVideo: onSelectRelatedVideo,
            onSelectPlayback: onSelectPlayback,
            recentlyWatched: recentlyWatched(),
            onSelectRecentlyWatched: onSelectRecentlyWatched,
            relatedImageLoader: imagePipeline,
            onSeek: onSeek
        ) {
            playerContent
        }
        .historyPageBackground()
        .navigationTitle("播放")
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    }
}

extension View {
    /// 历史页（播放页、整页空间页）的不透明窗口底色，延伸到工具栏与侧栏下方。
    ///
    /// macOS 没有给页面设底色的接口，页面本身透明，所以自铺。换页转场让移动的历史页叠在不动的那一页上滑，也靠这层
    /// 不透明；新增历史页类型都要铺它（见 ARCHITECTURE「播放页布局」）。
    fileprivate func historyPageBackground() -> some View {
        background {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
        }
    }
}
