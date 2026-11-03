import BiliApplication
import BiliBrowseFeature
import BiliLibraryFeature
import Testing

@testable import BiliKit

/// 每个来源恰好一份描述，侧栏按固定的组顺序分段、组内按 case 顺序排列；只有稍后再看、观看历史与收藏夹要求账户，离开、
/// 换号与关窗的停用与清理经描述作用到来源的模型；侧栏选择值在来源与收藏夹行之间映射，登出时离开收藏夹回到首页。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppSourcesTests {
    @Test
    func everySourceHasOneDescriptorInSidebarOrder() {
        let sources = makeSources()

        #expect(Set(sources.ordered.map(\.id)) == Set(AppTab.allCases))
        #expect(sources.ordered.count == AppTab.allCases.count)
        for tab in AppTab.allCases {
            #expect(sources[tab].id == tab)
        }
        #expect(
            sources.ordered.filter(\.requiresAccount).map(\.id) == [
                .watchLater, .history, .favorites
            ]
        )
    }

    /// 顶部无标题的一组是搜索、首页、热门，带标题的「资料库」组依次是稍后再看、观看历史，最后是只在登录后显示的
    /// 「收藏夹」组；侧栏顺序就是各段依次展开。
    @Test
    func sidebarGroupsSourcesUnderFixedSections() {
        let sources = makeSources()

        #expect(sources.sections.map(\.group) == [.browse, .library, .favorites])
        #expect(
            sources.sections.map { $0.sources.map(\.id) } == [
                [.search, .home, .popular], [.watchLater, .history], [.favorites]
            ]
        )
        #expect(sources.ordered.map(\.id) == sources.sections.flatMap { $0.sources.map(\.id) })
        #expect(AppSourceGroup.browse.title == nil)
        #expect(AppSourceGroup.library.title != nil)
        #expect(AppSourceGroup.favorites.title != nil)
        #expect(
            AppSourceGroup.allCases.filter(\.isShownOnlyWhenSignedIn) == [.favorites]
        )
    }

    /// 单行来源的侧栏选择值就是来源本身，选中它即切换到该来源。
    @Test
    func singleRowSourcesSelectThemselves() {
        let sources = makeSources()
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: {},
            uploaderSpace: makeUploaderSpace()
        )

        for tab in AppTab.allCases where sources[tab].itemSelection == nil {
            sources.select(.source(tab), in: coordinator)

            #expect(coordinator.selectedTab == tab)
            #expect(sources.sidebarSelection(for: tab) == .source(tab))
        }
    }

    /// 每个收藏夹一行、带 ID 的选择值：选中一行切到收藏夹来源并记下收藏夹，夹之间切换不离开来源；离开后侧栏仍按记下的
    /// 收藏夹恢复高亮。
    @Test
    func favoriteFolderRowsMapToTheFavoritesSourceAndItsFolder() {
        let favorites = makeFavoriteModels()
        let sources = makeSources(favorites: favorites)
        let coordinator = AppNavigationCoordinator(
            startPlayback: { _ in },
            stopPlayback: {},
            uploaderSpace: makeUploaderSpace()
        )

        sources.select(.item(.favorites, id: 10), in: coordinator)
        #expect(coordinator.selectedTab == .favorites)
        #expect(favorites.folders.selectedFolderID == 10)
        #expect(sources.sidebarSelection(for: .favorites) == .item(.favorites, id: 10))

        sources.select(.item(.favorites, id: 20), in: coordinator)
        #expect(coordinator.selectedTab == .favorites)
        #expect(sources.sidebarSelection(for: coordinator.selectedTab) == .item(.favorites, id: 20))

        sources.select(.source(.home), in: coordinator)
        #expect(sources.sidebarSelection(for: coordinator.selectedTab) == .source(.home))
        #expect(sources.sidebarSelection(for: .favorites) == .item(.favorites, id: 20))
    }

    /// 「收藏夹」组只在登录后显示：在收藏夹时登出回到首页，换号仍留在收藏夹；其他来源不受影响。
    @Test(arguments: [
        (AppTab.favorites, AccountSessionScope.signedOut, AppTab.home),
        (.favorites, .unresolved, .home),
        (.favorites, .signedIn(accountID: 8), .favorites),
        (.favorites, .signedIn(accountID: nil), .favorites),
        (.watchLater, .signedOut, .watchLater),
        (.history, .signedOut, .history)
    ])
    func accountChangeLeavesSourcesWhoseGroupDisappears(
        from tab: AppTab,
        scope: AccountSessionScope,
        expected: AppTab
    ) {
        #expect(makeSources().route(afterAccountChangeFrom: tab, scope: scope) == expected)
    }

    /// 收藏夹的描述：夹内页面绑定来源，账户变化与关窗丢弃选择与列表。
    @Test
    func favoritesDescriptorFollowsItsModels() async {
        let favorites = makeFavoriteModels()
        let sources = makeSources(favorites: favorites)
        favorites.list.synchronize()
        await waitForObservedState {
            if case .loaded = favorites.list.state { return true }
            return false
        }
        favorites.folders.selectFolder(10)
        await favorites.folders.waitForCurrentTask()
        #expect(sources[.favorites].refreshGeneration() == 1)
        #expect(sources[.favorites].revalidationParticipant === favorites.folders)

        sources[.favorites].synchronizeAccountSession(
            AccountSessionChange(generation: 1, scope: .signedOut, isCurrentRoute: true)
        )
        #expect(favorites.folders.selectedFolderID == nil)

        sources.resetForWindowClosure()
        #expect(favorites.list.state == .idle)
    }

    @Test
    func historyDescriptorFollowsItsModel() async {
        let historyModel = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: WatchHistoryRepositoryStub())
        )
        let sources = makeSources(historyModel: historyModel)

        historyModel.loadIfNeeded()
        await historyModel.waitForCurrentTask()
        #expect(sources[.history].refreshGeneration() == 1)

        sources.resetAccountContent()
        #expect(historyModel.state == .idle)
    }

    /// 离开稍后再看或观看历史时，只把离开的那个来源的凭据类失败恢复为 idle。
    @Test(arguments: [AppTab.history, .watchLater])
    func leavingASourceReturnsItsCredentialFailureToIdle(source: AppTab) async {
        let historyModel = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(
                repository: WatchHistoryRepositoryStub(error: .authenticationRequired)
            )
        )
        let watchLaterModel = WatchLaterViewModel(
            useCase: WatchLaterUseCase(
                repository: WatchLaterRepositoryStub(error: .authenticationInvalid)
            )
        )
        let sources = makeSources(watchLaterModel: watchLaterModel, historyModel: historyModel)
        historyModel.loadIfNeeded()
        watchLaterModel.loadIfNeeded()
        await historyModel.waitForCurrentTask()
        await watchLaterModel.waitForCurrentTask()
        #expect(historyModel.state == .failed(.authenticationRequired))
        #expect(watchLaterModel.state == .failed(.authenticationInvalid))

        sources[source].deactivate()

        #expect((historyModel.state == .idle) == (source == .history))
        #expect((watchLaterModel.state == .idle) == (source == .watchLater))
    }

    /// 稍后再看的描述跟随它的模型：刷新代次就是模型的加载成功代次，换号前的清理与离开来源都作用到模型。
    @Test
    func watchLaterDescriptorFollowsItsModel() async {
        let watchLaterModel = WatchLaterViewModel(
            useCase: WatchLaterUseCase(repository: WatchLaterRepositoryStub())
        )
        let sources = makeSources(watchLaterModel: watchLaterModel)

        watchLaterModel.loadIfNeeded()
        await watchLaterModel.waitForCurrentTask()
        #expect(sources[.watchLater].refreshGeneration() == 1)
        #expect(sources[.watchLater].revalidationParticipant === watchLaterModel)

        sources.resetAccountContent()
        #expect(watchLaterModel.state == .idle)
    }

    /// 稍后再看的条件只在窗口内存里：关窗清理与账户变化都经描述把排序、筛选与关键词恢复默认。
    @Test
    func watchLaterDescriptorRestoresTheDefaultCriteria() async {
        let watchLaterModel = WatchLaterViewModel(
            useCase: WatchLaterUseCase(repository: WatchLaterRepositoryStub())
        )
        let session = WatchLaterSession(model: watchLaterModel)
        let browseModel = BrowseViewModel(useCase: FeedUseCase(repository: FeedRepositoryStub()))
        let favorites = makeFavoriteModels()
        let sources = AppSources(
            browseModel: browseModel,
            watchLaterModel: watchLaterModel,
            watchLaterSession: session,
            historyModel: WatchHistoryViewModel(
                useCase: WatchHistoryUseCase(repository: WatchHistoryRepositoryStub())
            ),
            favoriteFolderList: favorites.list,
            favoriteFolders: favorites.folders,
            searchSession: VideoSearchSession(browseModel: browseModel, recordHistory: { _ in }),
            trendingSearchModel: TrendingSearchViewModel(
                useCase: TrendingSearchUseCase(repository: EmptyTrendingSearchRepository())
            )
        )
        session.searchDraft = "猫"
        session.submitSearch()
        await watchLaterModel.waitForCurrentTask()
        #expect(session.narrowsResults)

        sources[.watchLater].synchronizeAccountSession(
            AccountSessionChange(generation: 1, scope: .signedOut, isCurrentRoute: true)
        )
        #expect(!session.narrowsResults)

        session.searchDraft = "狗"
        session.submitSearch()
        await watchLaterModel.waitForCurrentTask()
        sources.resetForWindowClosure()

        #expect(!session.narrowsResults)
        #expect(session.appliedKeyword.isEmpty)
        #expect(watchLaterModel.state == .idle)
    }

    /// 关窗时搜索来源清空草稿，撤回已提交的搜索。
    @Test
    func windowClosureClearsTheSearchSession() {
        let browseModel = BrowseViewModel(useCase: FeedUseCase(repository: FeedRepositoryStub()))
        let session = VideoSearchSession(browseModel: browseModel, recordHistory: { _ in })
        let watchLaterModel = WatchLaterViewModel(
            useCase: WatchLaterUseCase(repository: WatchLaterRepositoryStub())
        )
        let favorites = makeFavoriteModels()
        let sources = AppSources(
            browseModel: browseModel,
            watchLaterModel: watchLaterModel,
            watchLaterSession: WatchLaterSession(model: watchLaterModel),
            historyModel: WatchHistoryViewModel(
                useCase: WatchHistoryUseCase(repository: WatchHistoryRepositoryStub())
            ),
            favoriteFolderList: favorites.list,
            favoriteFolders: favorites.folders,
            searchSession: session,
            trendingSearchModel: TrendingSearchViewModel(
                useCase: TrendingSearchUseCase(repository: EmptyTrendingSearchRepository())
            )
        )
        session.search(keyword: "猫")

        sources.resetForWindowClosure()

        #expect(session.draft.isEmpty)
        #expect(session.submittedCriteria == nil)
    }

    /// 账户变化（本窗口换号或其他窗口换号）不动搜索草稿与已提交的搜索：搜索不要求账户，只有 Browse 工作集重启。
    @Test
    func accountChangeKeepsTheSearchDraft() {
        let browseModel = BrowseViewModel(useCase: FeedUseCase(repository: FeedRepositoryStub()))
        let session = VideoSearchSession(browseModel: browseModel, recordHistory: { _ in })
        let watchLaterModel = WatchLaterViewModel(
            useCase: WatchLaterUseCase(repository: WatchLaterRepositoryStub())
        )
        let favorites = makeFavoriteModels()
        let sources = AppSources(
            browseModel: browseModel,
            watchLaterModel: watchLaterModel,
            watchLaterSession: WatchLaterSession(model: watchLaterModel),
            historyModel: WatchHistoryViewModel(
                useCase: WatchHistoryUseCase(repository: WatchHistoryRepositoryStub())
            ),
            favoriteFolderList: favorites.list,
            favoriteFolders: favorites.folders,
            searchSession: session,
            trendingSearchModel: TrendingSearchViewModel(
                useCase: TrendingSearchUseCase(repository: EmptyTrendingSearchRepository())
            )
        )
        session.search(keyword: "猫")
        let submitted = session.submittedCriteria

        sources.resetAccountContent()
        for source in sources.ordered {
            source.synchronizeAccountSession(
                AccountSessionChange(
                    generation: 1,
                    scope: .signedIn(accountID: 2),
                    isCurrentRoute: source.id == .search
                )
            )
        }

        #expect(session.draft == "猫")
        #expect(session.submittedCriteria == submitted)
    }

    private func makeSources(
        watchLaterModel: WatchLaterViewModel = WatchLaterViewModel(
            useCase: WatchLaterUseCase(repository: WatchLaterRepositoryStub())
        ),
        historyModel: WatchHistoryViewModel = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: WatchHistoryRepositoryStub())
        ),
        favorites: (list: FavoriteFolderListModel, folders: FavoriteFolderViewModel) =
            makeFavoriteModels()
    ) -> AppSources {
        let browseModel = BrowseViewModel(useCase: FeedUseCase(repository: FeedRepositoryStub()))
        return AppSources(
            browseModel: browseModel,
            watchLaterModel: watchLaterModel,
            watchLaterSession: WatchLaterSession(model: watchLaterModel),
            historyModel: historyModel,
            favoriteFolderList: favorites.list,
            favoriteFolders: favorites.folders,
            searchSession: VideoSearchSession(browseModel: browseModel, recordHistory: { _ in }),
            trendingSearchModel: TrendingSearchViewModel(
                useCase: TrendingSearchUseCase(repository: EmptyTrendingSearchRepository())
            )
        )
    }
}

/// 已登录（mid 7）窗口的收藏夹列表与夹内模型，仓库是共享的空替身。
@MainActor
private func makeFavoriteModels(
    scope: AccountSessionScope = .signedIn(accountID: 7)
) -> (list: FavoriteFolderListModel, folders: FavoriteFolderViewModel) {
    let useCase = FavoritesUseCase(repository: FavoritesRepositoryStub())
    let list = FavoriteFolderListModel(useCase: useCase, accountScope: { scope })
    return (list, FavoriteFolderViewModel(useCase: useCase, folderList: list))
}
