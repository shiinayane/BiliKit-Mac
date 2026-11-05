import AppKit
import BiliApplication
import BiliDanmaku
import BiliModels
import BiliVideoCollectionUI
import BiliVideoDetailFeature
import Foundation
import MediaPlayer
import Observation
import Synchronization
import Testing

@testable import BiliKit

/// 等待 AppKit 在后续 main actor 回合完成的布局或 diff 应用；只让出执行权，不按固定时长轮询。
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}

/// 等待 `@Observable` 状态满足条件：每次被追踪属性变化后才重新判断，超时由测试的 time limit 兜底。
@MainActor
func waitForObservedState(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                continuation.resume()
            }
        }
    }
}

/// 等到当前视频意图写回终态；内容准备与播放器安装期间的状态都不算完成。
@MainActor
func waitUntilSettled(_ model: VideoViewModel) async {
    await waitForObservedState {
        switch model.state {
        case .idle, .ready, .failed, .failedPage:
            true
        case .loading, .loadingPage, .preparingPlayback:
            false
        }
    }
}

/// 可等待的事件计数：记录端 `record()`，等待端挂起到计数达到目标为止。
actor TestEventCounter {
    private(set) var count = 0
    private var waiters = CountWaiters()

    func record() {
        count += 1
        waiters.resume(reaching: count)
    }

    func wait(untilCount target: Int = 1) async {
        await withCheckedContinuation { waiters.add($0, until: target, current: count) }
    }
}

/// 由持有者在自己的隔离域内同步使用的计数等待表；计数本身由持有者保存与推进。
struct CountWaiters {
    private var pending: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// `current` 已达到 `target` 时立即恢复，否则登记到 `resume(reaching:)`。
    mutating func add(
        _ continuation: CheckedContinuation<Void, Never>,
        until target: Int,
        current: Int
    ) {
        if current >= target {
            continuation.resume()
        } else {
            pending.append((target, continuation))
        }
    }

