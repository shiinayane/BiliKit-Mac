import BiliApplication
import BiliBrowseFeature
import BiliLibraryFeature
import Foundation

/// 侧栏把平级来源分成的组；case 的声明顺序就是组在侧栏里的顺序，组内按 `AppTab` 的声明顺序。
///
/// 每个来源在 `AppSources.init` 的穷尽 switch 里必须给出所属的组。组只决定侧栏怎样分段、是否带标题、是否可折叠与
/// 未登录时是否显示，不改变来源的停用、账户变化与清理语义。
enum AppSourceGroup: CaseIterable {
    /// 顶部不带标题的一组：搜索、首页、热门。
    case browse
    /// 「资料库」：只属于当前账户的个人列表（稍后再看、观看历史）。
    case library
    /// 「关注」：一个来源（关注）为「全部关注」与每个分组各提供一行，可折叠；只在已登录时显示。
    case follows
    /// 「收藏夹」：一个来源（收藏夹）为每个自己创建的收藏夹提供一行，可折叠；只在已登录时显示。
    case favorites

    /// 侧栏分段标题；nil 表示不显示标题。
    var title: LocalizedStringResource? {
        switch self {
        case .browse: nil
        case .library: "资料库"
        case .follows: "关注"
        case .favorites: "收藏夹"
        }
    }

    /// 未登录（含仍在确认）时整组不显示：行来自只属于当前账户的列表，没有可显示的行。
    var isShownOnlyWhenSignedIn: Bool {
        switch self {
        case .browse, .library: false
        case .follows, .favorites: true
        }
    }
}

/// 侧栏一个平级来源的描述：标题、图标、所属分组，以及窗口在来源边界上对它做的事。
///
/// 只保存读取与动作闭包，不拥有模型；模型归 `WindowComposition`。侧栏行、刷新回顶、离开来源时的停用、账户变化、
/// 关窗与其他窗口换号时的清理都遍历 `AppSources`，新增来源时这些地方不需要各自再登记一次。根视图的构造
/// （`AppShellView.selectedSourceRoot`）与 Browse 工作集的激活（`AppRootView.browseActivation`）依赖各来源
/// 自己的类型，仍是 `AppTab` 上的穷尽 switch，漏写由编译器报。
@MainActor
struct AppSourceDescriptor: Identifiable {
    let id: AppTab
    /// 侧栏行与来源页导航标题共用。
    let title: LocalizedStringResource
    let systemImage: String
    /// 侧栏里所属的组；组内按 `AppTab` 的声明顺序排列。
    let group: AppSourceGroup
    /// 来源在侧栏提供多行（每行一个条目）时的选中读写；只有一行的来源为 nil。
    ///
    /// 侧栏的选择值据此在来源本身与条目行之间映射（`AppSidebarSelection`）。
    let itemSelection: AppSourceItemSelection?
    /// 内容只属于当前账户（只在登录后读取）。
    ///
    /// 其他窗口换号时，本窗口在自己的复核结束前就先 `reset`，不让上一账户的内容在复核期间继续显示。
    let requiresAccount: Bool
    /// 内容被整体替换的代次；`AppShellView` 在它前进时只把这个来源的网格滚回顶部。
    ///
    /// 按各来源现有语义透传：推荐、热门与搜索只在原地刷新成功时前进，稍后再看、观看历史与关注每次加载成功（含首次加载、
    /// 换行、换排序或关键词）都前进，收藏夹每次整体替换成功（选夹、换夹、翻页、换排序或关键词、刷新）都前进。
    let refreshGeneration: @MainActor () -> UInt64
    /// 从本来源切到另一个来源时调用一次；推荐、热门与搜索的停用由 Browse 激活（`AppRootView.browseActivation`）
    /// 统一承担，这里不动作。
    let deactivate: @MainActor () -> Void
    /// 账户会话变化后通知来源，由来源自己决定丢弃、重启或重新加载；App 不替来源判断。
    ///
    /// 本窗口范围发生已解析的变化时对所有来源调用；其他窗口换号、本窗口复核结束后只对不要求账户的来源再调用
    /// 一次（要求账户的来源已在复核前 `reset`，由复核得出的范围变化重新加载）。可能以同一代次收到多次，按代次
    /// 去重的来源（Browse）只处理一次。
    let synchronizeAccountSession: @MainActor (AccountSessionChange) -> Void
    /// 绑定本来源的账户复核参与者：只在本来源是当前来源时收到复核结果（`AccountRevalidationParticipants`）。
    ///
    /// 稍后再看、观看历史、关注页与收藏夹的夹内页面复核成功后会加载，不在本页时不能让它在后台读取账户内容。不绑定来源
    /// 的参与者（视频、弹幕、评论、UP 主空间、三个来源共用的 Browse，以及侧栏常驻的收藏夹列表与关注分组）由
    /// `WindowComposition` 另行登记；侧栏的这两组是例外：它们是侧栏行的元数据，窗口已登录就读取（见 SECURITY-MODEL §3）。
    let revalidationParticipant: (any AccountRevalidationParticipant)?
    /// 取消本来源自己的请求并丢弃自己的内容（搜索的草稿与热搜、稍后再看的列表与条件、观看历史、关注的分组、选中的行、
    /// 条件与列表、收藏夹的列表、选择、条件与夹内内容）。
    ///
    /// 由 `AppSources` 调用：关窗时对所有来源，其他窗口换号时只对 `requiresAccount` 的来源。推荐、热门与搜索
    /// 共用的 Browse 工作集不属于某一个来源，不在这里，由 `AppSources.resetForWindowClosure` 整体丢弃一次。
    let reset: @MainActor () -> Void
}

