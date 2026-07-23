import AppKit
import AVKit
import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliDanmaku
import BiliLibraryFeature
import BiliModels
import Observation
import SwiftUI
import Testing
@testable import BiliKit

@Suite(.serialized)
struct AppShellChromeTests {
    @Test
    @MainActor
    func busyHistoryRefreshButtonIsDisabled() {
        let historyModel = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(
                repository: AppShellSuspendingHistoryRepository()
            )
        )
        historyModel.reload()
        #expect(historyModel.isBusy)

        #expect(HistoryRefreshButton(model: historyModel).isDisabled)
        historyModel.reset()
    }
}

struct PlayerHostLifecycleProbeTests {
    @Test
    @MainActor
    func appRouteReturnAndWindowCloseEachDismantleCurrentHostOnce() async {
        let repository = AppShellRouteRepository()
        let playback = SuspendingPlayback()
        let videoModel = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: playback
        )
        let feedModel = GuestFeedViewModel(
            useCase: GuestFeedUseCase(repository: repository)
        )
        let timeline = AppShellIdleTimeline()
        let subtitleModel = SubtitleViewModel(
            useCase: SubtitleUseCase(
                repository: AppShellEmptySubtitleRepository()
            ),
            timeline: timeline
        )
        let danmakuModel = DanmakuControlsViewModel(
            presentation: AppShellPresentation()
        )
        let authenticationModel = AuthenticationViewModel(
            service: AppShellSignedOutAuthentication(),
            qrCodeProvider: AppShellEmptyQRCodeProvider()
        )
        let historyModel = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(
                repository: AppShellSuspendingHistoryRepository()
            )
        )
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
        let probe = PlayerHostLifecycleProbe()
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
        let playerContent = AnyView(
            PlayerHostView(
                player: AVPlayer(),
                danmakuRenderer: renderer,
                danmakuController: controller,
                lifecycleProbe: probe
            ) {
                EmptyView()
            }
        )
        let visibility = AppShellContentVisibility()
        let hostingView = NSHostingView(
            rootView: DisappearingContentRoot(
                visibility: visibility,
                content: ContentView(
                navigationModel: navigationModel,
                feedModel: feedModel,
                videoModel: videoModel,
                subtitleModel: subtitleModel,
                danmakuModel: danmakuModel,
                authenticationModel: authenticationModel,
                historyModel: historyModel,
                playerContent: playerContent
                )
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_080, height: 680)
        hostingView.layoutSubtreeIfNeeded()

        navigationModel.openPlayback("BV1RouteHostA")
        #expect(await waitUntil {
            probe.events.count == 1 && probe.activeCount == 1
        })

        navigationModel.returnFromPlayback()
        #expect(await waitUntil {
            probe.events.count == 2 && probe.activeCount == 0
        })

        navigationModel.openPlayback("BV1RouteHostB")
        #expect(await waitUntil {
            probe.events.count == 3 && probe.activeCount == 1
        })

        visibility.isPresented = false
        hostingView.layoutSubtreeIfNeeded()
        #expect(await waitUntil {
            probe.events.count == 4
                && probe.activeCount == 0
                && navigationModel.route == .section(.popular)
                && playback.stopCount == 2
        })

        guard case let .created(firstHost) = probe.events[0],
              case let .dismantled(firstDismantled) = probe.events[1],
              case let .created(secondHost) = probe.events[2],
              case let .dismantled(secondDismantled) = probe.events[3]
        else {
            Issue.record("unexpected lifecycle event order")
            return
        }
        #expect(firstHost == firstDismantled)
        #expect(secondHost == secondDismantled)
        #expect(probe.peakActiveCount == 1)
        #expect(videoModel.state == .idle)
    }

    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

}

@MainActor
@Observable
private final class AppShellContentVisibility {
    var isPresented = true
}

private struct DisappearingContentRoot: View {
    let visibility: AppShellContentVisibility
    let content: ContentView

    @ViewBuilder
    var body: some View {
        if visibility.isPresented {
            content
        }
    }
}

private actor AppShellRouteRepository: GuestContentRepository {
    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [], pageNumber: page, pageSize: pageSize)
    }

    func searchVideos(keyword: String, page: Int) async throws -> SearchPage {
        SearchPage(
            videos: [],
            pageNumber: page,
            pageSize: 20,
            totalResults: 0,
            totalPages: 0
        )
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        VideoDetail(
            bvid: bvid,
            title: "手写路由测试视频",
            summary: "仅用于 App shell 生命周期测试",
            coverURL: nil,
            owner: VideoOwner(id: 1, name: "测试用户"),
            statistics: VideoStatistics(
                viewCount: 1,
                danmakuCount: 1,
                likeCount: 1
            ),
            durationSeconds: 60,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [
            VideoPage(
                cid: 1,
                index: 1,
                title: "P1",
                durationSeconds: 60
            ),
        ]
    }

    func playback(
        for bvid: String,
        cid: Int64,
        quality: Int
    ) async throws -> VideoPlayback {
        VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: [],
                audioRepresentations: []
            ),
            mediaHeaders: [:]
        )
    }
}

@MainActor
private final class SuspendingPlayback: PlaybackControlling {
    private(set) var stopCount = 0

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity
    ) async throws {
        try await Task.sleep(for: .seconds(30))
    }

    func pause() {}

    func stop() {
        stopCount += 1
    }
}

private actor AppShellEmptySubtitleRepository: SubtitleRepository {
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

private struct AppShellSignedOutAuthentication: AuthenticationServicing {
    func restore() async -> AuthenticationState { .signedOut }

    func requestQRCode() async -> AuthenticationState { .signedOut }

    func pollOnce() async -> AuthenticationState { .signedOut }

    func finalizeLogin() async -> AuthenticationState { .signedOut }

    func cancelLogin() async -> AuthenticationState { .signedOut }

    func logout() async -> AuthenticationState { .signedOut }
}

private struct AppShellEmptyQRCodeProvider:
    AuthenticationQRCodeProviding
{
    func makeQRCodeImage(scale: Int) async throws -> CGImage? { nil }
}

private actor AppShellSuspendingHistoryRepository: WatchHistoryRepository {
    func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage {
        try await Task.sleep(for: .seconds(30))
        return WatchHistoryPage(items: [], continuation: nil)
    }
}

@MainActor
private final class AppShellIdleTimeline: PlaybackTimelineProviding {
    let currentTimelineSnapshot = PlaybackTimelineSnapshot.idle

    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        AsyncStream { continuation in
            continuation.yield(.idle)
        }
    }
}

@MainActor
private final class AppShellPresentation: DanmakuPresentationControlling {
    func start(for identity: PlaybackItemIdentity) {}

    func setEnabled(_ enabled: Bool) {}

    func setModeVisibility(
        scrolling: Bool,
        top: Bool,
        bottom: Bool
    ) {}

    func stop() {}
}