    mutating func resume(reaching count: Int) {
        let ready = pending.filter { $0.target <= count }
        pending.removeAll { $0.target <= count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

extension Array where Element == CheckedContinuation<Void, Never> {
    /// 放行并清空全部挂起者。
    mutating func resumeAll() {
        let pending = self
        removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

/// `AuthenticatedSessionInvalidating` 的唯一测试替身，只记录失效次数。
actor RecordingSessionInvalidator: AuthenticatedSessionInvalidating {
    private(set) var invalidationCount = 0

    func invalidateAuthenticatedSession() {
        invalidationCount += 1
    }
}

/// 卡片取图 port 的最小替身：从不命中缓存，加载也不返回图；给只需要传入 port、不验证取图的视图用。
struct NoImageCardLoader: NativeVideoImageLoading {
    func cachedImage(for url: URL, kind: NativeVideoCardImageKind) -> CGImage? { nil }

    func image(for url: URL, kind: NativeVideoCardImageKind) async -> NativeVideoCardImage? { nil }
}

/// Feed port 的唯一测试替身：推荐默认不可用（给了 `recommendations` 时只有这一页），热门与搜索恒为空页。
///
/// App 根视图会激活浏览页，这里给不验证 Feed 的测试一个不依赖网络的来源。
struct FeedRepositoryStub: FeedRepository {
    var recommendations: [RecommendedVideo]?

    func recommendations(
        after continuation: RecommendationContinuation?
    ) async throws -> RecommendationPage {
        guard let recommendations else { throw ContentApplicationError.unavailable }
        return RecommendationPage(
            videos: recommendations,
            continuation: continuation,
            nextContinuation: nil
        )
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [], pageNumber: page, pageSize: pageSize)
    }

    func searchVideos(request: VideoSearchRequest) async throws -> SearchPage {
        SearchPage(
            videos: [],
            pageNumber: request.page,
            pageSize: 20,
            totalResults: 0,
            totalPages: 0
        )
    }
}

/// 观看历史 port 的唯一测试替身：给了 `error` 时每次读取都失败，否则返回空页。
struct WatchHistoryRepositoryStub: WatchHistoryRepository {
    var error: ContentApplicationError?

    func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage {
        if let error { throw error }
        return WatchHistoryPage(items: [], continuation: nil)
    }
}

/// 稍后再看 port 的唯一测试替身：给了 `error` 时每次读取都失败，否则返回所请求页，条目为 `bvids`（默认空页）。
struct WatchLaterRepositoryStub: WatchLaterRepository {
    var error: ContentApplicationError?
    var bvids: [String] = []

    func watchLater(request: WatchLaterRequest) async throws -> WatchLaterPage {
        if let error { throw error }
        return WatchLaterPage(
            items: bvids.map {
                WatchLaterItem(
                    bvid: $0,
                    title: "手写稍后再看条目",
                    coverURL: nil,
                    owner: nil,
                    durationSeconds: 60,
                    progress: .notStarted,
                    addedAt: nil
                )
            },
            pageNumber: request.page,
            nextPageNumber: nil,
            totalCount: bvids.count
        )
    }
}

/// 稍后再看、收藏、播放页互动与首页推荐反馈四个写入 port 的唯一测试替身：记录每次写入，按顺序取 `outcomes`（用完后
/// 一律成功）；`holdsWrites` 时每次写入挂起到 `releaseWrites()` 或任务取消。互动读取返回 `engagement`，不计入写入。
actor AccountWriteRepositoryStub: WatchLaterWriteRepository, FavoritesWriteRepository,
    VideoEngagementRepository, RecommendationFeedbackRepository
{
    private var outcomes: [AccountWriteError?]
    private let holdsWrites: Bool
    private let engagementState: VideoEngagementState
    private let tripleOutcome: VideoTripleOutcome
    private(set) var calls: [String] = []
    private var callWaiters = CountWaiters()
    private var held: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(
        outcomes: [AccountWriteError?] = [],
        holdsWrites: Bool = false,
        engagement: VideoEngagementState = VideoEngagementState(
            isLiked: false,
            coinCount: 0,
            isFavorited: false
        ),
        tripleOutcome: VideoTripleOutcome = VideoTripleOutcome(
            isLiked: true,
            isCoined: true,
            isFavorited: true,
            addedCoinCount: 2
        )
    ) {
        self.outcomes = outcomes
        self.holdsWrites = holdsWrites
        engagementState = engagement
        self.tripleOutcome = tripleOutcome
    }

    func engagement(of target: VideoWriteTarget) async throws -> VideoEngagementState {
        engagementState
    }

    func setLiked(_ isLiked: Bool, target: VideoWriteTarget, accountID: Int64) async throws {
        try await record("\(isLiked ? "like" : "unlike") \(target.bvid) \(accountID)")
    }

    func addCoins(
        _ count: Int,
        alsoLike: Bool,
        target: VideoWriteTarget,
        accountID: Int64
    ) async throws -> Bool {
        try await record("coin \(count) \(alsoLike ? "+like " : "")\(target.bvid) \(accountID)")
        return alsoLike
    }

    func triple(target: VideoWriteTarget, accountID: Int64) async throws -> VideoTripleOutcome {
        try await record("triple \(target.bvid) \(accountID)")
        return tripleOutcome
    }

    func setFollowing(
        _ isFollowing: Bool,
        uploader: UploaderWriteTarget,
        accountID: Int64
    ) async throws {
        try await record("\(isFollowing ? "follow" : "unfollow") \(uploader.mid) \(accountID)")
    }

    func add(_ target: VideoWriteTarget, accountID: Int64) async throws {
        try await record("add \(target.bvid) \(accountID)")
    }

    func remove(_ target: VideoWriteTarget, accountID: Int64) async throws {
        try await record("remove \(target.bvid) \(accountID)")
    }

    func update(_ change: FavoriteMembershipChange, accountID: Int64) async throws {
        try await record(
            "favorite \(change.target.bvid) +\(change.addedFolderIDs) -\(change.removedFolderIDs) \(accountID)"
        )
    }

    func remove(_ entry: FavoriteFolderEntry, accountID: Int64) async throws {
        try await record("unfavorite \(entry.videoAID) from \(entry.folderID) \(accountID)")
    }

    func dislike(_ feedback: RecommendationFeedback, accountID: Int64) async throws {
        try await record("dislike \(feedback.target.bvid) \(feedback.reason) \(accountID)")
    }

    func cancelDislike(_ feedback: RecommendationFeedback, accountID: Int64) async throws {
        try await record("undislike \(feedback.target.bvid) \(feedback.reason) \(accountID)")
    }

    func waitForCallCount(_ target: Int) async {
        await withCheckedContinuation { callWaiters.add($0, until: target, current: calls.count) }
    }

    func releaseWrites() {
        released = true
        held.resumeAll()
    }

    private func record(_ call: String) async throws {
        calls.append(call)
        callWaiters.resume(reaching: calls.count)
        let outcome = outcomes.isEmpty ? nil : outcomes.removeFirst()
        if holdsWrites, !released {
            await withCheckedContinuation { held.append($0) }
        }
        try Task.checkCancellation()
        if let outcome { throw outcome }
    }
}

/// 收藏夹 port 的唯一测试替身：返回固定的收藏夹列表（含默认收藏夹，视频只在默认收藏夹里）与所请求页（条目为
/// `pageItems`），并记录列表请求的 mid；给了 `error` 时每次读取都失败。
actor FavoritesRepositoryStub: FavoritesRepository {
    private let error: ContentApplicationError?
    private let pageItems: [FavoriteItem]
    private(set) var folderOwnerIDs: [Int64] = []
    private var folderRequestWaiters = CountWaiters()

    init(error: ContentApplicationError? = nil, pageItems: [FavoriteItem] = []) {
        self.error = error
        self.pageItems = pageItems
    }

    func waitForFolderRequestCount(_ target: Int) async {
        await withCheckedContinuation {
            folderRequestWaiters.add($0, until: target, current: folderOwnerIDs.count)
        }
    }

    func favoriteFolders(ownerID: Int64) async throws -> [FavoriteFolder] {
        folderOwnerIDs.append(ownerID)
        folderRequestWaiters.resume(reaching: folderOwnerIDs.count)
        if let error { throw error }
        return [
            FavoriteFolder(
                id: 10,
                title: "默认收藏夹",
                mediaCount: 0,
                isPrivate: false,
                isDefault: true
            ),
            FavoriteFolder(id: 20, title: "私密收藏", mediaCount: 0, isPrivate: true, isDefault: false)
        ]
    }

    func favoriteFolderMemberships(
        ownerID: Int64,
        video: VideoWriteTarget
    ) async throws -> [FavoriteFolderMembership] {
        try await favoriteFolders(ownerID: ownerID).map {
            FavoriteFolderMembership(folder: $0, containsVideo: $0.isDefault)
        }
    }

    func favoriteFolderPage(request: FavoriteFolderRequest) async throws -> FavoriteFolderPage {
        if let error { throw error }
        return FavoriteFolderPage(
            items: pageItems,
            pageNumber: request.page,
            pageSize: 40,
            totalCount: pageItems.count,
            hasMore: false
        )
    }
}

/// 单个视频的手写详情、分 P 与播放地址；`FixtureVideoRepository` 按它回答。
struct VideoFixture: Sendable {
    let aid: Int64
    let bvid: String
    let page: VideoPage
    let title: String

    init(
        aid: Int64 = 700_000,
        bvid: String = "BV1LifecycleFixture",
        cid: Int64 = 900_001,
        title: String = "生命周期测试视频"
    ) {
        self.aid = aid
        self.bvid = bvid
        page = VideoPage(
            cid: cid,
            index: 1,
            title: "P1",
            durationSeconds: 120
        )
        self.title = title
    }

    var identity: PlaybackItemIdentity {
        PlaybackItemIdentity(bvid: bvid, cid: page.cid)
    }

    var detail: VideoDetail {
        VideoDetail(
            bvid: bvid,
            title: title,
            summary: "手写测试数据",
            coverURL: nil,
            owner: VideoOwner(id: 10_001, name: "测试 UP 主"),
            statistics: VideoStatistics(
                viewCount: 10,
                danmakuCount: 2,
                likeCount: 3
            ),
            durationSeconds: 120,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            aid: aid,
            pages: [page]
        )
    }

    var playback: VideoPlayback {
        VideoPlayback(
            media: .dash(
                PlaybackManifest(
                    videoRepresentations: [],
                    audioTracks: []
                )
            ),
            mediaHeaders: [:]
        )
    }
}

/// 视频 port 的唯一测试替身：按 BVID 选择 fixture 回答详情与播放；`playbackError` 让每次播放请求都失败。
struct FixtureVideoRepository: VideoRepository {
    private let fixturesByBVID: [String: VideoFixture]
    private let playbackError: ContentApplicationError?

    init(
        fixtures: [VideoFixture],
        playbackError: ContentApplicationError? = nil
    ) {
        fixturesByBVID = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.bvid, $0) })
        self.playbackError = playbackError
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        try fixture(bvid).detail
    }

    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        if let playbackError { throw playbackError }
        return try fixture(bvid).playback
    }

