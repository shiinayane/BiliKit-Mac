//
//  AppRootView.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import BiliVideoDetailFeature
import Combine
import SwiftUI

/// 窗口级生命周期入口，连接导航激活、认证变化与窗口的打开与关闭。
///
/// 页面 View 只表达局部意图；窗口对象图（`WindowComposition`）在视图身份首次出现时构造一次，窗口出现时打开、
/// 消失时关闭（关闭顺序见 `WindowComposition.close()`）。
struct AppRootView: View {
    @Environment(\.appearsActive) private var appearsActive
    @StateObject private var windowHolder: WindowCompositionHolder
    @State private var isAuthenticationPresented = false

    /// `window`（`ProcessComposition.makeWindow()` 组装的窗口）只在视图身份首次出现时求值一次。
    init(window: @autoclosure @escaping @MainActor () -> WindowComposition) {
        _windowHolder = StateObject(wrappedValue: WindowCompositionHolder(window()))
    }

    var body: some View {
        AppShellView(
            navigationCoordinator: navigationCoordinator,
            sources: window.sources,
            browseModel: browseModel,
            videoModel: videoModel,
            commentsModel: commentsModel,
            danmakuModel: danmakuModel,
            danmakuComposer: window.danmakuComposer,
            commentWrite: window.commentWrite,
            authenticationModel: authenticationModel,
            watchLaterModel: window.watchLaterModel,
            watchLaterSession: window.watchLaterSession,
            historyModel: historyModel,
            favoriteFolderList: window.favoriteFolderList,
            favoriteFolders: window.favoriteFolders,
            trendingSearchModel: window.trendingSearchModel,
            searchSession: window.searchSession,
            searchHistory: window.process.searchHistory,
            searchSuggestionSource: window.searchSuggestionSource,
            playerContent: playerContent,
            commentAssetURLResolver: window.commentAssetURLResolver,
            commentLinkRouter: window.commentLinkRouter,
            commentShortLinks: window.commentShortLinks,
            commentImagePreview: window.commentImagePreview,
            seekPlayback: window.seekPlayback,
            imagePipeline: window.imagePipeline,
            gridRetainer: window.gridRetainerOwner.retainer,
            accountWrites: window.accountWrites,
            engagementModel: window.engagementModel,
            isAuthenticationPresented: $isAuthenticationPresented
        )
        .task(id: browseActivation) {
            await browseModel.activate(browseActivation)
        }
        .task(id: commentActivationAID) {
            await applyCommentActivation(aid: commentActivationAID)
        }
        .onAppear {
            window.synchronizeWatchProgressAccess(historyAccountScope)
            window.open()
        }
        .onChange(of: appearsActive, initial: true) { _, isActive in
            if isActive {
                window.markWindowActive()
            }
        }
        .task {
            authenticationModel.restoreIfNeeded()
            await authenticationModel.waitForCurrentTask()
            synchronizeBenchmarkAuthentication()
        }
        .onChange(of: authenticationModel.sessionPhase) { _, _ in
            synchronizeBenchmarkAuthentication()
        }
        .onChange(of: authenticationModel.state) { _, _ in
            synchronizeBenchmarkAuthentication()
        }
        .onChange(of: isAccountSignedOutConfirmed, initial: true) { _, isConfirmed in
            window.synchronizeSignedOutConfirmation(isConfirmed)
        }
        .onChange(of: historyAccountScope) { previousScope, scope in
            window.synchronizeWatchProgressAccess(scope)
            guard AccountSessionScope.isResolvedChange(from: previousScope, to: scope)
            else {
                return
            }
            accountSessionCoordinator.publish(scope)
            // 先通知不要求账户的来源（Browse 重启当前路由），关闭播放，再通知要求账户的来源（稍后再看、观看历史与
            // 收藏夹清空并按需重载）；最后，当前来源所在的组在新范围下不再显示（登出时的收藏夹）就回到首页。
            notifyAccountSessionChange(
                generation: accountSessionCoordinator.generation,
                scope: scope,
                requiringAccount: false
            )
            navigationCoordinator.closePlaybackForAuthenticationChange()
            notifyAccountSessionChange(
                generation: accountSessionCoordinator.generation,
                scope: scope,
                requiringAccount: true
            )
            navigationCoordinator.selectedTab = window.sources.route(
                afterAccountChangeFrom: navigationCoordinator.selectedTab,
                scope: scope
            )
        }
        .task(id: accountSessionCoordinator.generation) {
            await synchronizeProcessAccountSession()
        }
        .onChange(of: authenticationModel.resolutionPhase) { previousPhase, phase in
            guard previousPhase == .restoring else { return }
            window.revalidationParticipants.finishRevalidation(
                phase,
                currentRoute: navigationCoordinator.selectedTab
            )
        }
        .onChange(of: navigationCoordinator.selectedTab) { previousTab, _ in
            window.sources[previousTab].deactivate()
        }
        .onChange(of: window.revalidationParticipants.generations) { previous, current in
            guard AccountRevalidationParticipants.requestsRevalidation(from: previous, to: current)
            else { return }
            authenticationModel.revalidate()
        }
        .onDisappear {
            window.close()
        }
    }

    private var window: WindowComposition {
        windowHolder.window
    }

