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
        let subtitleRepository = AppShellRecordingSubtitleRepository()
        let subtitleModel = SubtitleViewModel(
            useCase: SubtitleUseCase(
                repository: subtitleRepository
            ),
            timeline: timeline
        )
        let presentation = AppShellPresentation()
        let danmakuModel = DanmakuControlsViewModel(
            presentation: presentation
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        navigationModel.openPlayback("BV1RouteHostA")
        #expect(await waitUntil {
            probe.events.count == 1
                && probe.activeCount == 1
                && playback.loadedIdentities.count == 1
                && presentation.startedIdentities.count == 1
        })
        await subtitleModel.waitForCurrentTask()
        guard let compactPlayerSize = await waitForPlayerSize(
            in: hostingView
        ) else {
            Issue.record("compact player layout did not settle")
            return
        }

        let firstHostEvent = probe.events[0]
        let baselineEventCount = probe.events.count
        let baselinePlaybackIdentities = playback.loadedIdentities
        let baselineSubtitleIdentities =
            await subtitleRepository.recordedTrackIdentities()
        let baselineDanmakuIdentities = presentation.startedIdentities
        #expect(baselineSubtitleIdentities == baselinePlaybackIdentities)

        window.setContentSize(NSSize(width: 1_320, height: 820))
        hostingView.layoutSubtreeIfNeeded()
        #expect(await waitUntil {
            guard let playerSize = self.playerSize(in: hostingView) else {
                return false
            }
            return self.isSixteenByNine(playerSize)
                && playerSize.width < compactPlayerSize.width
        })

        window.setContentSize(NSSize(width: 1_080, height: 680))
        hostingView.layoutSubtreeIfNeeded()
        #expect(await waitUntil {
            guard let playerSize = self.playerSize(in: hostingView) else {
                return false
            }
            return self.isSixteenByNine(playerSize)
                && abs(playerSize.width - compactPlayerSize.width) < 1
        })
        #expect(probe.events.count == baselineEventCount)
        #expect(probe.events[0] == firstHostEvent)
        #expect(probe.activeCount == 1)
        #expect(probe.peakActiveCount == 1)
        #expect(playback.loadedIdentities == baselinePlaybackIdentities)
        #expect(
            await subtitleRepository.recordedTrackIdentities()
                == baselineSubtitleIdentities
        )
        #expect(presentation.startedIdentities == baselineDanmakuIdentities)

        navigationModel.returnFromPlayback()
        #expect(await waitUntil {
            probe.events.count == 2 && probe.activeCount == 0
        })
        #expect(playback.stopCount == 1)

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

    @MainActor
    private func waitForPlayerSize(in root: NSView) async -> CGSize? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            root.layoutSubtreeIfNeeded()
            if let size = playerSize(in: root), isSixteenByNine(size) {
                return size
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }

    @MainActor
    private func playerSize(in root: NSView) -> CGSize? {
        firstSubview(of: AVPlayerView.self, in: root)?.bounds.size
    }

    @MainActor
    private func isSixteenByNine(_ size: CGSize) -> Bool {
        guard size.height > 0 else { return false }
        return abs(size.width / size.height - 16.0 / 9.0) < 0.01
    }

    @MainActor
    private func firstSubview<ViewType: NSView>(
        of type: ViewType.Type,
        in root: NSView
    ) -> ViewType? {
        if let match = root as? ViewType {
            return match
        }
        for child in root.subviews {
            if let match = firstSubview(of: type, in: child) {
                return match
            }
        }
        return nil
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
            VideoPage(
                cid: 2,
                index: 2,
                title: "P2",
                durationSeconds: 3_661
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
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity
    ) async throws {
        loadedIdentities.append(identity)
        try await Task.sleep(for: .seconds(30))
    }

    func pause() {}

    func stop() {
        stopCount += 1
    }
}

private actor AppShellRecordingSubtitleRepository: SubtitleRepository {
    private var trackIdentities: [PlaybackItemIdentity] = []

    func tracks(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleTrack] {
        trackIdentities.append(identity)
        return []
    }

    func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) async throws -> [SubtitleCue] {
        return []
    }

    func reset(for identity: PlaybackItemIdentity) async {}

    func recordedTrackIdentities() -> [PlaybackItemIdentity] {
        trackIdentities
    }
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
    private(set) var startedIdentities: [PlaybackItemIdentity] = []

    func start(for identity: PlaybackItemIdentity) {
        startedIdentities.append(identity)
    }

    func setEnabled(_ enabled: Bool) {}

    func setModeVisibility(
        scrolling: Bool,
        top: Bool,
        bottom: Bool
    ) {}

    func stop() {}
}