    private func fixture(_ bvid: String) throws -> VideoFixture {
        guard let fixture = fixturesByBVID[bvid] else {
            throw ContentApplicationError.invalidRequest
        }
        return fixture
    }
}

/// UP 主名片 port 的唯一测试替身：`holdsRequests` 时请求挂起到 `releaseLateResult()` 为止（验证迟到结果与
/// 取消），否则立即返回空名片。
actor UploaderProfileRepositoryStub:
    UploaderProfileRepository
{
    private let holdsRequests: Bool
    private var requestStarted = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<UploaderProfile, Never>?
    private var requestCompleted = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(holdsRequests: Bool) {
        self.holdsRequests = holdsRequests
    }

    func uploaderProfile(for ownerID: Int64) async throws -> UploaderProfile {
        requestStarted = true
        requestWaiters.resumeAll()
        guard holdsRequests else { return UploaderProfile() }
        let result = await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
        requestCompleted = true
        completionWaiters.resumeAll()
        return result
    }

    func waitForRequest() async throws {
        guard !requestStarted else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func releaseLateResult() {
        resultContinuation?.resume(returning: UploaderProfile(signature: "迟到签名", isVIP: true))
        resultContinuation = nil
    }

    func waitForCompletion() async throws {
        guard !requestCompleted else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append(continuation)
        }
    }
}

