import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import BiliVideoCollectionUI
import SwiftUI

/// 首页推荐来源的 App 接线：呈现与原生网格在 Browse 的 `RecommendedFeedView`，这里只转交窗口级网格依赖
/// （`AppShellView` 构造的 `NativeVideoGridHostContext`）和标题。
struct RecommendedTabRoot: View {
    let title: LocalizedStringResource
    let model: BrowseViewModel
    let gridHost: NativeVideoGridHostContext
    let onSelect: (String) -> Void

    var body: some View {
        RecommendedFeedView(
            model: model,
            gridHost: gridHost,
            onSelect: onSelect
        )
        .navigationTitle(Text(title))
    }
}

/// 热门来源的 App 接线：呈现与原生网格在 Browse 的 `PopularFeedView`，这里只转交窗口级网格依赖和标题。
struct PopularTabRoot: View {
    let title: LocalizedStringResource
    let model: BrowseViewModel
    let gridHost: NativeVideoGridHostContext
    let onSelect: (String) -> Void

    var body: some View {
        PopularFeedView(
            model: model,
            gridHost: gridHost,
            onSelect: onSelect
        )
        .navigationTitle(Text(title))
    }
}

/// 搜索来源的 App 接线：起始页、结果呈现与原生网格在 Browse 的 `VideoSearchView`，草稿、筛选与提交在 Browse 的
/// `VideoSearchSession`；这里转交窗口级网格依赖，用热搜模型、窗口图片管线（实现热搜图标 port）与进程级搜索历史
/// 构造起始页输入，并宿主绑定会话的工具栏搜索框（AppKit）与排序、筛选控件。
struct SearchTabRoot: View {
    let title: LocalizedStringResource
    @Bindable var session: VideoSearchSession
    let model: BrowseViewModel
    let gridHost: NativeVideoGridHostContext
    let imagePipeline: NativeVideoImagePipeline
    let trendingSearchModel: TrendingSearchViewModel
    let searchHistory: SearchHistoryStore
    let searchSuggestionSource: SearchSuggestionSource
    let onSelect: (String) -> Void

    var body: some View {
        VideoSearchView(
            model: model,
            submittedSearchCriteria: session.submittedCriteria,
            hasActiveFilters: session.filterSelection.activeFilterCount > 0,
            gridHost: gridHost,
            startPageContext: startPageContext,
            onSelect: onSelect,
            onClearFilters: session.clearFilters
        )
        .navigationTitle(Text(title))
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ToolbarSearchField(
                    text: $session.draft,
                    prompt: AppStrings.localized("搜索 B 站视频"),
                    history: { searchHistory.entries },
                    suggestionSource: searchSuggestionSource,
                    onSubmit: session.submit,
                    onSelectSuggestion: session.search(keyword:)
                )
                .frame(
                    minWidth: ToolbarSearchFieldLayout.minimumWidth,
                    idealWidth: ToolbarSearchFieldLayout.idealWidth,
                    maxWidth: ToolbarSearchFieldLayout.idealWidth
                )
            }
            ToolbarItemGroup(placement: .primaryAction) {
                SearchToolbarControls(
                    selection: $session.filterSelection,
                    onSelectOrder: session.selectOrder,
                    onApplyFilters: session.applyFilters
                )
            }
        }
    }

    /// 历史以读取闭包交出，只在起始页里求值，这里不读 `entries`。
    private var startPageContext: SearchStartPageContext {
        SearchStartPageContext(
            trendingModel: trendingSearchModel,
            iconLoader: imagePipeline,
            history: { searchHistory.entries },
            onSearch: session.search(keyword:),
            onRemoveHistory: { searchHistory.remove($0) },
            onClearHistory: { searchHistory.clear() }
        )
    }
}

