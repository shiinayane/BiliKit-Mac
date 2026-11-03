import AppKit
import BiliApplication
import BiliAuthFeature
import BiliModels
import BiliVideoDetailFeature
import CoreGraphics
import Foundation
import SwiftUI

@testable import BiliKit

/// 窗口组装的测试替身与 `makeTestAdapters`：测试窗口与生产走同一个 `WindowComposition`，只把 adapter 换成这些替身。

/// 评论 port 的唯一测试替身：记录请求的 subject；`rootError` 让根评论请求失败。
actor CommentRepositoryStub: CommentRepository {
    private let rootError: CommentReadError?
    private var subjects: [CommentSubjectIdentity] = []
    private var requestWaiters = CountWaiters()

    init(rootError: CommentReadError? = nil) {
        self.rootError = rootError
    }

    func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) async throws -> CommentRootPage {
        subjects.append(subject)
        requestWaiters.resume(reaching: subjects.count)
        if let rootError { throw rootError }
        return CommentRootPage(
            threads: [],
            totalCount: 0,
            continuation: nil,
            isEnd: true
        )
    }

    func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) async throws -> CommentReplyPage {
        if let rootError { throw rootError }
        return CommentReplyPage(
            rootID: rootID,
            replies: [],
            pageNumber: page,
            pageSize: pageSize,
            totalCount: 0
        )
    }

    func dialog(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        dialogID: CommentID,
        fromFloor: Int?,
        pageSize: Int
    ) async throws -> CommentDialogPage {
        if let rootError { throw rootError }
        return CommentDialogPage(rootID: rootID, dialogID: dialogID, replies: [], nextFloor: nil)
    }

    func requestedSubjects() -> [CommentSubjectIdentity] {
        subjects
    }

    func waitForRequestCount(_ target: Int) async {
        await withCheckedContinuation {
            requestWaiters.add($0, until: target, current: subjects.count)
        }
    }
}

/// 弹幕呈现 port 的唯一测试替身：记录开始与停止。
@MainActor
final class RecordingDanmakuPresentation: DanmakuSessionControlling {
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCount = 0
    private var startWaiters = CountWaiters()
    private var stopWaiters = CountWaiters()

    func start(for identity: PlaybackItemIdentity) {
        startedIdentities.append(identity)
        startWaiters.resume(reaching: startedIdentities.count)
    }

    func setEnabled(_ enabled: Bool) {}
    func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {}
    func setOpacity(_ opacity: DanmakuOpacity) {}
    func setDisplayArea(_ displayArea: DanmakuDisplayArea) {}
    func setDensity(_ density: DanmakuDensity) {}
    func setMergesDuplicates(_ merges: Bool) {}
    func setModeVisibility(scrolling: Bool, top: Bool, bottom: Bool) {}
    func setAuthenticationInvalidationHandler(_ handler: @escaping @MainActor () -> Void) {}

    func stop() {
        stopCount += 1
        stopWaiters.resume(reaching: stopCount)
    }

    func waitForStartedCount(_ target: Int) async {
        await withCheckedContinuation {
            startWaiters.add($0, until: target, current: startedIdentities.count)
        }
    }

    func waitForStopCount(_ target: Int) async {
        await withCheckedContinuation {
            stopWaiters.add($0, until: target, current: stopCount)
        }
    }
}

