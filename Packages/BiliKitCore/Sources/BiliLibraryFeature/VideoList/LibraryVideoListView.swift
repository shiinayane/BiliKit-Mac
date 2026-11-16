import BiliApplication
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 资料库列表来源（观看历史、稍后再看）共用的根视图：按账户呈现状态显示登录门槛，已登录时显示列表内容与
/// 原生网格，把页面可见性连接到 ViewModel 的加载与路由停用语义，并在工具栏提供刷新。
///
/// `.task` 只在已登录、列表内容出现时触发并等待模型当前请求。真正的来源 Tab 停用由 App composition
/// 通知模型；播放详情只是覆盖本页面，不应误取消分页。登出清理仍由窗口级 `reset` 边界负责；凭据失效经
/// 模型的 `authenticationRevalidationGeneration` 交给 App 统一复核。登录与账号页面由 App 注入的
/// `onPresentAuthentication` 打开。滚动位置、回顶请求与图片管线属于 App 窗口，经
/// `NativeVideoGridHostContext` 原样交给网格。登录门槛与工具栏（来源给的控件加刷新按钮）在共用的
/// `LibrarySourceShell`。
struct LibraryVideoListView<Item: Sendable & Equatable, Cursor: Equatable & Sendable>: View {
    let model: LibraryVideoListModel<Item, Cursor>
    let text: LibraryVideoListText
    let card: (Item) -> NativeVideoCardPresentation
    /// 卡片菜单的稍后再看写操作：稍后再看页是移除，观看历史是加入。
    let watchLaterAction: NativeVideoCardMenu.WatchLaterAction
    let accountState: AccountPresentationState
    let gridHost: NativeVideoGridHostContext
    let onSelect: (String) -> Void
    let onPresentAuthentication: () -> Void
    /// 排在刷新按钮之前的工具栏控件；没有时为 nil。
    var toolbarControls: AnyView? = nil
    /// 刷新按钮的动作；没有时直接 `model.reload()`。
    ///
    /// 稍后再看经会话刷新，由会话决定条件。
    var refresh: (() -> Void)? = nil

    var body: some View {
        LibrarySourceShell(
            accountState: accountState,
            signInTitle: text.signInTitle,
            signInDescription: text.signInDescription,
            onPresentAuthentication: onPresentAuthentication,
            toolbarControls: toolbarControls,
            isBusy: { model.isBusy },
            refresh: refresh ?? model.reload,
            content: {
                LibraryListContentView(
                    model: model,
                    text: text,
                    loading: {
                        VideoCardGridSkeleton(
                            loadingLabel: text.loading,
                            expectedItemCount: model.expectedLoadingItemCount
                        )
                    },
                    grid: { items, tailState in
                        LibraryVideoGrid(
                            items: items,
                            tailState: tailState,
                            accessibilityLabel: text.gridAccessibilityLabel,
                            card: card,
                            watchLaterAction: watchLaterAction,
                            gridHost: gridHost,
                            onNearEnd: model.loadMore,
                            onSelect: onSelect
                        )
                    }
                )
                .task {
                    model.loadIfNeeded()
                    await model.waitForCurrentTask()
                }
            }
        )
    }
}

/// 资料库来源（观看历史、稍后再看、收藏夹）共用的外壳：按账户呈现状态显示登录门槛，已登录时显示来源内容，并在工具栏
/// primaryAction 组里依次放来源给的控件（稍后再看与收藏夹的排序等，由 App 宿主）与刷新按钮，同一组保证顺序。
///
/// 只负责排版；加载、刷新与内容状态归来源的模型，登录与账号页面由 App 注入的 `onPresentAuthentication` 打开。
struct LibrarySourceShell<Content: View>: View {
    let accountState: AccountPresentationState
    let signInTitle: String
    let signInDescription: String
    let onPresentAuthentication: () -> Void
    /// 排在刷新按钮之前的工具栏控件；没有时为 nil。
    let toolbarControls: AnyView?
    /// 刷新按钮是否禁用；只在刷新按钮里求值，加载状态变化时不让外壳重新求值。
    let isBusy: () -> Bool
    let refresh: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        AccountGateView(
            state: accountState,
            signInTitle: signInTitle,
            signInDescription: signInDescription,
            onPresentAuthentication: onPresentAuthentication,
            signedInContent: content
        )
        .toolbar {
            if case .signedIn = accountState {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let toolbarControls {
                        toolbarControls
                    }
                    LibraryRefreshButton(isBusy: isBusy, refresh: refresh)
                }
            }
        }
    }
}

/// 单独成一个 View：只有它读取忙碌状态，加载状态变化时不让整个根视图重新求值。
private struct LibraryRefreshButton: View {
    @Environment(\.locale) private var locale
    let isBusy: () -> Bool
    let refresh: () -> Void

    var body: some View {
        Button {
            refresh()
        } label: {
            Label(
                LibraryFeatureStrings.localized("刷新", locale: locale),
                systemImage: "arrow.clockwise"
            )
        }
        .disabled(isBusy())
    }
}
