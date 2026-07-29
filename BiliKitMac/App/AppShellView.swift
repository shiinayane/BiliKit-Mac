import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import SwiftUI

struct AppShellView: View {
    let navigationCoordinator: AppNavigationCoordinator
    let browseModel: GuestBrowseViewModel
    let videoModel: GuestVideoViewModel
    let subtitleModel: SubtitleViewModel
    let danmakuModel: DanmakuControlsViewModel
    let authenticationModel: AuthenticationViewModel
    let historyModel: WatchHistoryViewModel
    let playerContent: AnyView
    @Binding var isAuthenticationPresented: Bool
    let submittedSearchQuery: String?
    let onSubmitSearch: () -> Void
    @State private var popularScrollPosition = ScrollPosition(
        idType: String.self
    )
    @State private var searchScrollPosition = ScrollPosition(
        idType: String.self
    )
    @State private var historyScrollPosition = ScrollPosition(
        idType: String.self
    )

    var body: some View {
        @Bindable var navigationCoordinator = navigationCoordinator

        TabView(selection: $navigationCoordinator.selectedTab) {
            Tab(value: AppTab.search) {
                tabNavigation(path: playbackPathBinding(for: .search)) {
                    SearchTabRoot(
                        model: browseModel,
                        searchDraft: $navigationCoordinator.searchDraft,
                        submittedSearchQuery: submittedSearchQuery,
                        scrollPosition: $searchScrollPosition,
                        onSelect: navigationCoordinator.openPlayback,
                        onSubmit: onSubmitSearch
                    )
                }
            } label: {
                Label("搜索", systemImage: "magnifyingglass")
            }

            Tab(value: AppTab.popular) {
                tabNavigation(path: playbackPathBinding(for: .popular)) {
                    PopularTabRoot(
                        model: browseModel,
                        scrollPosition: $popularScrollPosition,
                        onSelect: navigationCoordinator.openPlayback
                    )
                }
            } label: {
                Label("热门", systemImage: "flame")
            }

            Tab(value: AppTab.history) {
                tabNavigation(path: playbackPathBinding(for: .history)) {
                    HistoryTabRoot(
                        model: historyModel,
                        isSignedIn: authenticationModel.isSignedIn,
                        scrollPosition: $historyScrollPosition,
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
            } label: {
                Label("观看历史", systemImage: "clock.arrow.circlepath")
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarBottomBar {
            accountButton
        }
        .frame(minWidth: 1_080, minHeight: 680)
        .sheet(isPresented: $isAuthenticationPresented) {
            AuthenticationView(model: authenticationModel)
        }
        .onChange(of: submittedSearchQuery) { previousQuery, query in
            guard previousQuery != query else { return }
            searchScrollPosition = ScrollPosition(idType: String.self)
        }
        .onChange(of: authenticationModel.isSignedIn) {
            previousIsSignedIn,
            isSignedIn in
            guard previousIsSignedIn != isSignedIn else { return }
            historyScrollPosition = ScrollPosition(idType: String.self)
        }
    }

    private var accountButton: some View {
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
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func tabNavigation<Content: View>(
        path: Binding<[PlaybackDestination]>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack(path: path) {
            content()
                .navigationDestination(for: PlaybackDestination.self) { _ in
                    PlaybackDestinationView(
                        model: videoModel,
                        subtitleModel: subtitleModel,
                        danmakuModel: danmakuModel,
                        playerContent: playerContent,
                        onRetry: navigationCoordinator.retryPlayback
                    )
                }
        }
    }

    private func playbackPathBinding(
        for tab: AppTab
    ) -> Binding<[PlaybackDestination]> {
        Binding(
            get: {
                navigationCoordinator.playbackPath(for: tab)
            },
            set: { path in
                navigationCoordinator.updatePlaybackPath(path, for: tab)
            }
        )
    }
}

private struct PopularTabRoot: View {
    let model: GuestBrowseViewModel
    @Binding var scrollPosition: ScrollPosition
    let onSelect: (String) -> Void

    var body: some View {
        PopularFeedView(
            model: model,
            scrollPosition: $scrollPosition,
            onSelect: onSelect
        )
        .navigationTitle("热门")
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

private struct SearchTabRoot: View {
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
            placement: .toolbarPrincipal,
            prompt: "搜索 B 站视频"
        )
        .onSubmit(of: .search) {
            onSubmit()
        }
    }
}

private struct HistoryTabRoot: View {
    let model: WatchHistoryViewModel
    let isSignedIn: Bool
    @Binding var scrollPosition: ScrollPosition
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
                scrollPosition: $scrollPosition,
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

private struct PlaybackDestinationView: View {
    let model: GuestVideoViewModel
    let subtitleModel: SubtitleViewModel
    let danmakuModel: DanmakuControlsViewModel
    let playerContent: AnyView
    let onRetry: () -> Void

    var body: some View {
        VideoPlaybackView(
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
    }
}