/// 账户会话变化时交给来源的事实。
struct AccountSessionChange {
    /// 进程账户会话代次（`AccountSessionCoordinator.generation`）。
    let generation: UInt64
    /// 本窗口的账户范围。
    let scope: AccountSessionScope
    /// 收到通知的来源是否为当前来源。
    let isCurrentRoute: Bool
}

/// 侧栏的一段：一个分组与它按 `AppTab` 声明顺序排列的来源；没有来源的组不成段。
@MainActor
struct AppSourceSection: Identifiable {
    let group: AppSourceGroup
    let sources: [AppSourceDescriptor]

    var id: AppSourceGroup { group }
}

/// 一个窗口的全部来源描述，按侧栏顺序排列（组的顺序固定，组内按 `AppTab` 的声明顺序）；由 `WindowComposition`
/// 构造一次。
///
/// 构造是对 `AppTab.allCases` 的穷尽 switch：新增一个 `AppTab` 必须在这里给出完整描述（含所属的组），否则不能
/// 编译，因此每个 `AppTab` 恰好有一份描述，按 tab 取描述不会落空。
@MainActor
struct AppSources {
    /// 侧栏顺序的全部来源，等于 `sections` 依次展开。
    let ordered: [AppSourceDescriptor]
    /// 侧栏的分段，按 `AppSourceGroup` 的声明顺序。
    let sections: [AppSourceSection]
    /// 推荐、热门与搜索共用的 Browse 工作集；只在关窗时整体丢弃。
    private let resetBrowseWorksets: @MainActor () -> Void

