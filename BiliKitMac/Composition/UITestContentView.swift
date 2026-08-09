#if DEBUG
    import BiliApplication
    import BiliAuthFeature
    import BiliBrowseFeature
    import BiliDanmaku
    import BiliLibraryFeature
    import BiliModels
    import CoreGraphics
    import Foundation
    import Observation
    import SwiftUI

    struct UITestContentView: View {
        private let content: AppRootView
        @State private var playback: UITestLocalAVPlayerPlayback
        @State private var sourceRequests: UITestSourceRequestRecorder
        private let dynamicTypeSize: DynamicTypeSize

        init() {
            let arguments = ProcessInfo.processInfo.arguments
            let usesContextualNavigator =
                arguments.contains("-ui-testing")
                && arguments.contains("-ui-testing-contextual-navigator")
            let usesMinimalPlaybackContext =
                arguments.contains("-ui-testing")
                && arguments.contains(
                    "-ui-testing-single-part-empty-summary"
                )
            let usesAccountIdentity =
                arguments.contains("-ui-testing")
                && arguments.contains("-ui-testing-account-identity")
            let sourceRequests = UITestSourceRequestRecorder()
            _sourceRequests = State(initialValue: sourceRequests)
            dynamicTypeSize =
                arguments.contains("-ui-testing-large-text")
                ? .accessibility3
                : .large
            let repository = UITestGuestRepository(
                featuredBVID: usesContextualNavigator
                    ? ContextualNavigatorUITestFixture.initialBVID
                    : "fixture-video-1",
                includesSourceFixtures: usesContextualNavigator,
                usesMinimalPlaybackContext: usesMinimalPlaybackContext,
                requestRecorder: sourceRequests
            )
            let playback = UITestLocalAVPlayerPlayback()
            _playback = State(initialValue: playback)
            let browseModel = GuestBrowseViewModel(
                useCase: GuestFeedUseCase(repository: repository)
            )
            let videoModel = GuestVideoViewModel(
                useCase: GuestVideoUseCase(repository: repository),
                playback: playback,
                uploaderSignatureUseCase: UploaderSignatureUseCase(
                    repository: repository
                )
            )
            let danmakuModel = DanmakuControlsViewModel(
                presentation: UITestDanmakuPresentation()
            )
            let authenticationModel = AuthenticationViewModel(
                service: UITestAuthenticationService(
                    restoresSignedIn: usesContextualNavigator
                        || usesAccountIdentity,
                    identity: usesAccountIdentity
                        ? Self.accountIdentityFixture
                        : nil
                ),
                qrCodeProvider: UITestQRCodeProvider()
            )
            let historyModel = WatchHistoryViewModel(
                useCase: WatchHistoryUseCase(
                    repository: UITestHistoryRepository(
                        includesFixture: usesContextualNavigator,
                        requestRecorder: sourceRequests
                    )
                )
            )
            let navigationCoordinator = AppNavigationCoordinator(
                startPlayback: { bvid in
                    videoModel.loadVideo(bvid)
                },
                stopPlayback: {
                    videoModel.reset()
                    danmakuModel.reset()
                }
            )

            content = AppRootView(
                navigationCoordinator: navigationCoordinator,
                browseModel: browseModel,
                videoModel: videoModel,
                danmakuModel: danmakuModel,
                authenticationModel: authenticationModel,
                historyModel: historyModel,
                playerContent: Self.makePlayerContent(playback: playback),
                playbackSidebarContent: usesContextualNavigator
                    ? { bvid, onSelectRecommendation in
                        ContextualNavigatorUITestFixture.sidebar(
                            bvid: bvid,
                            onSelectRecommendation: onSelectRecommendation
                        )
                    }
                    : nil
            )
        }

        var body: some View {
            content.overlay(alignment: .topTrailing) {
                VStack {
                    Text(playback.isLoaded ? "播放中" : "播放已停止")
                        .accessibilityIdentifier(
                            playback.isLoaded
                                ? "playback.status.playing"
                                : "playback.status.stopped"
                        )
                    Text("Local AVPlayer fixture")
                        .accessibilityLabel(playback.probeValue)
                        .accessibilityIdentifier("local-avplayer.timeline")
                    Text("Source request counts")
                        .accessibilityLabel(sourceRequests.probeValue)
                        .accessibilityIdentifier("fixture.source-requests")
                }
                .font(.caption2)
                .opacity(0.01)
            }
            .environment(\.dynamicTypeSize, dynamicTypeSize)
        }

        private static func makePlayerContent(
            playback: UITestLocalAVPlayerPlayback
        ) -> AnyView {
            let renderer = CoreAnimationDanmakuRenderer()
            let controller = DanmakuPresentationController(
                backend: renderer,
                configuration: DanmakuLaneConfiguration(
                    surfaceWidth: 0,
                    surfaceHeight: 0,
                    laneHeight: 36,
                    minimumHorizontalGap: 12,
                    maximumActiveCount:
                        DanmakuLaneConfiguration.hardMaximumActiveCount,
                    displayAreaFraction: 1
                )
            )
            return AnyView(
                PlayerHostView(
                    player: playback.player,
                    danmakuRenderer: renderer,
                    danmakuController: controller
                )
            )
        }

        private static let accountIdentityFixture = AccountIdentity(
            id: 42,
            displayName: "Fixture Account",
            avatarURL: nil
        )
    }

    private struct UITestGuestRepository: GuestContentRepository,
        UploaderSignatureRepository
    {
        let featuredBVID: String
        let includesSourceFixtures: Bool
        let usesMinimalPlaybackContext: Bool
        let requestRecorder: UITestSourceRequestRecorder

        func popular(page: Int, pageSize: Int) async throws -> PopularPage {
            await requestRecorder.recordPopular()
            return PopularPage(
                videos: includesSourceFixtures
                    ? Self.popularVideos(featuredBVID: featuredBVID)
                    : [Self.popularVideo(bvid: featuredBVID)],
                pageNumber: page,
                pageSize: pageSize
            )
        }

        func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
            await requestRecorder.recordSearch()
            let videos = includesSourceFixtures ? Self.searchVideos : []
            return SearchPage(
                videos: videos,
                pageNumber: page,
                pageSize: videos.count,
                totalResults: videos.count,
                totalPages: includesSourceFixtures ? 1 : 0
            )
        }

        func videoDetail(for bvid: String) async throws -> VideoDetail {
            VideoDetail(
                bvid: bvid,
                title: "自制播放页示例",
                summary: usesMinimalPlaybackContext
                    ? ""
                    : "用于验证本机导航往返的假值。",
                coverURL: nil,
                owner: Self.owner,
                statistics: Self.statistics,
                durationSeconds: 1_205,
                publishedAt: Self.publishedAt,
                dimension: VideoDimension(width: 1_920, height: 1_080, rotation: 0)
            )
        }

        func signature(for ownerID: Int64) async throws -> String? {
            "用于验证窄侧栏中签名默认单行显示，点击后完整换行展开，再次点击恢复收起状态的公开假值。"
        }

        func pages(for bvid: String) async throws -> [VideoPage] {
            let pages = [
                VideoPage(
                    cid: 101,
                    index: 1,
                    title: "示例章节",
                    durationSeconds: 1_205
                ),
                VideoPage(
                    cid: 102,
                    index: 2,
                    title: "布局迁移与状态边界",
                    durationSeconds: 1_401
                ),
                VideoPage(
                    cid: 103,
                    index: 3,
                    title: "辅助功能验证",
                    durationSeconds: 1_600
                ),
                VideoPage(
                    cid: 104,
                    index: 4,
                    title: "长目录滚动",
                    durationSeconds: 980
                ),
                VideoPage(
                    cid: 105,
                    index: 5,
                    title: "边界状态",
                    durationSeconds: 760
                ),
                VideoPage(
                    cid: 106,
                    index: 6,
                    title: "键盘访问",
                    durationSeconds: 620
                ),
                VideoPage(
                    cid: 107,
                    index: 7,
                    title: "末项切换：长标题 mixed English 与日本語可读性验证",
                    durationSeconds: 540
                ),
            ]
            return usesMinimalPlaybackContext
                ? [pages[0]]
                : pages
        }

        func playback(
            for bvid: String,
            cid: Int64
        ) async throws -> VideoPlayback {
            VideoPlayback(
                manifest: PlaybackManifest(
                    videoRepresentations: [],
                    originalAudioRepresentations: []
                ),
                mediaHeaders: [:]
            )
        }

        private static let owner = VideoOwner(id: 1, name: "示例创作者")
        private static let statistics = VideoStatistics(
            viewCount: 123_456,
            danmakuCount: 7_890,
            likeCount: 4_321
        )
        private static let publishedAt = Date(timeIntervalSince1970: 1_785_000_000)
        private static let searchVideos = (0..<18).map { index in
            SearchVideo(
                bvid: index == 0
                    ? "fixture-search-A"
                    : index == 17
                        ? "fixture-search-marker"
                        : "fixture-search-\(index)",
                title: "自制搜索示例 \(index + 1)",
                coverURL: nil,
                owner: owner,
                statistics: statistics,
                durationSeconds: 541,
                publishedAt: publishedAt
            )
        }

        private static func popularVideos(
            featuredBVID: String
        ) -> [PopularVideo] {
            (0..<18).map { index in
                popularVideo(
                    bvid: index == 0
                        ? featuredBVID
                        : index == 17
                            ? "fixture-popular-marker"
                            : "fixture-popular-\(index)"
                )
            }
        }

        private static func popularVideo(bvid: String) -> PopularVideo {
            PopularVideo(
                bvid: bvid,
                title: "自制热门示例",
                coverURL: nil,
                owner: owner,
                statistics: statistics,
                durationSeconds: 637,
                publishedAt: publishedAt
            )
        }
    }

    @MainActor
    private final class UITestDanmakuPresentation: DanmakuPresentationControlling {
        func start(for identity: PlaybackItemIdentity) {}
        func setEnabled(_ enabled: Bool) {}
        func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {}
        func setOpacity(_ opacity: DanmakuOpacity) {}
        func setDisplayArea(_ displayArea: DanmakuDisplayArea) {}
        func setDensity(_ density: DanmakuDensity) {}

        func setModeVisibility(
            scrolling: Bool,
            top: Bool,
            bottom: Bool
        ) {}

        func stop() {}
    }

    private struct UITestAuthenticationService: AuthenticationServicing {
        let restoresSignedIn: Bool
        let identity: AccountIdentity?

        func restore() async -> AuthenticationState {
            restoresSignedIn ? .signedIn(identity) : .signedOut
        }
        func requestQRCode() async -> AuthenticationState { .signedOut }
        func pollOnce() async -> AuthenticationState { .signedOut }
        func finalizeLogin() async -> AuthenticationState { .signedOut }
        func cancelLogin() async -> AuthenticationState { .signedOut }
        func logout() async -> AuthenticationState { .signedOut }
    }

    private struct UITestQRCodeProvider: AuthenticationQRCodeProviding {
        func makeQRCodeImage(scale: Int) async throws -> CGImage? { nil }
    }

    private struct UITestHistoryRepository: WatchHistoryRepository {
        let includesFixture: Bool
        let requestRecorder: UITestSourceRequestRecorder

        func watchHistory(
            after continuation: WatchHistoryContinuation?,
            pageSize: Int
        ) async throws -> WatchHistoryPage {
            await requestRecorder.recordHistory()
            return WatchHistoryPage(
                items: includesFixture
                    ? Self.items
                    : [],
                continuation: nil
            )
        }

        private static let items = (0..<18).map { index in
            WatchHistoryItem(
                bvid: index == 0
                    ? "fixture-history-A"
                    : index == 17
                        ? "fixture-history-marker"
                        : "fixture-history-\(index)",
                title: "自制历史示例 \(index + 1)",
                coverURL: nil,
                owner: VideoOwner(id: 2, name: "历史夹具创作者"),
                progressSeconds: 120,
                durationSeconds: 600,
                viewedAt: Date(timeIntervalSince1970: 1_785_000_000)
            )
        }
    }

    @MainActor
    @Observable
    private final class UITestSourceRequestRecorder {
        private(set) var popularCount = 0
        private(set) var searchCount = 0
        private(set) var historyCount = 0

        var probeValue: String {
            "popular=\(popularCount);search=\(searchCount);history=\(historyCount)"
        }

        func recordPopular() {
            popularCount += 1
        }

        func recordSearch() {
            searchCount += 1
        }

        func recordHistory() {
            historyCount += 1
        }
    }
#endif
