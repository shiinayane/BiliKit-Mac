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
        TabView(selection: selectedSectionBinding) {
            Tab(value: AppSection.search) {
                sectionNavigation(for: .search) {
                    SearchPageRoot(
                        model: feedModel,
                        query: searchQueryBinding,
                        submittedQuery: submittedSearchQuery,
                        scrollPosition: $searchScrollPosition,
                        onSelect: navigationModel.openPlayback,
                        onSubmit: onSubmitSearch
                    )
                }
            } label: {
                Label("搜索", systemImage: "magnifyingglass")
            }

            Tab(value: AppSection.popular) {
                sectionNavigation(for: .popular) {
                    PopularPageRoot(
                        model: feedModel,
                        scrollPosition: $popularScrollPosition,
                        onSelect: navigationModel.openPlayback
                    )
                }
            } label: {
                Label("热门", systemImage: "flame")
            }

            Tab(value: AppSection.history) {
                sectionNavigation(for: .history) {
                    HistoryPageRoot(
                        model: historyModel,
                        isSignedIn: authenticationModel.isSignedIn,
                        scrollPosition: $historyScrollPosition,
                        onSelect: navigationModel.openPlayback,
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

    private func sectionNavigation<Content: View>(
        for section: AppSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack(path: playbackPathBinding(for: section)) {
            content()
                .navigationDestination(for: PlaybackDestination.self) { _ in
                    PlaybackPageRoot(
                        model: videoModel,
                        subtitleModel: subtitleModel,
                        danmakuModel: danmakuModel,
                        playerContent: playerContent,
                        onRetry: navigationModel.retryPlayback
                    )
                }
        }
    }

    private var selectedSectionBinding: Binding<AppSection> {
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

    private func playbackPathBinding(
        for section: AppSection
    ) -> Binding<[PlaybackDestination]> {
        Binding(
            get: {
                navigationModel.selectedSection == section
                    ? navigationModel.playbackPath
                    : []
            },
            set: { path in
                guard navigationModel.selectedSection == section else {
                    return
                }
                navigationModel.playbackPath = path
            }
        )
    }
}

private struct PopularPageRoot: View {
    let model: GuestFeedViewModel
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

private struct SearchPageRoot: View {
    let model: GuestFeedViewModel
    @Binding var query: String
    let submittedQuery: String?
    @Binding var scrollPosition: ScrollPosition
    let onSelect: (String) -> Void
    let onSubmit: () -> Void

    var body: some View {
        VideoSearchView(
            model: model,
            submittedQuery: submittedQuery,
            scrollPosition: $scrollPosition,
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

private struct PlaybackPageRoot: View {
    @Environment(\.dismiss) private var dismiss

    let model: GuestVideoViewModel
    let subtitleModel: SubtitleViewModel
    let danmakuModel: DanmakuControlsViewModel
    let playerContent: AnyView
    let onRetry: () -> Void

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
        .onExitCommand {
            dismiss()
        }
    }
}