/// 播放 port 的唯一测试替身：记录 load/begin/stop；`holdsLoads` 时 load 挂起到
/// `failPendingLoad()` 为止，用于驱动加载失败路径。
@MainActor
final class RecordingPlayback: PlaybackControlling {
    private struct ControlledFailure: Error {}

    private let holdsLoads: Bool
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCallCount = 0
    private var pendingLoad: CheckedContinuation<Void, any Error>?
    private var loadWaiters = CountWaiters()
    private var stopWaiters = CountWaiters()

    init(holdsLoads: Bool = false) {
        self.holdsLoads = holdsLoads
    }

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        AsyncStream { $0.finish() }
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        startPositionSeconds: Double?
    ) async throws {
        loadedIdentities.append(identity)
        loadWaiters.resume(reaching: loadedIdentities.count)
        guard holdsLoads else { return }
        try await withCheckedThrowingContinuation { continuation in
            pendingLoad = continuation
        }
    }

    func beginPlayback(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async -> PlaybackStartOutcome {
        startedIdentities.append(identity)
        return .startedAtBeginning
    }

    func restartFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        resumeToken: PlaybackResumeToken
    ) async -> Bool { false }

    func replayFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async -> Bool { false }

    func pause() {}

    func stop() {
        stopCallCount += 1
        stopWaiters.resume(reaching: stopCallCount)
    }

    func failPendingLoad() {
        pendingLoad?.resume(throwing: ControlledFailure())
        pendingLoad = nil
    }

    func waitForLoadCallCount(_ target: Int) async {
        await withCheckedContinuation {
            loadWaiters.add($0, until: target, current: loadedIdentities.count)
        }
    }

    func waitForStopCallCount(_ target: Int) async {
        await withCheckedContinuation {
            stopWaiters.add($0, until: target, current: stopCallCount)
        }
    }
}

/// UP 主空间投稿 port 的唯一测试替身：每次读取都失败（不可用），只用于让空间层打开而不依赖网络。
struct UnavailableUploaderVideoRepository: UploaderVideoRepository {
    func uploaderVideos(
        ownerID: Int64,
        order: UploaderVideoOrder,
        page: Int
    ) async throws -> UploaderVideoPage {
        throw ContentApplicationError.unavailable
    }
}

/// 侧栏上下文层（UP 主空间）的真实模型；投稿读取恒失败，名片请求挂起到测试放行。
@MainActor
func makeUploaderSpace(
    profiles: UploaderProfileRepositoryStub = UploaderProfileRepositoryStub(holdsRequests: true)
) -> UploaderSpaceViewModel {
    UploaderSpaceViewModel(
        useCase: UploaderVideoUseCase(repository: UnavailableUploaderVideoRepository()),
        profileUseCase: UploaderProfileUseCase(repository: profiles)
    )
}

/// 系统 Now Playing 信息中心的唯一测试替身：记录发布、状态与清除。
@MainActor
final class RecordingNowPlayingCenter: SystemNowPlayingCenterWriting {
    private(set) var publications: [[String: Any]] = []
    private(set) var states: [MPNowPlayingPlaybackState] = []
    private(set) var clearCount = 0
    var onPublish: (([String: Any]) -> Void)?

    var latestTitle: String? {
        publications.last?[MPMediaItemPropertyTitle] as? String
    }

    func publish(info: [String: Any], state: MPNowPlayingPlaybackState) {
        publications.append(info)
        states.append(state)
        onPublish?(info)
    }

    func clear() {
        clearCount += 1
    }
}

