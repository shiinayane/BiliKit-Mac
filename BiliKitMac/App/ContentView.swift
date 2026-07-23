//
//  ContentView.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import SwiftUI

struct ContentView: View {
    @State private var navigationModel: AppNavigationModel
    @State private var feedModel: GuestFeedViewModel
    @State private var videoModel: GuestVideoViewModel
    @State private var subtitleModel: SubtitleViewModel
    @State private var danmakuModel: DanmakuControlsViewModel
    @State private var authenticationModel: AuthenticationViewModel
    @State private var historyModel: WatchHistoryViewModel
    @State private var isAuthenticationPresented = false
    @State private var submittedQuery: String?
    @State private var searchRevision = 0
    private let playerContent: AnyView

    init(environment: AppEnvironment = .live()) {
        let feedModel = environment.makeFeedViewModel()
        let videoModel = environment.makeVideoViewModel()
        let subtitleModel = environment.makeSubtitleViewModel()
        let danmakuModel = environment.makeDanmakuViewModel()

        _feedModel = State(initialValue: feedModel)
        _videoModel = State(initialValue: videoModel)
        _subtitleModel = State(initialValue: subtitleModel)
        _danmakuModel = State(initialValue: danmakuModel)
        _navigationModel = State(
            initialValue: AppNavigationModel(
                startPlayback: { bvid in
                    videoModel.selectVideo(bvid)
                },
                stopPlayback: {
                    videoModel.reset()
                    subtitleModel.reset()
                    danmakuModel.reset()
                }
            )
        )
        _authenticationModel = State(
            initialValue: environment.makeAuthenticationViewModel()
        )
        _historyModel = State(
            initialValue: environment.makeWatchHistoryViewModel()
        )
        playerContent = environment.makePlayerView(
            subtitleModel: subtitleModel
        )
    }

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
        .task(id: feedTaskID) {
            await loadFeed(for: feedTaskID)
        }
        .task {
            authenticationModel.restoreIfNeeded()
            await authenticationModel.waitForCurrentTask()
        }
        .onChange(of: authenticationModel.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                subtitleModel.retry()
                return
            }
            historyModel.reset()
            navigationModel.authenticationDidBecomeSignedOut()
            subtitleModel.reset()
        }
        .onChange(of: navigationModel.searchQuery) { _, query in
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return
            }
            submittedQuery = nil
            searchRevision += 1
        }
        .onDisappear {
            navigationModel.closeWindow()
            feedModel.cancel()
            authenticationModel.cancelTransientWork()
            historyModel.reset()
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
            .accessibilityIdentifier("sidebar.account")
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    }

    @ViewBuilder
    private var routeContent: some View {
        switch navigationModel.route {
        case .section(.popular):
            PopularFeedView(
                model: feedModel,
                selectedBVID: selectedBVID(for: .popular),
                onSelect: navigationModel.openPlayback
            )
        case .section(.search):
            VideoSearchView(
                model: feedModel,
                selectedBVID: selectedBVID(for: .search),
                onSelect: navigationModel.openPlayback
            )
            .toolbar {
                ToolbarItem(placement: .principal) {
                    CenteredSearchField(
                        text: $navigationModel.searchQuery,
                        placeholder: "搜索 B 站视频",
                        onSubmit: performSearch
                    )
                    .frame(width: 340)
                    .accessibilityIdentifier("search.field")
                }
            }
        case .section(.history):
            historyContent
        case .playback:
            VideoDetailColumn(
                model: videoModel,
                subtitleModel: subtitleModel,
                danmakuModel: danmakuModel,
                onRetry: navigationModel.retryPlayback
            ) {
                playerContent
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        navigationModel.returnFromPlayback()
                    } label: {
                        Label("返回", systemImage: "chevron.backward")
                    }
                    .accessibilityIdentifier("playback.back")
                }
            }
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if authenticationModel.isSignedIn {
            WatchHistoryView(
                model: historyModel,
                onSelect: navigationModel.openPlayback,
                onAuthenticationRequired: {
                    historyModel.reset()
                    authenticationModel.revalidate()
                }
            )
        } else {
            ContentUnavailableView {
                Label("登录后查看观看历史", systemImage: "person.crop.circle")
            } description: {
                Text("观看历史只在登录期间加载，不会保存到本机。")
            } actions: {
                Button("登录") {
                    isAuthenticationPresented = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("history.login")
            }
            .accessibilityIdentifier("history.signed-out")
        }
    }

    private var selectedSectionBinding: Binding<AppSection?> {
        Binding(
            get: { navigationModel.selectedSection },
            set: { navigationModel.selectedSection = $0 }
        )
    }

    private func selectedBVID(for section: AppSection) -> String? {
        guard navigationModel.returnSnapshot?.sourceSection == section else {
            return nil
        }
        return navigationModel.returnSnapshot?.selectedBVID
    }

    private var normalizedSearchQuery: String {
        navigationModel.searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func performSearch() {
        guard !normalizedSearchQuery.isEmpty else { return }
        navigationModel.searchQuery = normalizedSearchQuery
        submittedQuery = normalizedSearchQuery
        searchRevision += 1
    }

    private var feedTaskID: AppFeedTaskID {
        let sourceSection: AppSection?
        switch navigationModel.route {
        case let .section(section):
            sourceSection = section
        case .playback:
            sourceSection = navigationModel.returnSnapshot?.sourceSection
        }

        switch sourceSection {
        case .popular:
            return .popular
        case .search:
            return .search(
                query: submittedQuery,
                revision: searchRevision
            )
        case .history, nil:
            return .none
        }
    }

    private func loadFeed(for intent: AppFeedTaskID) async {
        switch intent {
        case .popular:
            feedModel.loadPopular()
            await feedModel.waitForCurrentTask()
        case .search(nil, _), .none:
            feedModel.cancel()
        case let .search(.some(query), _):
            feedModel.search(query)
            await feedModel.waitForCurrentTask()
        }
    }
}

private enum AppFeedTaskID: Hashable {
    case popular
    case search(query: String?, revision: Int)
    case none
}

#Preview {
    ContentView()
}
