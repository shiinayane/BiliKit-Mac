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
            searchScrollPosition = ScrollPosition(idType: String.self)
        }
        .onChange(of: authenticationModel.sessionPhase) {
            previousPhase,
            phase in
            guard previousPhase != .unresolved, phase != .unresolved,
                previousPhase != phase
            else {
                return
            }
            historyScrollPosition = ScrollPosition(idType: String.self)
        }
    }

    private var sidebarContextID: String {
        navigationCoordinator.currentPlaybackBVID == nil
            ? "navigation"
            : "playback"
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
                scrollPosition: $searchScrollPosition,
                onSelect: navigationCoordinator.openPlayback,
                onSubmit: onSubmitSearch
            )
        case .popular:
            PopularTabRoot(
                model: browseModel,
                scrollPosition: $popularScrollPosition,
                onSelect: navigationCoordinator.openPlayback
            )
        case .history:
            HistoryTabRoot(
                model: historyModel,
                accountState: authenticationModel.accountPresentationState,
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
