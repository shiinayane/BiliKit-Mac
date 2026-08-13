import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import SwiftUI

/// 描述窗口的原生 NavigationSplitView/NavigationStack 外壳，并保留来源状态与滚动位置。
///
/// 系统返回通过 path Binding 回写 coordinator，使播放停止与视觉导航保持同一事实来源；
/// SwiftUI `body` 与普通样式 modifier 不承担资源生命周期。
struct AppShellView: View {
    let navigationCoordinator: AppNavigationCoordinator
    let browseModel: GuestBrowseViewModel
    let videoModel: GuestVideoViewModel
    let danmakuModel: DanmakuControlsViewModel
    let authenticationModel: AuthenticationViewModel
    let historyModel: WatchHistoryViewModel
    let playerContent: AnyView
    @Binding var isAuthenticationPresented: Bool
    let submittedSearchQuery: String?
    let onSubmitSearch: () -> Void
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var popularScrollOffsetY: CGFloat = 0
    @State private var searchScrollOffsetY: CGFloat = 0
    @State private var historyScrollOffsetY: CGFloat = 0
    @State private var popularScrollReset = NativeVideoGridScrollResetState()
    @State private var searchScrollReset = NativeVideoGridScrollResetState()
    @State private var historyScrollReset = NativeVideoGridScrollResetState()

    var body: some View {
        @Bindable var navigationCoordinator = navigationCoordinator

        NavigationSplitView(columnVisibility: $columnVisibility) {
            Group {
                if let playbackBVID = navigationCoordinator.currentPlaybackBVID {
                    playbackSidebar(for: playbackBVID)
                } else {
                    AppNavigationSidebar(
                        selection: $navigationCoordinator.selectedTab,
                        accountState: authenticationModel.accountPresentationState,
                        onPresentAuthentication: {
                            isAuthenticationPresented = true
                        }
                    )
                }
            }
            .id(sidebarContextID)
            .navigationSplitViewColumnWidth(
                min: sidebarMinimumWidth,
                ideal: sidebarIdealWidth,
                max: sidebarMaximumWidth
            )
        } detail: {
            NavigationStack(path: $navigationCoordinator.playbackPath) {
                selectedSourceRoot
                    .navigationDestination(
                        for: PlaybackDestination.self
                    ) { _ in
                        PlaybackDestinationView(
                            model: videoModel,
                            danmakuModel: danmakuModel,
                            playerContent: playerContent,
                            onRetry: navigationCoordinator.retryPlayback,
                            onSelectRelatedVideo:
                                navigationCoordinator.openPlayback
                        )
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
        .sheet(isPresented: $isAuthenticationPresented) {
            AuthenticationView(model: authenticationModel)
        }
        .onChange(of: submittedSearchQuery) { previousQuery, query in
            guard previousQuery != query else { return }
            searchScrollOffsetY = 0
            searchScrollReset.request()
        }
        .onChange(of: browseModel.popularSuccessfulRefreshGeneration) {
            previousGeneration,
            generation in
            guard previousGeneration != generation else { return }
            popularScrollOffsetY = 0
            popularScrollReset.request()
        }
        .onChange(of: browseModel.searchSuccessfulRefreshGeneration) {
            previousGeneration,
            generation in
            guard previousGeneration != generation else { return }
            searchScrollOffsetY = 0
            searchScrollReset.request()
        }
        .onChange(of: historyModel.successfulReloadGeneration) {
            previousGeneration,
            generation in
            guard previousGeneration != generation else { return }
            historyScrollOffsetY = 0
            historyScrollReset.request()
        }
        .onChange(of: historyAccountScope) { previousScope, scope in
            guard AccountSessionScope.isResolvedChange(from: previousScope, to: scope)
            else {
                return
            }
            historyScrollOffsetY = 0
            historyScrollReset.request()
        }
    }

    private var sidebarContextID: String {
        navigationCoordinator.currentPlaybackBVID == nil
            ? "navigation"
            : "playback"
    }

    private var historyAccountScope: AccountSessionScope {
        authenticationModel.sessionScope
    }

    @ViewBuilder
    private func playbackSidebar(for bvid: String) -> some View {
        PlaybackContextSidebar(
            model: videoModel,
            onRetry: navigationCoordinator.retryPlayback
        )
    }

    private var sidebarMinimumWidth: CGFloat {
        navigationCoordinator.currentPlaybackBVID == nil ? 300 : 320
    }

    private var sidebarIdealWidth: CGFloat {
        navigationCoordinator.currentPlaybackBVID == nil ? 320 : 360
    }

    private var sidebarMaximumWidth: CGFloat {
        navigationCoordinator.currentPlaybackBVID == nil ? 320 : 440
    }

    @ViewBuilder
    private var selectedSourceRoot: some View {
        switch navigationCoordinator.selectedTab {
        case .search:
            SearchTabRoot(
                model: browseModel,
                searchDraft: Binding(
                    get: { navigationCoordinator.searchDraft },
                    set: { navigationCoordinator.searchDraft = $0 }
                ),
                submittedSearchQuery: submittedSearchQuery,
                scrollOffsetY: $searchScrollOffsetY,
                scrollReset: $searchScrollReset,
                onSelect: navigationCoordinator.openPlayback,
                onSubmit: onSubmitSearch
            )
        case .popular:
            PopularTabRoot(
                model: browseModel,
                scrollOffsetY: $popularScrollOffsetY,
                scrollReset: $popularScrollReset,
                onSelect: navigationCoordinator.openPlayback
            )
        case .history:
            HistoryTabRoot(
                model: historyModel,
                accountState: authenticationModel.accountPresentationState,
                scrollOffsetY: $historyScrollOffsetY,
                scrollReset: $historyScrollReset,
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
    }
}

private struct PlaybackDestinationView: View {
    let model: GuestVideoViewModel
    let danmakuModel: DanmakuControlsViewModel
    let playerContent: AnyView
    let onRetry: () -> Void
    let onSelectRelatedVideo: (String) -> Void

    var body: some View {
        VideoPlaybackView(
            model: model,
            danmakuModel: danmakuModel,
            onRetry: onRetry,
            onSelectRelatedVideo: onSelectRelatedVideo
        ) {
            playerContent
        }
        .navigationTitle("播放")
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}
