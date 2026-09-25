//
//  AppRootView.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import Combine
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
    @Environment(\.appearsActive) private var appearsActive
    @StateObject private var windowOwnerHolder: AppWindowOwnerHolder
    private let accountSessionCoordinator: AccountSessionCoordinator
    private let appSettingsModel: AppSettingsModel?
    @State private var isAuthenticationPresented = false
    @State private var searchFilterSelection = SearchFilterSelection()
    @State private var appliedSearchFilters = AppliedVideoSearchFilters()
    @State private var submittedSearchCriteria: VideoSearchCriteria?
    init(
        environment: AppEnvironment? = nil,
        accountSessionCoordinator: AccountSessionCoordinator = AccountSessionCoordinator(),
        systemNowPlayingController: SystemNowPlayingController? = nil,
        appSettingsModel: AppSettingsModel? = nil
    ) {
        self.accountSessionCoordinator = accountSessionCoordinator
        self.appSettingsModel = appSettingsModel
        _windowOwnerHolder = StateObject(
            wrappedValue: AppWindowOwnerHolder(
                AppWindowOwner(
                    environment: environment
                        ?? .live(
                            accountSessionCoordinator: accountSessionCoordinator,
                            appSettingsModel: appSettingsModel
                        ),
                    systemNowPlayingController: systemNowPlayingController
                )
            )
        )
    }

    init(
        navigationCoordinator: AppNavigationCoordinator,
        browseModel: BrowseViewModel,
        videoModel: VideoViewModel,
        commentsModel: PlaybackCommentsViewModel? = nil,
        danmakuModel: DanmakuControlsViewModel,
        authenticationModel: AuthenticationViewModel,
        historyModel: WatchHistoryViewModel,
        playerContent: AnyView,
        commentAssetURLResolver: @escaping CommentAssetURLResolver = { _ in nil },
        commentVideoLinkResolver: @escaping CommentVideoLinkResolver = { _ in nil },
        commentLinkURLResolver: @escaping CommentLinkURLResolver = { _ in nil },
        accountSessionCoordinator: AccountSessionCoordinator = AccountSessionCoordinator(),
        watchProgressConnection: WatchProgressWindowConnection? = nil
    ) {
        self.accountSessionCoordinator = accountSessionCoordinator
        appSettingsModel = nil
        _windowOwnerHolder = StateObject(
            wrappedValue: AppWindowOwnerHolder(
                AppWindowOwner(
                    navigationCoordinator: navigationCoordinator,
                    browseModel: browseModel,
                    videoModel: videoModel,
                    commentsModel: commentsModel,
                    danmakuModel: danmakuModel,
                    authenticationModel: authenticationModel,
                    historyModel: historyModel,
                    playerContent: playerContent,
                    commentAssetURLResolver: commentAssetURLResolver,
                    commentVideoLinkResolver: commentVideoLinkResolver,
                    commentLinkURLResolver: commentLinkURLResolver,
                    watchProgressConnection: watchProgressConnection
                )
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
            commentAssetURLResolver: windowOwner.commentAssetURLResolver,
            commentVideoLinkResolver: windowOwner.commentVideoLinkResolver,
            commentLinkURLResolver: windowOwner.commentLinkURLResolver,
            imagePipeline: windowOwner.imagePipeline,
            isAuthenticationPresented: $isAuthenticationPresented,
            searchFilterSelection: $searchFilterSelection,
            submittedSearchCriteria: submittedSearchCriteria,
            onSubmitSearch: performSearch,
            onSelectSearchOrder: selectSearchOrder,
            onApplySearchFilters: applySearchFilters,
            onClearSearchFilters: clearSearchFilters
        )
        .task(id: browseActivation) {
            await applyBrowseActivation(for: browseActivation)
        }
        .task(id: commentActivationAID) {
            await applyCommentActivation(aid: commentActivationAID)
        }
        .onAppear {
            windowOwner.synchronizeWatchProgressAccess(historyAccountScope)
            windowOwner.open()
        }
        .onChange(of: appearsActive, initial: true) { _, isActive in
            if isActive {
                windowOwner.markWindowActive()
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
        .onChange(of: historyAccountScope) { previousScope, scope in
            windowOwner.synchronizeWatchProgressAccess(scope)
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
        .onChange(of: authenticationRevalidationRequests) { previous, current in
            guard zip(previous, current).contains(where: { $1 > $0 }) else { return }
            authenticationModel.revalidate()
        }
        .onChange(of: navigationCoordinator.searchDraft) { _, query in
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return
            }
            submittedSearchCriteria = nil
        }
        .onDisappear {
            appSettingsModel?.removeAuthenticationOwner(
                windowOwner.benchmarkAuthenticationOwnerID
            )
            navigationCoordinator.resetForWindowClosure()
            browseModel.reset()
            authenticationModel.cancelTransientWork()
            historyModel.reset()
            commentsModel?.reset()
            windowOwner.close()
        }
    }

    private var windowOwner: AppWindowOwner {
        windowOwnerHolder.owner
    }

    private var navigationCoordinator: AppNavigationCoordinator {
        windowOwner.navigationCoordinator
    }

    private var browseModel: BrowseViewModel {
        windowOwner.browseModel
    }

    private var videoModel: VideoViewModel {
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

    private func synchronizeBenchmarkAuthentication() {
        appSettingsModel?.synchronizeAuthentication(
            Self.benchmarkAccess(
                sessionPhase: authenticationModel.sessionPhase,
                isSigningOut: authenticationModel.isSigningOut
            ),
            ownerID: windowOwner.benchmarkAuthenticationOwnerID
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

    /// 各 ViewModel 发现凭据失效时递增自己的计数；任一计数增加都触发一次认证复核。
    private var authenticationRevalidationRequests: [Int] {
        [
            videoModel.authenticationRevalidationGeneration,
            browseModel.authenticationRevalidationGeneration,
            danmakuModel.authenticationRevalidationGeneration,
            commentsModel?.authenticationRevalidationGeneration ?? 0
        ]
    }

    private var normalizedSearchDraft: String {
        navigationCoordinator.searchDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 提交规范化搜索意图；编辑中的 draft 本身不会触发网络请求。
    private func performSearch() {
        guard !normalizedSearchDraft.isEmpty else { return }
        navigationCoordinator.searchDraft = normalizedSearchDraft
        let criteria = appliedSearchFilters.criteria(query: normalizedSearchDraft)
        if submittedSearchCriteria == criteria {
            browseModel.search(criteria)
        } else {
            submittedSearchCriteria = criteria
        }
    }

    private func selectSearchOrder(_ order: VideoSearchOrder) {
        appliedSearchFilters.order = order
        updateSubmittedSearchCriteriaIfNeeded()
    }

    private func applySearchFilters(_ selection: SearchFilterSelection) {
        guard let filters = try? selection.resolvedFilters() else { return }
        appliedSearchFilters = filters
        updateSubmittedSearchCriteriaIfNeeded()
    }

    private func clearSearchFilters() {
        searchFilterSelection.resetFilters()
        appliedSearchFilters.duration = .all
        appliedSearchFilters.publicationRange = nil
        updateSubmittedSearchCriteriaIfNeeded()
    }

    private func updateSubmittedSearchCriteriaIfNeeded() {
        guard let submittedSearchCriteria else { return }
        self.submittedSearchCriteria = appliedSearchFilters.criteria(
            query: submittedSearchCriteria.query
        )
    }

    private var browseActivation: BrowseActivation {
        switch navigationCoordinator.selectedTab {
        case .home:
            return .recommendation
        case .popular:
            return .popular
        case .search:
            return .search(criteria: submittedSearchCriteria)
        case .history:
            return .inactive
        }
    }

    /// 激活当前 Tab 对应的 Browse 工作集并等待当前模型任务；任务所有权与取消仍由 ViewModel 管理。
    private func applyBrowseActivation(
        for activation: BrowseActivation
    ) async {
        switch activation {
        case .recommendation:
            browseModel.activateRecommendation()
            await browseModel.waitForCurrentTask()
        case .popular:
            browseModel.activatePopular(pageSize: BrowseViewModel.popularPageSize)
            await browseModel.waitForCurrentTask()
        case .search(nil), .inactive:
            browseModel.deactivateRoute()
        case .search(.some(let criteria)):
            browseModel.activateSearch(criteria)
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

/// 让窗口对象图只在视图身份首次出现时创建一次。
///
/// `@StateObject` 的 autoclosure 只求值一次；`State(initialValue:)` 会在父视图每次重算
/// `AppRootView.init` 时构造并丢弃整套对象图（包括 AVPlayer 与 URLSession）。
@MainActor
private final class AppWindowOwnerHolder: ObservableObject {
    let owner: AppWindowOwner

    init(_ owner: AppWindowOwner) {
        self.owner = owner
    }
}

private enum BrowseActivation: Hashable {
    case recommendation
    case popular
    case search(criteria: VideoSearchCriteria?)
    case inactive
}

#Preview {
    AppRootView()
}