/// 稍后再看来源的 App 接线：登录门槛、刷新、加载语义、筛选空态与原生网格在 Library 的 `WatchLaterView`，条件在
/// Library 的 `WatchLaterSession`。
///
/// 这里转交账户呈现状态、窗口级网格依赖、标题与打开登录页的动作，并构造排序菜单与筛选按钮
/// （`WatchLaterToolbarControls`）交给 Feature：控件挂在 Feature 的 `.toolbar` 里、与刷新同一 primaryAction 组且排在
/// 刷新之前，只在已登录时出现。这里还挂工具栏尾部的紧凑搜索框（系统 `.searchable`，只在已登录时；回车提交、清空
/// 恢复全部）与当前条件下总数的副标题。搜索框不放工具栏正中：那是搜索来源的全局搜索框，这里只过滤本列表。
struct WatchLaterTabRoot: View {
    @Environment(\.locale) private var locale
    let title: LocalizedStringResource
    let model: WatchLaterViewModel
    @Bindable var session: WatchLaterSession
    let accountState: AccountPresentationState
    let gridHost: NativeVideoGridHostContext
    let onSelect: (String) -> Void
    let onPresentAuthentication: () -> Void

    var body: some View {
        WatchLaterView(
            model: model,
            session: session,
            accountState: accountState,
            gridHost: gridHost,
            onSelect: onSelect,
            onPresentAuthentication: onPresentAuthentication,
            toolbarControls: AnyView(WatchLaterToolbarControls(session: session))
        )
        .navigationTitle(Text(title))
        .navigationSubtitle(LibraryToolbarText.totalCount(model.totalCount, locale: locale))
        .modifier(
            LibrarySearchField(
                accountState: accountState,
                text: $session.searchDraft,
                prompt: AppStrings.localized("搜索稍后再看", locale: locale),
                onSubmit: session.submitSearch
            )
        )
    }
}

/// 收藏夹来源的 App 接线：登录门槛、刷新、加载语义、空态、页码条与原生网格在 Library 的 `FavoriteFolderView`，选择与条件在
/// Library 的 `FavoriteFolderViewModel`。
///
/// 这里转交账户呈现状态、窗口级网格依赖与打开登录页的动作，构造排序菜单（`FavoritesToolbarControls`，排在刷新之前），
/// 并挂工具栏尾部的紧凑搜索框（系统 `.searchable`，只在已登录时；只搜当前收藏夹，回车提交、清空恢复）。导航标题是选中的
/// 收藏夹名称（列表未到时用来源标题），副标题是当前条件下的总数。
struct FavoritesTabRoot: View {
    @Environment(\.locale) private var locale
    let title: LocalizedStringResource
    @Bindable var model: FavoriteFolderViewModel
    let accountState: AccountPresentationState
    let gridHost: NativeVideoGridHostContext
    let onSelect: (String) -> Void
    let onPresentAuthentication: () -> Void

    var body: some View {
        FavoriteFolderView(
            model: model,
            accountState: accountState,
            gridHost: gridHost,
            onSelect: onSelect,
            onPresentAuthentication: onPresentAuthentication,
            toolbarControls: AnyView(FavoritesToolbarControls(model: model))
        )
        .navigationTitle(navigationTitle)
        .navigationSubtitle(LibraryToolbarText.totalCount(model.totalCount, locale: locale))
        .modifier(
            LibrarySearchField(
                accountState: accountState,
                text: $model.searchDraft,
                prompt: AppStrings.localized("搜索收藏夹", locale: locale),
                onSubmit: model.submitSearch
            )
        )
    }

    private var navigationTitle: Text {
        if let folderTitle = model.selectedFolderTitle {
            Text(verbatim: folderTitle)
        } else {
            Text(title)
        }
    }
}

/// 资料库来源（稍后再看、关注、收藏夹）工具栏尾部的紧凑搜索框：系统 `.searchable`，只在已登录时挂上；回车提交、清空恢复
/// 全部（清空的规则在来源的模型里）。
///
/// 不放工具栏正中：那是搜索来源的全局搜索框，这里只过滤本来源。
private struct LibrarySearchField: ViewModifier {
    let accountState: AccountPresentationState
    @Binding var text: String
    let prompt: String
    let onSubmit: () -> Void
    /// 来源此刻是否提供搜索（关注只在全部关注时提供）。
    var isAvailable = true

