import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import SwiftUI

struct AppShellView: View {
    let navigationModel: AppNavigationModel
    let feedModel: GuestFeedViewModel
    let videoModel: GuestVideoViewModel
    let subtitleModel: SubtitleViewModel
    let danmakuModel: DanmakuControlsViewModel
    let authenticationModel: AuthenticationViewModel
    let historyModel: WatchHistoryViewModel
    let playerContent: AnyView
    @Binding var isAuthenticationPresented: Bool
    let onSubmitSearch: () -> Void

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            routeContent
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1_080, minHeight: 680)
        .sheet(isPresented: $isAuthenticationPresented) {
            AuthenticationView(model: authenticationModel)
        }
    }

    private var sidebar: some View {
        List(selection: selectedSectionBinding) {
            Label("搜索", systemImage: "magnifyingglass")
                .tag(AppSection.search)
                .accessibilityIdentifier("sidebar.search")
            Label("热门", systemImage: "flame")
                .tag(AppSection.popular)
                .accessibilityIdentifier("sidebar.popular")
            Label("观看历史", systemImage: "clock.arrow.circlepath")
                .tag(AppSection.history)
                .accessibilityIdentifier("sidebar.history")
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                isAuthenticationPresented = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                    Text(authenticationModel.isSignedIn ? "账号" : "登录")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .accessibilityHint(
                authenticationModel.isSignedIn
                    ? "打开账号管理"
                    : "打开扫码登录"
            )
            .accessibilityIdentifier("sidebar.account")
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    }

    @ViewBuilder
    private var routeContent: some View {
        switch navigationModel.route {
        case .section(.popular):
            PopularPageRoot(
                model: feedModel,
                selectedBVID: selectedBVID(for: .popular),
                onSelect: navigationModel.openPlayback
            )
        case .section(.search):
            SearchPageRoot(
                model: feedModel,
                query: searchQueryBinding,
                selectedBVID: selectedBVID(for: .search),
                onSelect: navigationModel.openPlayback,
                onSubmit: onSubmitSearch
            )
        case .section(.history):
            HistoryPageRoot(
                model: historyModel,
                isSignedIn: authenticationModel.isSignedIn,
                onSelect: navigationModel.openPlayback,
                onPresentAuthentication: {
                    isAuthenticationPresented = true
                },
                onAuthenticationRequired: {
                    historyModel.reset()
                    authenticationModel.revalidate()
                }
            )
        case .playback:
            PlaybackPageRoot(
                model: videoModel,
                subtitleModel: subtitleModel,
                danmakuModel: danmakuModel,
                playerContent: playerContent,
                onRetry: navigationModel.retryPlayback,
                onReturn: navigationModel.returnFromPlayback
            )
        }
    }

    private var selectedSectionBinding: Binding<AppSection?> {
        Binding(
            get: { navigationModel.selectedSection },
            set: { navigationModel.selectedSection = $0 }
        )
    }

    private var searchQueryBinding: Binding<String> {
        Binding(
            get: { navigationModel.searchQuery },
            set: { navigationModel.searchQuery = $0 }
        )
    }

    private func selectedBVID(for section: AppSection) -> String? {
        guard navigationModel.returnSnapshot?.sourceSection == section else {
            return nil
        }
        return navigationModel.returnSnapshot?.selectedBVID
    }
}

private struct PopularPageRoot: View {
    let model: GuestFeedViewModel
    let selectedBVID: String?
    let onSelect: (String) -> Void

    var body: some View {
        PopularFeedView(
            model: model,
            selectedBVID: selectedBVID,
            onSelect: onSelect
        )
        .navigationTitle("热门")
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

private struct SearchPageRoot: View {
    let model: GuestFeedViewModel
    @Binding var query: String
    let selectedBVID: String?
    let onSelect: (String) -> Void
    let onSubmit: () -> Void

    var body: some View {
        VideoSearchView(
            model: model,
            selectedBVID: selectedBVID,
            onSelect: onSelect
        )
        .navigationTitle("搜索")
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                CenteredSearchField(
                    text: $query,
                    placeholder: "搜索 B 站视频",
                    onSubmit: onSubmit
                )
                .frame(width: 340)
                .accessibilityIdentifier("search.field")
            }
        }
    }
}

private struct HistoryPageRoot: View {
    let model: WatchHistoryViewModel
    let isSignedIn: Bool
    let onSelect: (String) -> Void
    let onPresentAuthentication: () -> Void
    let onAuthenticationRequired: () -> Void

    var body: some View {
        content
            .navigationTitle("观看历史")
            .toolbar {
                if isSignedIn {
                    ToolbarItem(placement: .primaryAction) {
                        HistoryRefreshButton(model: model)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if isSignedIn {
            WatchHistoryView(
                model: model,
                onSelect: onSelect,
                onAuthenticationRequired: onAuthenticationRequired
            )
        } else {
            ContentUnavailableView {
                Label("登录后查看观看历史", systemImage: "person.crop.circle")
            } description: {
                Text("观看历史只在登录期间加载，不会保存到本机。")
            } actions: {
                Button("登录", action: onPresentAuthentication)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("打开扫码登录")
                    .accessibilityIdentifier("history.login")
            }
            .accessibilityIdentifier("history.signed-out")
        }
    }

}

struct HistoryRefreshButton: View {
    let model: WatchHistoryViewModel

    var isDisabled: Bool {
        model.isBusy
    }

    var body: some View {
        Button {
            model.reload()
        } label: {
            Label("刷新", systemImage: "arrow.clockwise")
        }
        .disabled(isDisabled)
        .accessibilityIdentifier("history.reload")
    }
}

private struct PlaybackPageRoot: View {
    let model: GuestVideoViewModel
    let subtitleModel: SubtitleViewModel
    let danmakuModel: DanmakuControlsViewModel
    let playerContent: AnyView
    let onRetry: () -> Void
    let onReturn: () -> Void

    var body: some View {
        VideoDetailColumn(
            model: model,
            subtitleModel: subtitleModel,
            danmakuModel: danmakuModel,
            onRetry: onRetry
        ) {
            playerContent
        }
        .navigationTitle("播放")
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: onReturn) {
                    Label("返回", systemImage: "chevron.backward")
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("返回来源页面并停止当前播放")
                .accessibilityIdentifier("playback.back")
            }
        }
    }
}