/// 认证服务的唯一测试替身：恢复返回可设的状态，可让首次恢复挂起到测试放行；登录与登出恒为未登录。
actor AuthenticationServiceStub: AuthenticationServicing {
    private var restoreState: AuthenticationState
    private let blocksFirstRestore: Bool
    private var restoreCount = 0
    private var firstRestoreStarted = false
    private var firstRestoreReleased = false
    private var restoreStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var restoreReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var restoreCountWaiters = CountWaiters()

    init(
        restoreState: AuthenticationState,
        blocksFirstRestore: Bool = false
    ) {
        self.restoreState = restoreState
        self.blocksFirstRestore = blocksFirstRestore
    }

    func setRestoreState(_ state: AuthenticationState) {
        restoreState = state
    }

    func restoreCallCount() -> Int {
        restoreCount
    }

    func restore() async -> AuthenticationState {
        restoreCount += 1
        restoreCountWaiters.resume(reaching: restoreCount)
        if blocksFirstRestore, restoreCount == 1 {
            firstRestoreStarted = true
            restoreStartWaiters.resumeAll()
            await withCheckedContinuation { continuation in
                if firstRestoreReleased {
                    continuation.resume()
                } else {
                    restoreReleaseWaiters.append(continuation)
                }
            }
        }
        return restoreState
    }

    func waitForFirstRestoreStart() async throws {
        if firstRestoreStarted { return }
        await withCheckedContinuation { continuation in
            restoreStartWaiters.append(continuation)
        }
    }

    func waitForRestoreCallCount(_ target: Int) async {
        await withCheckedContinuation {
            restoreCountWaiters.add($0, until: target, current: restoreCount)
        }
    }

    func releaseFirstRestore() {
        firstRestoreReleased = true
        restoreReleaseWaiters.resumeAll()
    }

    func restoreAfterExternalSessionChange() async -> AuthenticationState { await restore() }
    func requestQRCode() async -> AuthenticationState { .signedOut }
    func pollOnce() async -> AuthenticationState { .signedOut }
    func finalizeLogin() async -> AuthenticationState { .signedOut }
    func cancelLogin() async -> AuthenticationState { .signedOut }
    func logout() async -> AuthenticationState { .signedOut }
}

/// 观看进度连接的探针：记录开始、停止与上报权限。
@MainActor
final class WatchProgressConnectionProbe {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var accessValues: [Bool] = []

    var connection: WatchProgressWindowConnection {
        WatchProgressWindowConnection(
            start: { [weak self] in self?.startCount += 1 },
            stop: { [weak self] in self?.stopCount += 1 },
            setReportingAccess: { [weak self] in self?.accessValues.append($0) }
        )
    }
}

/// 二维码 port 的唯一测试替身：不生成图像。
struct EmptyQRCodeProvider: AuthenticationQRCodeProviding {
    func makeQRCodeImage(scale: Int) async throws -> CGImage? { nil }
}

/// 热搜 port 的唯一测试替身：恒为空。
struct EmptyTrendingSearchRepository: TrendingSearchRepository {
    func trendingSearchKeywords(limit: Int) async throws -> [TrendingSearchKeyword] { [] }
}

/// 搜索联想 port 的唯一测试替身：恒为空。
struct EmptySearchSuggestionRepository: SearchSuggestionRepository {
    func searchSuggestions(for term: String) async throws -> [String] { [] }
}

/// 弹幕偏好的唯一测试替身：读取默认值，写入丢弃。
final class DefaultDanmakuPreferencesStore: DanmakuPreferencesStoring {
    func load() -> DanmakuPreferences { .defaults }
    func saveSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {}
    func saveOpacity(_ opacity: DanmakuOpacity) {}
    func saveDisplayArea(_ displayArea: DanmakuDisplayArea) {}
    func saveDensity(_ density: DanmakuDensity) {}
    func saveMergesDuplicates(_ merges: Bool) {}
}

extension SystemNowPlayingPlaybackConnection {
    /// 没有播放器的连接：时间线恒为空闲、不推送更新，系统命令一律不执行。
    static var idle: SystemNowPlayingPlaybackConnection {
        SystemNowPlayingPlaybackConnection(
            currentSnapshot: { .idle },
            timelineUpdates: { AsyncStream { $0.finish() } },
            currentItemIdentifier: { nil },
            currentDefaultPlaybackRate: { 1 },
            observeDefaultPlaybackRate: { _ in SystemNowPlayingDefaultRateObservation {} },
            perform: { _, _, _ in false }
        )
    }
}

