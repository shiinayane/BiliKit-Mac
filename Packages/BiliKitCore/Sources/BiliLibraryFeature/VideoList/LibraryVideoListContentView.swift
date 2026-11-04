import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 资料库列表页的来源文案，由来源的根视图按当前 locale 本地化后交给共用视图。
struct LibraryVideoListText {
    /// 显式继续策略的来源（观看历史）空页之后的文案。
    struct ManualContinue {
        /// 当前页没有可显示条目、但还能继续时的空态说明。
        let emptyDescription: String
        /// 显式继续按钮的标题。
        let actionTitle: String
    }

    /// 条件筛掉了全部结果时的空态：取代来源的普通空态，并给出清除条件的动作。
    struct FilteredEmpty {
        let title: String
        let description: String
        let clearTitle: String
        let clear: () -> Void
    }

    let signInTitle: String
    let signInDescription: String
    let loading: String
    let emptyTitle: String
    let emptySymbol: String
    let emptyDescription: String
    let failureTitle: String
    let refreshing: String
    let loadingMore: String
    let gridAccessibilityLabel: String
    /// 只有显式继续策略的来源给出；停止策略的来源没有显式继续入口。
    let manualContinue: ManualContinue?
    /// 只在来源有筛选或关键词在起作用时给出（稍后再看）；为 nil 时空结果用普通空态。
    var filteredEmpty: FilteredEmpty? = nil
}

/// 网格的输入：从列表状态取出条目与分页状态。
///
/// 没有条目的 `loaded`、加载中与失败时构造失败，由空页、骨架或失败页接手；加载更多期间总能构造。
struct LibraryVideoListLoadedSurface<Item: Sendable & Equatable, Cursor: Equatable & Sendable>:
    Equatable
{
    let items: [Item]
    let canLoadMore: Bool
    let isLoadingMore: Bool
    let requiresManualLoadMore: Bool
    let loadMoreError: ContentApplicationError?

    init?(state: LibraryVideoListState<Item, Cursor>, requiresManualLoadMore: Bool) {
        switch state {
        case .loaded(let items, let continuation, let loadMoreError)
        where !items.isEmpty:
            self.items = items
            canLoadMore = continuation != nil
            isLoadingMore = false
            self.requiresManualLoadMore = requiresManualLoadMore
            self.loadMoreError = loadMoreError
        case .loadingMore(let items, _):
            self.items = items
            canLoadMore = true
            isLoadingMore = true
            self.requiresManualLoadMore = false
            loadMoreError = nil
        case .idle, .loading, .loaded, .failed:
            return nil
        }
    }
}

