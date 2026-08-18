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

enum HistoryRouteOwnership {
    static func deactivatesHistory(from previous: AppTab, to current: AppTab) -> Bool {
        previous == .history && current != .history
    }
}

/// 窗口级生命周期入口，连接导航激活、认证变化与最终资源清理。
///
/// 页面 View 只表达局部意图；关窗时需要在这里清除 Browse/History 工作集、认证临时任务，
/// 并借导航路径清空统一停止播放、原生字幕和弹幕资源。
struct AppRootView: View {
    @State private var windowOwner: AppWindowOwner
    private let accountSessionCoordinator: AccountSessionCoordinator
    @State private var isAuthenticationPresented = false
    @State private var submittedSearchQuery: String?
    init(
        environment: AppEnvironment? = nil,
        accountSessionCoordinator: AccountSessionCoordinator = AccountSessionCoordinator()
    ) {
        self.accountSessionCoordinator = accountSessionCoordinator
        let environment =
            environment
            ?? .live(accountSessionCoordinator: accountSessionCoordinator)
        _windowOwner = State(
            initialValue: AppWindowOwner(environment: environment)
        )
    }

    init(
        navigationCoordinator: AppNavigationCoordinator,
        browseModel: GuestBrowseViewModel,
        videoModel: GuestVideoViewModel,
        commentsModel: PlaybackCommentsViewModel? = nil,
        danmakuModel: DanmakuControlsViewModel,
        authenticationModel: AuthenticationViewModel,
        historyModel: WatchHistoryViewModel,
        playerContent: AnyView,
        accountSessionCoordinator: AccountSessionCoordinator = AccountSessionCoordinator()
    ) {
        self.accountSessionCoordinator = accountSessionCoordinator
        _windowOwner = State(
            initialValue: AppWindowOwner(
                navigationCoordinator: navigationCoordinator,
                browseModel: browseModel,
                videoModel: videoModel,
                commentsModel: commentsModel,
                danmakuModel: danmakuModel,
                authenticationModel: authenticationModel,
                historyModel: historyModel,
                playerContent: playerContent
            )
        )
    }

    var body: some View {
        AppShellView(
            navigationCoordinator: navigationCoordinator,
            browseModel: browseModel,
            videoModel: videoModel,
            commentsModel: commentsModel,
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
        .task(id: commentActivationAID) {
            await applyCommentActivation(aid: commentActivationAID)
        }
        .onAppear {
            windowOwner.open()
        }
        .task {
            authenticationModel.restoreIfNeeded()
            await authenticationModel.waitForCurrentTask()
        }
        .onChange(of: historyAccountScope) { previousScope, scope in
            guard AccountSessionScope.isResolvedChange(from: previousScope, to: scope)
            else {
                return
            }
            accountSessionCoordinator.publish(scope)
            browseModel.synchronizeAuthenticationSession(
                generation: accountSessionCoordinator.generation
            )
            navigationCoordinator.closePlaybackForAuthenticationChange()
            historyModel.reset()
            if case .signedIn = scope,
                navigationCoordinator.selectedTab == .history
            {
                historyModel.loadIfNeeded()
            }
        }
        .task(id: accountSessionCoordinator.generation) {
            await synchronizeProcessAccountSession()
        }
        .onChange(of: authenticationModel.resolutionPhase) { previousPhase, phase in
            guard previousPhase == .restoring,
                navigationCoordinator.selectedTab == .history
            else { return }
            switch phase {
            case .signedIn:
                historyModel.loadIfNeeded()
            case .failed:
                historyModel.reportAuthenticationRevalidationFailure()
            default:
                break
            }
        }
        .onChange(of: navigationCoordinator.selectedTab) { previousTab, tab in
            if HistoryRouteOwnership.deactivatesHistory(from: previousTab, to: tab) {
                historyModel.deactivateRoute()
            }
        }
        .onChange(of: videoModel.authenticationRevalidationGeneration) {
            previousGeneration,
            generation in
            guard generation > previousGeneration else { return }
            authenticationModel.revalidate()
        }
        .onChange(of: danmakuModel.authenticationRevalidationGeneration) {
            previousGeneration,
            generation in
            guard generation > previousGeneration else { return }
            authenticationModel.revalidate()
        }
        .onChange(of: commentAuthenticationRevalidationGeneration) {
            previousGeneration,
            generation in
            guard generation > previousGeneration else { return }
            authenticationModel.revalidate()
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
            commentsModel?.reset()
            windowOwner.close()
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

    private var commentsModel: PlaybackCommentsViewModel? {
        windowOwner.commentsModel
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

    private var historyAccountScope: AccountSessionScope {
        authenticationModel.sessionScope
    }

    private var playerContent: AnyView {
        windowOwner.playerContent
    }

    private var commentActivationAID: Int64? {
        guard let currentBVID = navigationCoordinator.currentPlaybackBVID,
            let videoIdentity = videoModel.presentedVideoIdentity,
            videoIdentity.bvid == currentBVID
        else { return nil }
        return videoIdentity.aid
    }

    private var commentAuthenticationRevalidationGeneration: Int {
        commentsModel?.authenticationRevalidationGeneration ?? 0
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

    private func applyCommentActivation(aid: Int64?) async {
        guard let commentsModel else { return }
        guard let aid else {
            commentsModel.reset()
            return
        }
        commentsModel.activateVideo(aid: aid)
        await commentsModel.waitForCurrentRootTask()
    }

    /// 先让本窗口认证 owner 完成凭据复核和 transport 失效，再重启账户化 Browse 请求。
    private func synchronizeProcessAccountSession() async {
        let processGeneration = accountSessionCoordinator.generation
        guard accountSessionCoordinator.scope != historyAccountScope else {
            return
        }
        navigationCoordinator.closePlaybackForAuthenticationChange()
        historyModel.reset()
        authenticationModel.revalidateAfterExternalSessionChange()
        await authenticationModel.waitForCurrentTask()
        guard accountSessionCoordinator.generation == processGeneration else {
            return
        }
        browseModel.synchronizeAuthenticationSession(
            generation: processGeneration
        )
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
