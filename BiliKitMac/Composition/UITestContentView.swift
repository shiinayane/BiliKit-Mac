#if DEBUG
    import BiliApplication
    import BiliAuthFeature
    import BiliBrowseFeature
    import BiliLibraryFeature
    import BiliModels
    import CoreGraphics
    import Foundation
    import Observation
    import SwiftUI

    struct UITestContentView: View {
        private let content: AppRootView
        private let playback: UITestPlayback

        init() {
            let arguments = ProcessInfo.processInfo.arguments
            let usesContextualNavigator =
                arguments.contains("-ui-testing")
                && arguments.contains("-ui-testing-contextual-navigator")
            let repository = UITestGuestRepository(
                featuredBVID: usesContextualNavigator
                    ? ContextualNavigatorUITestFixture.initialBVID
                    : "fixture-video-1"
            )
            let playback = UITestPlayback()
            self.playback = playback
            let browseModel = GuestBrowseViewModel(
                useCase: GuestFeedUseCase(repository: repository)
            )
            let videoModel = GuestVideoViewModel(
                useCase: GuestVideoUseCase(repository: repository),
                playback: playback
            )
            let subtitleModel = SubtitleViewModel(
                useCase: SubtitleUseCase(repository: UITestSubtitleRepository()),
                timeline: UITestTimeline()
            )
            let danmakuModel = DanmakuControlsViewModel(
                presentation: UITestDanmakuPresentation()
            )
            let authenticationModel = AuthenticationViewModel(
                service: UITestAuthenticationService(),
                qrCodeProvider: UITestQRCodeProvider()
            )
            let historyModel = WatchHistoryViewModel(
                useCase: WatchHistoryUseCase(repository: UITestHistoryRepository())
            )
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

            content = AppRootView(
                navigationCoordinator: navigationCoordinator,
                browseModel: browseModel,
                videoModel: videoModel,
                subtitleModel: subtitleModel,
                danmakuModel: danmakuModel,
                authenticationModel: authenticationModel,
                historyModel: historyModel,
                playerContent: AnyView(
                    ZStack {
                        Color.black
                        Image(systemName: "play.rectangle")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.75))
                            .accessibilityHidden(true)
                    }
                ),
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
                Text(playback.isLoaded ? "播放中" : "播放已停止")
                    .font(.caption2)
                    .opacity(0.01)
                    .accessibilityIdentifier(
                        playback.isLoaded
                            ? "playback.status.playing"
                            : "playback.status.stopped"
                    )
            }
        }
    }

    private struct UITestGuestRepository: GuestContentRepository {
        let featuredBVID: String

        func popular(page: Int, pageSize: Int) async throws -> PopularPage {
            PopularPage(
                videos: [Self.popularVideo(bvid: featuredBVID)],
                pageNumber: page,
                pageSize: pageSize
            )
        }

        func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
            SearchPage(
                videos: [],
                pageNumber: page,
                pageSize: 0,
                totalResults: 0,
                totalPages: 0
            )
        }

        func videoDetail(for bvid: String) async throws -> VideoDetail {
            VideoDetail(
                bvid: bvid,
                title: "自制播放页示例",
                summary: "用于验证本机导航往返的假值。",
                coverURL: nil,
                owner: Self.owner,
                statistics: Self.statistics,
                durationSeconds: 1_205,
                publishedAt: Self.publishedAt,
                dimension: VideoDimension(width: 1_920, height: 1_080, rotation: 0)
            )
        }

        func pages(for bvid: String) async throws -> [VideoPage] {
            [
                VideoPage(
                    cid: 101,
                    index: 1,
                    title: "示例章节",
                    durationSeconds: 1_205
                )
            ]
        }

        func playback(
            for bvid: String,
            cid: Int64
        ) async throws -> VideoPlayback {
            VideoPlayback(
                manifest: PlaybackManifest(
                    videoRepresentations: [],
                    audioRepresentations: []
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
    @Observable
    private final class UITestPlayback: PlaybackControlling {
        private(set) var isLoaded = false

        func load(
            _ playback: VideoPlayback,
            identity: PlaybackItemIdentity
        ) async throws {
            isLoaded = true
        }

        func pause() {}

        func stop() {
            isLoaded = false
        }
    }

    @MainActor
    private final class UITestTimeline: PlaybackTimelineProviding {
        let currentTimelineSnapshot = PlaybackTimelineSnapshot.idle

        func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
            AsyncStream { continuation in
                continuation.yield(.idle)
                continuation.finish()
            }
        }
    }

    private struct UITestSubtitleRepository: SubtitleRepository {
        func tracks(
            for identity: PlaybackItemIdentity
        ) async throws -> [SubtitleTrack] {
            []
        }

        func cues(
            for trackID: String,
            identity: PlaybackItemIdentity
        ) async throws -> [SubtitleCue] {
            []
        }

        func reset(for identity: PlaybackItemIdentity) async {}
    }

    @MainActor
    private final class UITestDanmakuPresentation: DanmakuPresentationControlling {
        func start(for identity: PlaybackItemIdentity) {}
        func setEnabled(_ enabled: Bool) {}

        func setModeVisibility(
            scrolling: Bool,
            top: Bool,
            bottom: Bool
        ) {}

        func stop() {}
    }

    private struct UITestAuthenticationService: AuthenticationServicing {
        func restore() async -> AuthenticationState { .signedOut }
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
        func watchHistory(
            after continuation: WatchHistoryContinuation?,
            pageSize: Int
        ) async throws -> WatchHistoryPage {
            WatchHistoryPage(items: [], continuation: nil)
        }
    }
#endif