/// 测试窗口的 adapter：与生产同一个 `WindowAdapters`，默认全部是不碰网络、系统播放器与真实偏好的替身，
/// 测试只替换自己要观察的那几个。
@MainActor
func makeTestAdapters(
    video: any VideoRepository = FixtureVideoRepository(fixtures: []),
    uploaderProfile: any UploaderProfileRepository = UploaderProfileRepositoryStub(
        holdsRequests: false
    ),
    comments: any CommentRepository = CommentRepositoryStub(),
    favorites: any FavoritesRepository = FavoritesRepositoryStub(),
    watchLater: any WatchLaterRepository = WatchLaterRepositoryStub(),
    watchLaterWrite: any WatchLaterWriteRepository = AccountWriteRepositoryStub(),
    favoritesWrite: any FavoritesWriteRepository = AccountWriteRepositoryStub(),
    videoEngagement: any VideoEngagementRepository = AccountWriteRepositoryStub(),
    recommendationFeedback: any RecommendationFeedbackRepository = AccountWriteRepositoryStub(),
    authentication: any AuthenticationServicing = AuthenticationServiceStub(
        restoreState: .signedOut
    ),
    playback: any PlaybackControlling = RecordingPlayback(),
    watchProgress: WatchProgressWindowConnection = WatchProgressWindowConnection(
        start: {},
        stop: {},
        setReportingAccess: { _ in }
    ),
    open: @escaping @MainActor () -> Void = {},
    close: @escaping @MainActor () -> Void = {}
) -> WindowAdapters {
    WindowAdapters(
        feedRepository: FeedRepositoryStub(),
        videoRepository: video,
        relatedVideoRepository: EmptyRelatedVideoRepository(),
        trendingSearchRepository: EmptyTrendingSearchRepository(),
        searchSuggestionRepository: EmptySearchSuggestionRepository(),
        uploaderProfileRepository: uploaderProfile,
        uploaderVideoRepository: UnavailableUploaderVideoRepository(),
        commentRepository: comments,
        historyRepository: WatchHistoryRepositoryStub(),
        watchLaterRepository: watchLater,
        watchLaterWriteRepository: watchLaterWrite,
        favoritesRepository: favorites,
        favoritesWriteRepository: favoritesWrite,
        videoEngagementRepository: videoEngagement,
        recommendationFeedbackRepository: recommendationFeedback,
        commentAssetURLResolver: { _, _ in nil },
        commentLinkRouter: { _ in nil },
        authenticationService: authentication,
        authenticationQRCodeProvider: EmptyQRCodeProvider(),
        playback: playback,
        makePlaybackAuthenticationInvalidations: { AsyncStream { $0.finish() } },
        danmakuPresentation: RecordingDanmakuPresentation(),
        danmakuPreferences: DefaultDanmakuPreferencesStore(),
        makePlayerContent: { _, _, _, _ in AnyView(EmptyView()) },
        seekPlayback: { _, _ in },
        nowPlayingConnection: .idle,
        makeWatchProgressConnection: { _ in watchProgress },
        open: open,
        close: close,
        synchronizeSignedOutConfirmation: { _ in }
    )
}

/// 账户写入测试的窗口：账户 7 已登录并确认，稍后再看、收藏与播放页互动的写入都经 `writes`；窗口已打开，调用方负责关闭。
@MainActor
func signedInWindow(
    process: ProcessComposition,
    video: any VideoRepository = FixtureVideoRepository(fixtures: []),
    writes: AccountWriteRepositoryStub = AccountWriteRepositoryStub(),
    watchLater bvids: [String] = [],
    favorites: FavoritesRepositoryStub = FavoritesRepositoryStub()
) async throws -> WindowComposition {
    let window = WindowComposition(
        process: process,
        adapters: makeTestAdapters(
            video: video,
            favorites: favorites,
            watchLater: WatchLaterRepositoryStub(bvids: bvids),
            watchLaterWrite: writes,
            favoritesWrite: writes,
            videoEngagement: writes,
            authentication: AuthenticationServiceStub(
                restoreState: .signedIn(
                    AccountIdentity(id: 7, displayName: "账号", avatarURL: nil)
                )
            )
        )
    )
    window.authenticationModel.restoreIfNeeded()
    await window.authenticationModel.waitForCurrentTask()
    window.open()
    return window
}

/// 给播放页一个 `BV17x411w7KC` 的视频详情（UP 主为 `ownerID`）并等互动状态读到。
@MainActor
func presentEngagement(in window: WindowComposition, ownerID: Int64 = 1) async {
    window.engagementModel.present(
        VideoDetail(
            bvid: "BV17x411w7KC",
            title: "标题",
            summary: "",
            coverURL: nil,
            owner: VideoOwner(id: ownerID, name: "作者"),
            statistics: VideoStatistics(viewCount: 1, danmakuCount: 1, likeCount: 1),
            durationSeconds: 60,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    )
    await waitForObservedState { window.engagementModel.engagement != nil }
}