    private var accountSessionCoordinator: AccountSessionCoordinator {
        window.process.accountSession
    }

    private var navigationCoordinator: AppNavigationCoordinator {
        window.navigationCoordinator
    }

    private var browseModel: BrowseViewModel {
        window.browseModel
    }

    private var videoModel: VideoViewModel {
        window.videoModel
    }

    private var commentsModel: PlaybackCommentsViewModel {
        window.commentsModel
    }

    private var danmakuModel: DanmakuControlsViewModel {
        window.danmakuModel
    }

    private var authenticationModel: AuthenticationViewModel {
        window.authenticationModel
    }

    private var historyModel: WatchHistoryViewModel {
        window.historyModel
    }

    private var isAccountSignedOutConfirmed: Bool {
        AccountSignedOutConfirmation.isConfirmed(
            windowScope: authenticationModel.sessionScope,
            resolutionPhase: authenticationModel.resolutionPhase,
            processScope: accountSessionCoordinator.scope
        )
    }

    private var historyAccountScope: AccountSessionScope {
        authenticationModel.sessionScope
    }

    private var playerContent: AnyView {
        window.playerContent
    }

    /// 窗口关闭后 onDisappear 已注销测速 owner；迟到的同步（如恢复登录完成）不得把它登记回去。
    private func synchronizeBenchmarkAuthentication() {
        guard !window.isClosed else { return }
        window.process.settings.synchronizeAuthentication(
            Self.benchmarkAccess(
                sessionPhase: authenticationModel.sessionPhase,
                isSigningOut: authenticationModel.isSigningOut
            ),
            ownerID: window.benchmarkAuthenticationOwnerID
        )
    }

    static func benchmarkAccess(
        sessionPhase: AccountSessionPhase,
        isSigningOut: Bool
    ) -> PlaybackRouteBenchmarkAccess {
        if isSigningOut { return .signedOut }
        return switch sessionPhase {
        case .unresolved: .resolving
        case .signedOut: .signedOut
        case .signedIn: .signedIn
        }
    }

    private var commentActivationAID: Int64? {
        guard let currentBVID = navigationCoordinator.currentPlaybackBVID,
            let videoIdentity = videoModel.presentedVideoIdentity,
            videoIdentity.bvid == currentBVID
        else { return nil }
        return videoIdentity.aid
    }

    /// 当前来源要求的 Browse 工作集；穷尽 switch，新增来源时由编译器要求给出映射。
    private var browseActivation: BrowseActivation {
        switch navigationCoordinator.selectedTab {
        case .home:
            .recommendation
        case .popular:
            .popular
        case .search:
            window.searchSession.browseActivation
        case .watchLater, .history, .favorites:
            .inactive
        }
    }

    private func applyCommentActivation(aid: Int64?) async {
        // 短链属于上一个视频的简介或评论：视频变化时取消在途解析。
        window.commentShortLinks.cancel()
        guard let aid else {
            commentsModel.reset()
            return
        }
        commentsModel.activateVideo(aid: aid)
        await commentsModel.waitForCurrentRootTask()
    }

    /// 其他窗口换号后，让本窗口先复核再按进程代次通知来源。
    ///
    /// 先丢弃要求账户的来源的内容，让本窗口认证 owner 完成凭据复核和 transport 失效，再按进程代次通知不要求
    /// 账户的来源。要求账户的来源由复核得出的范围变化（`historyAccountScope` 的 onChange）重新加载；复核得出的范围不变时
    /// 没有这次变化，由 `WindowComposition.externalSessionRevalidationDidFinish()` 让被提前丢弃的收藏夹列表重新对齐。
    private func synchronizeProcessAccountSession() async {
        let processGeneration = accountSessionCoordinator.generation
        guard accountSessionCoordinator.awaitsRevalidation(ofWindowScope: historyAccountScope)
        else {
            return
        }
        navigationCoordinator.closePlaybackForAuthenticationChange()
        window.sources.resetAccountContent()
        authenticationModel.revalidateAfterExternalSessionChange()
        await authenticationModel.waitForCurrentTask()
        window.externalSessionRevalidationDidFinish()
        guard accountSessionCoordinator.generation == processGeneration else {
            return
        }
        notifyAccountSessionChange(
            generation: processGeneration,
            scope: historyAccountScope,
            requiringAccount: false
        )
    }

    /// 把账户会话变化交给要求账户（或不要求账户）的来源，由来源自己处理。
    private func notifyAccountSessionChange(
        generation: UInt64,
        scope: AccountSessionScope,
        requiringAccount: Bool
    ) {
        for source in window.sources.ordered where source.requiresAccount == requiringAccount {
            source.synchronizeAccountSession(
                AccountSessionChange(
                    generation: generation,
                    scope: scope,
                    isCurrentRoute: source.id == navigationCoordinator.selectedTab
                )
            )
        }
    }
}

/// 让窗口对象图只在视图身份首次出现时创建一次。
///
/// `@StateObject` 的 autoclosure 只求值一次；`State(initialValue:)` 会在父视图每次重算
/// `AppRootView.init` 时构造并丢弃整套对象图（包括 AVPlayer 与 URLSession）。
@MainActor
private final class WindowCompositionHolder: ObservableObject {
    let window: WindowComposition

    init(_ window: WindowComposition) {
        self.window = window
    }
}
