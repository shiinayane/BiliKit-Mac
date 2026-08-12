import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import SwiftUI

struct PopularTabRoot: View {
    let model: GuestBrowseViewModel
    @Binding var scrollOffsetY: CGFloat
    let onSelect: (String) -> Void

    var body: some View {
        PopularFeedView(
            model: model,
            scrollOffsetY: $scrollOffsetY,
            makeLoadedContent: { videos, scrollOffsetY, onSelect in
                AnyView(
                    PopularNativeGridView(
                        videos: videos,
                        scrollOffsetY: scrollOffsetY,
                        onSelect: onSelect
                    )
                    .ignoresSafeArea(.container, edges: .top)
                )
            },
            onSelect: onSelect
        )
        .navigationTitle("热门")
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

struct SearchTabRoot: View {
    let model: GuestBrowseViewModel
    @Binding var searchDraft: String
    let submittedSearchQuery: String?
    @Binding var scrollPosition: ScrollPosition
    let onSelect: (String) -> Void
    let onSubmit: () -> Void

    var body: some View {
        VideoSearchView(
            model: model,
            submittedSearchQuery: submittedSearchQuery,
            scrollPosition: $scrollPosition,
            onSelect: onSelect
        )
        .navigationTitle("搜索")
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .searchable(
            text: $searchDraft,
            placement: searchFieldPlacement,
            prompt: "搜索 B 站视频"
        )
        .onSubmit(of: .search) {
            onSubmit()
        }
    }

    private var searchFieldPlacement: SearchFieldPlacement {
        #if compiler(>=6.2)
            .toolbarPrincipal
        #else
            .toolbar
        #endif
    }
}

struct HistoryTabRoot: View {
    let model: WatchHistoryViewModel
    let accountState: AccountPresentationState
    @Binding var scrollPosition: ScrollPosition
    let onSelect: (String) -> Void
    let onPresentAuthentication: () -> Void
    let onAuthenticationRequired: () -> Void

    var body: some View {
        content
            .navigationTitle("观看历史")
            .toolbar {
                if case .signedIn = accountState {
                    ToolbarItem(placement: .primaryAction) {
                        HistoryRefreshButton(model: model)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch accountState {
        case .signedIn:
            WatchHistoryView(
                model: model,
                scrollPosition: $scrollPosition,
                onSelect: onSelect,
                onAuthenticationRequired: onAuthenticationRequired
            )
        case .signedOut:
            ContentUnavailableView {
                Label("登录后查看观看历史", systemImage: "person.crop.circle")
            } description: {
                Text("观看历史只在登录期间加载，不会保存到本机。")
            } actions: {
                Button("登录", action: onPresentAuthentication)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("打开扫码登录")
            }
        case .resolving:
            ProgressView("正在检查登录状态…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label(
                    "暂时无法确认登录状态",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
            } description: {
                Text("本机登录状态没有被自动清除，请在账号页面重试。")
            } actions: {
                Button("查看账号状态", action: onPresentAuthentication)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct HistoryRefreshButton: View {
    let model: WatchHistoryViewModel

    var body: some View {
        Button {
            model.reload()
        } label: {
            Label("刷新", systemImage: "arrow.clockwise")
        }
        .disabled(model.isBusy)
    }
}
