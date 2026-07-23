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
        let navigationModel = AppNavigationModel(
            startPlayback: { bvid in
                videoModel.selectVideo(bvid)
            },
            stopPlayback: {
                videoModel.reset()
                subtitleModel.reset()
                danmakuModel.reset()
            }
        )

        self.init(
            navigationModel: navigationModel,
            feedModel: feedModel,
            videoModel: videoModel,
            subtitleModel: subtitleModel,
            danmakuModel: danmakuModel,
            authenticationModel: environment.makeAuthenticationViewModel(),
            historyModel: environment.makeWatchHistoryViewModel(),
            playerContent: environment.makePlayerView(
                subtitleModel: subtitleModel
            )
        )
    }

    init(
        navigationModel: AppNavigationModel,
        feedModel: GuestFeedViewModel,
        videoModel: GuestVideoViewModel,
        subtitleModel: SubtitleViewModel,
        danmakuModel: DanmakuControlsViewModel,
        authenticationModel: AuthenticationViewModel,
        historyModel: WatchHistoryViewModel,
        playerContent: AnyView
    ) {
        _navigationModel = State(initialValue: navigationModel)
        _feedModel = State(initialValue: feedModel)
        _videoModel = State(initialValue: videoModel)
        _subtitleModel = State(initialValue: subtitleModel)
        _danmakuModel = State(initialValue: danmakuModel)
        _authenticationModel = State(initialValue: authenticationModel)
        _historyModel = State(initialValue: historyModel)
        self.playerContent = playerContent
    }

    var body: some View {
        AppShellView(
            navigationModel: navigationModel,
            feedModel: feedModel,
            videoModel: videoModel,
            subtitleModel: subtitleModel,
            danmakuModel: danmakuModel,
            authenticationModel: authenticationModel,
            historyModel: historyModel,
            playerContent: playerContent,
            isAuthenticationPresented: $isAuthenticationPresented,
            onSubmitSearch: performSearch
        )
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
            feedModel.loadPopular(pageSize: 50)
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