    func body(content: Content) -> some View {
        if case .signedIn = accountState, isAvailable {
            content
                .searchable(text: $text, placement: .toolbar, prompt: Text(prompt))
                .onSubmit(of: .search, onSubmit)
        } else {
            content
        }
    }
}

/// 关注来源的 App 接线：登录门槛、刷新、加载语义、空态与人物卡片网格在 Library 的 `FollowListView`，选中的行与条件在
/// Library 的 `FollowListSession`。
///
/// 这里转交账户呈现状态、窗口级网格依赖与打开登录页的动作，构造排序菜单（`FollowsToolbarControls`，只在全部关注且没有
/// 搜索时），并挂工具栏尾部的紧凑搜索框（只在全部关注时；回车提交、清空恢复）。导航标题是选中的行（「全部关注」或分组名，
/// 分组列表未到时用来源标题），副标题是当前列表的总人数（分组成员接口不给总数，分组页没有副标题）。点卡片压一层整页空间页。
struct FollowsTabRoot: View {
    @Environment(\.locale) private var locale
    let title: LocalizedStringResource
    @Bindable var session: FollowListSession
    let groupList: FollowGroupListModel
    let accountState: AccountPresentationState
    let gridHost: NativeVideoGridHostContext
    let onSelect: FollowListView.Selection
    let onPresentAuthentication: () -> Void

    var body: some View {
        FollowListView(
            session: session,
            accountState: accountState,
            gridHost: gridHost,
            onSelect: onSelect,
            onPresentAuthentication: onPresentAuthentication,
            toolbarControls: AnyView(FollowsToolbarControls(session: session))
        )
        .navigationTitle(navigationTitle)
        .navigationSubtitle(
            LibraryToolbarText.personCount(session.model.totalCount, locale: locale)
        )
        .modifier(
            LibrarySearchField(
                accountState: accountState,
                text: $session.searchDraft,
                prompt: AppStrings.localized("在关注中搜索", locale: locale),
                onSubmit: session.submitSearch,
                isAvailable: session.isShowingAllFollowings
            )
        )
    }

    private var navigationTitle: Text {
        if let rowTitle = session.selectedRowTitle(groupList: groupList, locale: locale) {
            Text(verbatim: rowTitle)
        } else {
            Text(title)
        }
    }
}

/// 资料库来源工具栏的共用文字。
private enum LibraryToolbarText {
    /// 副标题：已有当前条件下的总数时是“共 N 个”，其他时候为空、不显示。
    static func totalCount(_ count: Int?, locale: Locale) -> String {
        guard let count else { return "" }
        return AppStrings.localized("共 \(count) 个", locale: locale)
    }

    /// 关注页的副标题：按人计的“共 N 人”，其他同 `totalCount`。
    static func personCount(_ count: Int?, locale: Locale) -> String {
        guard let count else { return "" }
        return AppStrings.localized("共 \(count) 人", locale: locale)
    }
}

/// 观看历史来源的 App 接线：登录门槛、刷新、加载语义与原生网格在 Library 的 `WatchHistoryView`，这里只转交
/// 账户呈现状态、窗口级网格依赖、标题与打开登录页的动作。
struct HistoryTabRoot: View {
    let title: LocalizedStringResource
    let model: WatchHistoryViewModel
    let accountState: AccountPresentationState
    let gridHost: NativeVideoGridHostContext
    let onSelect: (String) -> Void
    let onPresentAuthentication: () -> Void

    var body: some View {
        WatchHistoryView(
            model: model,
            accountState: accountState,
            gridHost: gridHost,
            onSelect: onSelect,
            onPresentAuthentication: onPresentAuthentication
        )
        .navigationTitle(Text(title))
    }
}
