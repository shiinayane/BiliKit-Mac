//
//  AppRootView.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import SwiftUI

struct AppRootView: View {
    @State private var navigationCoordinator: AppNavigationCoordinator
    @State private var browseModel: GuestBrowseViewModel
    @State private var videoModel: GuestVideoViewModel
    @State private var subtitleModel: SubtitleViewModel
    @State private var danmakuModel: DanmakuControlsViewModel
    @State private var authenticationModel: AuthenticationViewModel
    @State private var historyModel: WatchHistoryViewModel
    @State private var isAuthenticationPresented = false
    @State private var submittedSearchQuery: String?
    private let playerContent: AnyView

    init(environment: AppEnvironment = .live()) {
        let browseModel = environment.makeBrowseViewModel()
        let videoModel = environment.makeVideoViewModel()
        let subtitleModel = environment.makeSubtitleViewModel()
        let danmakuModel = environment.makeDanmakuViewModel()
        let navigationCoordinator = AppNavigationCoordinator(
            startPlayback: { bvid in
                videoModel.loadVideo(bvid)
            },
            stopPlayback: {
                videoModel.reset()
                subtitleModel.reset()
                danmakuModel.reset()
            }
        )

        self.init(
            navigationCoordinator: navigationCoordinator,
            browseModel: browseModel,
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
        navigationCoordinator: AppNavigationCoordinator,
        browseModel: GuestBrowseViewModel,
        videoModel: GuestVideoViewModel,
        subtitleModel: SubtitleViewModel,
        danmakuModel: DanmakuControlsViewModel,
        authenticationModel: AuthenticationViewModel,
        historyModel: WatchHistoryViewModel,
        playerContent: AnyView
    ) {
        _navigationCoordinator = State(initialValue: navigationCoordinator)
        _browseModel = State(initialValue: browseModel)
        _videoModel = State(initialValue: videoModel)
        _subtitleModel = State(initialValue: subtitleModel)
        _danmakuModel = State(initialValue: danmakuModel)
        _authenticationModel = State(initialValue: authenticationModel)
        _historyModel = State(initialValue: historyModel)
        self.playerContent = playerContent
    }

    var body: some View {
        AppShellView(
            navigationCoordinator: navigationCoordinator,
            browseModel: browseModel,
            videoModel: videoModel,
            subtitleModel: subtitleModel,
            danmakuModel: danmakuModel,
            authenticationModel: authenticationModel,
            historyModel: historyModel,
            playerContent: playerContent,
            isAuthenticationPresented: $isAuthenticationPresented,
            submittedSearchQuery: submittedSearchQuery,
            onSubmitSearch: performSearch
        )
        .task(id: browseActivation) {
            await applyBrowseActivation(for: browseActivation)
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
            subtitleModel.suspendForAuthentication()
        }
        .onChange(of: navigationCoordinator.searchDraft) { _, query in
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return
            }
            submittedSearchQuery = nil
        }
        .onDisappear {
            navigationCoordinator.resetForWindowClosure()
            browseModel.reset()
            authenticationModel.cancelTransientWork()
            historyModel.reset()
        }
    }

    private var normalizedSearchDraft: String {
        navigationCoordinator.searchDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func performSearch() {
        guard !normalizedSearchDraft.isEmpty else { return }
        navigationCoordinator.searchDraft = normalizedSearchDraft
        submittedSearchQuery = normalizedSearchDraft
        browseModel.search(normalizedSearchDraft)
    }

    private var browseActivation: BrowseActivation {
        switch navigationCoordinator.selectedTab {
        case .popular:
            return .popular
        case .search:
            return .search(query: submittedSearchQuery)
        case .history:
            return .inactive
        }
    }

    private func applyBrowseActivation(
        for activation: BrowseActivation
    ) async {
        switch activation {
        case .popular:
            browseModel.activatePopular(pageSize: 50)
            await browseModel.waitForCurrentTask()
        case .search(nil), .inactive:
            browseModel.deactivateRoute()
        case .search(.some(let query)):
            browseModel.activateSearch(query)
            await browseModel.waitForCurrentTask()
        }
    }
}

private enum BrowseActivation: Hashable {
    case popular
    case search(query: String?)
    case inactive
}

#Preview {
    AppRootView()
}