/// 系统远程命令中心的唯一测试替身：记录安装与移除，可代系统触发命令。
@MainActor
final class RecordingRemoteCommands: SystemRemoteCommandManaging {
    private(set) var installationCount = 0
    private(set) var removalCount = 0
    private var handler:
        (
            @Sendable (SystemNowPlayingCommand) ->
                SystemNowPlayingCommandResult
        )?

    func install(
        handler:
            @escaping @Sendable (SystemNowPlayingCommand) ->
            SystemNowPlayingCommandResult
    ) {
        guard self.handler == nil else { return }
        installationCount += 1
        self.handler = handler
    }

    func removeHandlers() {
        guard handler != nil else { return }
        removalCount += 1
        handler = nil
    }

    func invoke(
        _ command: SystemNowPlayingCommand
    ) -> SystemNowPlayingCommandResult {
        handler?(command) ?? .noSuchContent
    }
}

/// 线路偏好存储的唯一测试替身：只在内存里保存。
final class MemoryPlaybackSourcePreferenceStore: PlaybackSourcePreferenceStoring, Sendable {
    private let record: Mutex<PlaybackSourcePreferenceRecord>
    init(record: PlaybackSourcePreferenceRecord = .defaults) { self.record = Mutex(record) }
    func load() -> PlaybackSourcePreferenceRecord { record.withLock { $0 } }
    func save(_ record: PlaybackSourcePreferenceRecord) { self.record.withLock { $0 = record } }
}

/// 观看进度 port 的唯一测试替身：`holdsReports` 时上报挂起到 `release()` 为止，否则立即丢弃。
actor WatchProgressRepositoryStub: WatchProgressRepository {
    private let holdsReports: Bool
    private var reportCount = 0
    private var reportWaiters = CountWaiters()
    private var held: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(holdsReports: Bool) {
        self.holdsReports = holdsReports
    }

    func report(_ progress: WatchProgressReport) async {
        reportCount += 1
        reportWaiters.resume(reaching: reportCount)
        guard holdsReports, !isReleased else { return }
        await withCheckedContinuation { held.append($0) }
    }

    func waitForReportCount(_ target: Int) async {
        await withCheckedContinuation {
            reportWaiters.add($0, until: target, current: reportCount)
        }
    }

    func release() {
        isReleased = true
        held.resumeAll()
    }
}

/// 测试用的进程级组装：与生产同一个类型，换成不碰网络、系统 Now Playing 与真实偏好的替身。
///
/// 搜索历史用一份 `ScratchDefaults`，搜索历史在构造时读完初值后即丢弃。经它构造的窗口不写入搜索历史
/// （测试的搜索会话各自注入写入闭包）。
@MainActor
func makeTestProcess() -> ProcessComposition {
    guard let scratch = ScratchDefaults() else {
        preconditionFailure("无法创建隔离的 UserDefaults")
    }
    defer { scratch.discard() }
    return ProcessComposition(
        accountSession: AccountSessionCoordinator(),
        watchProgressRepository: WatchProgressRepositoryStub(holdsReports: false),
        settings: AppSettingsModel(
            store: MemoryPlaybackSourcePreferenceStore(),
            discover: { _ in [] },
            resetDiscovery: {},
            run: { _, _ in [] }
        ),
        nowPlaying: SystemNowPlayingController(
            center: RecordingNowPlayingCenter(),
            remoteCommands: RecordingRemoteCommands(),
            artworkLoader: { _ in nil }
        ),
        searchHistory: SearchHistoryStore(defaults: scratch.defaults),
        updater: AppUpdater()
    )
}

/// 相关推荐 port 的唯一测试替身：恒为空。
struct EmptyRelatedVideoRepository: RelatedVideoRepository {
    func relatedVideos(to bvid: String) async throws -> [RelatedVideo] { [] }
}

/// 本 target 构造 `VideoViewModel` 的唯一入口：相关推荐默认为空、UP 主名片默认立即为空名片、播放附带的凭据
/// 失效流默认立即结束。
@MainActor
func makeVideoViewModel(
    useCase: VideoUseCase,
    playback: any PlaybackControlling,
    uploaderProfileUseCase: UploaderProfileUseCase = UploaderProfileUseCase(
        repository: UploaderProfileRepositoryStub(holdsRequests: false)
    )
) -> VideoViewModel {
    VideoViewModel(
        useCase: useCase,
        playback: playback,
        relatedVideoUseCase: RelatedVideoUseCase(repository: EmptyRelatedVideoRepository()),
        uploaderProfileUseCase: uploaderProfileUseCase,
        playbackAuthenticationInvalidations: AsyncStream { $0.finish() }
    )
}