/// 已登录时的资料库列表主区：按 `LibraryVideoListModel` 的状态显示骨架、空页、失败页或原生网格，叠加刷新与
/// 分页状态胶囊；凭据失败的说明按模型的账户复核进度区分。
///
/// 不拥有请求、分页与复核（`LibraryVideoListModel`）；条目到卡片的映射由来源给出，滚动位置、回顶请求与图片
/// 管线由根视图从 App 窗口转交；卡片菜单取 `LibraryVideoCardMenu`，写入口来自 App 注入的环境 `videoCardAccountWriting`。
struct LibraryVideoListContentView<Item: Sendable & Equatable, Cursor: Equatable & Sendable>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @Environment(\.videoCardAccountWriting) private var accountWriting
    let model: LibraryVideoListModel<Item, Cursor>
    let text: LibraryVideoListText
    let card: (Item) -> NativeVideoCardPresentation
    /// 卡片展示数据按位置缓存，加载更多时只格式化新追加的条目，见 `NativeVideoCardCache`。
    @State private var cards = NativeVideoCardCache<Item>()
    /// 卡片菜单的稍后再看写操作：稍后再看页是移除，观看历史是加入。
    let watchLaterAction: NativeVideoCardMenu.WatchLaterAction
    let gridHost: NativeVideoGridHostContext
    let onSelect: (String) -> Void

    var body: some View {
        ZStack {
            content
                .transition(.opacity)
        }
        .animation(
            LoadingStateTransition.animation(reduceMotion: reduceMotion),
            value: visualPhase
        )
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            VideoCardGridSkeleton(
                loadingLabel: text.loading,
                expectedItemCount: model.expectedLoadingItemCount
            )
        case .loaded(let items, let continuation, let loadMoreError) where items.isEmpty:
            emptyList(
                canLoadMore: continuation != nil,
                loadMoreError: loadMoreError
            )
        case .failed(let error):
            failures.view(error, fallbackTitle: text.failureTitle, retry: { model.reload() })
        case .loaded, .loadingMore:
            // 有条目的 loaded 与加载更多共用这一支，网格在加载更多前后保持同一视图身份；
            // 这两种状态下 surface 总能构造。
            if let surface = LibraryVideoListLoadedSurface(
                state: model.state,
                requiresManualLoadMore: model.requiresManualLoadMore
            ) {
                videoList(surface)
            }
        }
    }

    private var visualPhase: LoadingVisualPhase {
        switch model.state {
        case .idle, .loading:
            .loading
        case .loaded(let items, _, _) where items.isEmpty:
            .empty
        case .loaded, .loadingMore:
            .content
        case .failed:
            .failure
        }
    }

    @ViewBuilder
    private func emptyList(
        canLoadMore: Bool,
        loadMoreError: ContentApplicationError?
    ) -> some View {
        if let filteredEmpty = text.filteredEmpty, !canLoadMore, loadMoreError == nil {
            ContentUnavailableView {
                Label(filteredEmpty.title, systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(filteredEmpty.description)
            } actions: {
                Button(filteredEmpty.clearTitle, action: filteredEmpty.clear)
            }
        } else {
            unfilteredEmptyList(canLoadMore: canLoadMore, loadMoreError: loadMoreError)
        }
    }

    private func unfilteredEmptyList(
        canLoadMore: Bool,
        loadMoreError: ContentApplicationError?
    ) -> some View {
        ContentUnavailableView {
            Label(text.emptyTitle, systemImage: text.emptySymbol)
        } description: {
            if let loadMoreError {
                Text(failures.message(for: loadMoreError))
            } else if canLoadMore, let manualContinue = text.manualContinue {
                Text(manualContinue.emptyDescription)
            } else {
                Text(text.emptyDescription)
            }
        } actions: {
            if canLoadMore, loadMoreError?.isRetryable ?? true,
                let manualContinue = text.manualContinue
            {
                Button(manualContinue.actionTitle) {
                    model.loadMore()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func videoList(
        _ surface: LibraryVideoListLoadedSurface<Item, Cursor>
    ) -> some View {
        NativeVideoGridView(
            items: cards.cards(for: surface.items, make: card),
            accessibilityLabel: text.gridAccessibilityLabel,
            // 尾标只在可自动加载时存在：显式继续门、加载更多失败与原地刷新都暂停近尾触发。
            tailState: NativeVideoGridTailState(
                canLoadMore: model.paginationTailIdentity != nil,
                tailIdentity: model.paginationTailIdentity,
                isLoading: surface.isLoadingMore
            ),
            host: gridHost,
            onNearEnd: model.loadMore,
            onSelect: onSelect,
            cardMenu: {
                LibraryVideoCardMenu.menu(
                    for: $0,
                    openURL: openURL,
                    writing: accountWriting,
                    watchLater: watchLaterAction
                )
            }
        )
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) {
            RefreshStatusCapsule(
                isRefreshing: model.isRefreshing,
                refreshingLabel: text.refreshing,
                errorMessage: model.refreshError.map(failures.message(for:))
            )
        }
        .overlay(alignment: .bottom) {
            PaginationStatusOverlay(paginationStatus(surface))
        }
    }

    private func paginationStatus(
        _ surface: LibraryVideoListLoadedSurface<Item, Cursor>
    ) -> PaginationStatusOverlay.Status {
        if surface.isLoadingMore {
            return .loadingMore(label: text.loadingMore)
        }
        if let loadMoreError = surface.loadMoreError {
            let canRetry = surface.canLoadMore && loadMoreError.isRetryable
            return .failed(
                message: failures.message(for: loadMoreError),
                retry: canRetry ? { model.loadMore() } : nil
            )
        }
        if surface.requiresManualLoadMore, let manualContinue = text.manualContinue {
            return .manualLoadMore(
                title: manualContinue.actionTitle,
                action: { model.loadMore() }
            )
        }
        return .idle
    }

    /// 失败文案按模型的账户复核进度区分（`LibraryContentFailure`）。
    private var failures: LibraryContentFailure {
        LibraryContentFailure(
            isAwaitingRevalidation: model.isAwaitingAuthenticationRevalidation,
            locale: locale
        )
    }
}