    init(
        browseModel: BrowseViewModel,
        watchLaterModel: WatchLaterViewModel,
        watchLaterSession: WatchLaterSession,
        historyModel: WatchHistoryViewModel,
        favoriteFolderList: FavoriteFolderListModel,
        favoriteFolders: FavoriteFolderViewModel,
        followGroupList: FollowGroupListModel,
        followSession: FollowListSession,
        searchSession: VideoSearchSession,
        trendingSearchModel: TrendingSearchViewModel
    ) {
        // 推荐、热门与搜索共用一个模型：Browse 按代次去重，丢弃三份工作集并只重启当前路由。
        let synchronizeBrowse: @MainActor (AccountSessionChange) -> Void = {
            browseModel.synchronizeAuthenticationSession(generation: $0.generation)
        }
        resetBrowseWorksets = { browseModel.reset() }
        let descriptors = AppTab.allCases.map { tab in
            switch tab {
            case .search:
                AppSourceDescriptor(
                    id: tab,
                    title: "搜索",
                    systemImage: "magnifyingglass",
                    group: .browse,
                    itemSelection: nil,
                    requiresAccount: false,
                    refreshGeneration: { browseModel.successfulRefreshGeneration(for: .search) },
                    deactivate: {},
                    synchronizeAccountSession: synchronizeBrowse,
                    revalidationParticipant: nil,
                    reset: {
                        searchSession.reset()
                        trendingSearchModel.reset()
                    }
                )
            case .home:
                AppSourceDescriptor(
                    id: tab,
                    title: "首页",
                    systemImage: "house",
                    group: .browse,
                    itemSelection: nil,
                    requiresAccount: false,
                    refreshGeneration: {
                        browseModel.successfulRefreshGeneration(for: .recommendation)
                    },
                    deactivate: {},
                    synchronizeAccountSession: synchronizeBrowse,
                    revalidationParticipant: nil,
                    // 推荐与热门只有共用的 Browse 工作集，没有自己的内容。
                    reset: {}
                )
            case .popular:
                AppSourceDescriptor(
                    id: tab,
                    title: "热门",
                    systemImage: "flame",
                    group: .browse,
                    itemSelection: nil,
                    requiresAccount: false,
                    refreshGeneration: { browseModel.successfulRefreshGeneration(for: .popular) },
                    deactivate: {},
                    synchronizeAccountSession: synchronizeBrowse,
                    revalidationParticipant: nil,
                    // 推荐与热门只有共用的 Browse 工作集，没有自己的内容。
                    reset: {}
                )
            case .watchLater:
                AppSourceDescriptor(
                    id: tab,
                    title: "稍后再看",
                    systemImage: "play.square.stack",
                    group: .library,
                    itemSelection: nil,
                    requiresAccount: true,
                    refreshGeneration: { watchLaterModel.successfulReloadGeneration },
                    deactivate: watchLaterModel.deactivateRoute,
                    // 账户变化与 reset 经会话：先把排序、筛选与关键词恢复默认，再交给列表。
                    synchronizeAccountSession: {
                        watchLaterSession.synchronizeAuthenticationSession(
                            scope: $0.scope,
                            isCurrentRoute: $0.isCurrentRoute
                        )
                    },
                    revalidationParticipant: watchLaterModel,
                    reset: watchLaterSession.reset
                )
            case .history:
                AppSourceDescriptor(
                    id: tab,
                    title: "观看历史",
                    systemImage: "clock.arrow.circlepath",
                    group: .library,
                    itemSelection: nil,
                    requiresAccount: true,
                    refreshGeneration: { historyModel.successfulReloadGeneration },
                    deactivate: historyModel.deactivateRoute,
                    synchronizeAccountSession: {
                        historyModel.synchronizeAuthenticationSession(
                            scope: $0.scope,
                            isCurrentRoute: $0.isCurrentRoute
                        )
                    },
                    revalidationParticipant: historyModel,
                    reset: historyModel.reset
                )
            case .follows:
                AppSourceDescriptor(
                    id: tab,
                    title: "关注",
                    systemImage: "person.2",
                    group: .follows,
                    itemSelection: AppSourceItemSelection(
                        selectedID: { followSession.selectedRowID },
                        select: { followSession.select(rowID: $0) }
                    ),
                    requiresAccount: true,
                    refreshGeneration: { followSession.model.successfulReloadGeneration },
                    deactivate: followSession.deactivateRoute,
                    // 页面丢弃上一账户的条件与内容；分组列表不论是否当前来源都按新账户重读。
                    synchronizeAccountSession: {
                        followSession.synchronizeAuthenticationSession(
                            scope: $0.scope,
                            isCurrentRoute: $0.isCurrentRoute
                        )
                        followGroupList.synchronizeAuthenticationSession()
                    },
                    revalidationParticipant: followSession.model,
                    reset: {
                        followSession.reset()
                        followGroupList.reset()
                    }
                )
            case .favorites:
                AppSourceDescriptor(
                    id: tab,
                    title: "收藏夹",
                    systemImage: "folder",
                    group: .favorites,
                    itemSelection: AppSourceItemSelection(
                        selectedID: { favoriteFolders.selectedFolderID },
                        select: { favoriteFolders.selectFolder($0) }
                    ),
                    requiresAccount: true,
                    refreshGeneration: { favoriteFolders.successfulReloadGeneration },
                    deactivate: favoriteFolders.deactivateRoute,
                    // 夹内页面丢弃上一账户的选择与内容；列表不论是否当前来源都按新账户重读。
                    synchronizeAccountSession: { _ in
                        favoriteFolders.synchronizeAuthenticationSession()
                        favoriteFolderList.synchronizeAuthenticationSession()
                    },
                    revalidationParticipant: favoriteFolders,
                    reset: {
                        favoriteFolders.reset()
                        favoriteFolderList.reset()
                    }
                )
            }
        }
        sections = AppSourceGroup.allCases.compactMap { group in
            let sources = descriptors.filter { $0.group == group }
            return sources.isEmpty ? nil : AppSourceSection(group: group, sources: sources)
        }
        ordered = sections.flatMap(\.sources)
    }

    /// 关窗：每个来源丢弃自己的内容，再整体丢弃一次 Browse 工作集。
    func resetForWindowClosure() {
        for source in ordered {
            source.reset()
        }
        resetBrowseWorksets()
    }

    /// 其他窗口换号、本窗口复核前：只丢弃要求账户的来源的内容，不让上一账户的内容在复核期间继续显示。
    func resetAccountContent() {
        for source in ordered where source.requiresAccount {
            source.reset()
        }
    }

    /// 账户范围变化后当前来源应在哪里：当前来源所在的组在新范围下不再显示（未登录时的「收藏夹」）时回到首页，否则不变。
    func route(afterAccountChangeFrom tab: AppTab, scope: AccountSessionScope) -> AppTab {
        guard self[tab].group.isShownOnlyWhenSignedIn else { return tab }
        if case .signedIn = scope { return tab }
        return .home
    }

    subscript(tab: AppTab) -> AppSourceDescriptor {
        guard let descriptor = ordered.first(where: { $0.id == tab }) else {
            preconditionFailure("AppSources 对每个 AppTab 都构造了描述")
        }
        return descriptor
    }
}
