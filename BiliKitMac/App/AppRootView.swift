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

/// 窗口级生命周期入口，连接导航激活、认证变化与最终资源清理。
///
/// 页面 View 只表达局部意图；关窗时需要在这里清除 Browse/History 工作集、认证临时任务，
/// 并借导航路径清空统一停止播放、字幕和弹幕资源。
struct AppRootView: View {
    @State private var windowOwner: AppWindowOwner
    @State private var isAuthenticationPresented = false
    @State private var submittedSearchQuery: String?
    private let playbackSidebarContent:
        (
            (String, @escaping (String) -> Void) -> AnyView
        )?

    init(environment: AppEnvironment = .live()) {
        playbackSidebarContent = nil
        _windowOwner = State(
            initialValue: AppWindowOwner(environment: environment)
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
        playerContent: AnyView,
        playbackSidebarContent: (
            (String, @escaping (String) -> Void) -> AnyView
        )? = nil
    ) {
        self.playbackSidebarContent = playbackSidebarContent
        _windowOwner = State(
            initialValue: AppWindowOwner(
                navigationCoordinator: navigationCoordinator,
                browseModel: browseModel,
                videoModel: videoModel,
                subtitleModel: subtitleModel,
                danmakuModel: danmakuModel,
                authenticationModel: authenticationModel,
                historyModel: historyModel,
                playerContent: playerContent,
                subtitlePresentationMode: .legacyOverlay
            )
        )
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
            subtitlePresentationMode: windowOwner.subtitlePresentationMode,
            isAuthenticationPresented: $isAuthenticationPresented,
            submittedSearchQuery: submittedSearchQuery,
            onSubmitSearch: performSearch,
            playbackSidebarContent: playbackSidebarContent
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
                switch windowOwner.subtitlePresentationMode {
                case .legacyOverlay:
                    subtitleModel.retry()
                case .nativePlayer:
                    navigationCoordinator.retryPlayback()
                }
                return
            }
            navigationCoordinator.closePlaybackForAuthenticationChange()
            historyModel.reset()
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

    private var navigationCoordinator: AppNavigationCoordinator {
        windowOwner.navigationCoordinator
    }

    private var browseModel: GuestBrowseViewModel {
        windowOwner.browseModel
    }

    private var videoModel: GuestVideoViewModel {
        windowOwner.videoModel
    }

    private var subtitleModel: SubtitleViewModel {
        windowOwner.subtitleModel
    }

    private var danmakuModel: DanmakuControlsViewModel {
        windowOwner.danmakuModel
    }

    private var authenticationModel: AuthenticationViewModel {
        windowOwner.authenticationModel
    }

    private var historyModel: WatchHistoryViewModel {
        windowOwner.historyModel
    }

    private var playerContent: AnyView {
        windowOwner.playerContent
    }

    private var normalizedSearchDraft: String {
        navigationCoordinator.searchDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 提交规范化搜索意图；编辑中的 draft 本身不会触发网络请求。
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

    /// 激活当前 Tab 对应的 Browse 工作集并等待当前模型任务；任务所有权与取消仍由 ViewModel 管理。
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
