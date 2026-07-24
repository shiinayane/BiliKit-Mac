import AppKit
import BiliApplication
import BiliBrowseFeature
import BiliModels
import SwiftUI
import Testing

struct VideoDetailLifecycleTests {
    @Test
    @MainActor
    func playbackFailureStopsPresentationAndRetryStartsItAgain() async {
        let fixture = VideoDetailLifecycleFixture()
        let player = ControlledFailingPlayback()
        let videoModel = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: VideoDetailLifecycleRepository(fixture: fixture)
            ),
            playback: player
        )
        let subtitleModel = SubtitleViewModel(
            useCase: SubtitleUseCase(
                repository: EmptySubtitleRepository()
            ),
            timeline: IdleTimeline()
        )
        let presentation = RecordingPresentation()
        let danmakuModel = DanmakuControlsViewModel(
            presentation: presentation
        )
        let hostingView = NSHostingView(
            rootView: AnyView(
                VideoDetailColumn(
                    model: videoModel,
                    subtitleModel: subtitleModel,
                    danmakuModel: danmakuModel,
                    onRetry: {}
                ) {
                    EmptyView()
                }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        #expect(await waitUntil {
            presentation.stopCount > 0
        })
        let baselineStopCount = presentation.stopCount

        videoModel.selectVideo(fixture.bvid)
        #expect(await waitUntil {
            player.loadCallCount == 1
                && presentation.startedIdentities.count == 1
                && subtitleModel.state != .idle
        })

        player.failPendingLoad()
        await videoModel.waitForCurrentTask()
        #expect(await waitUntil {
            if case .failed = videoModel.state {
                return subtitleModel.state == .idle
                    && presentation.stopCount == baselineStopCount + 1
            }
            return false
        })

        videoModel.selectVideo(fixture.bvid)
        #expect(await waitUntil {
            player.loadCallCount == 2
                && presentation.startedIdentities.count == 2
                && subtitleModel.state != .idle
        })

        player.failPendingLoad()
        await videoModel.waitForCurrentTask()
        #expect(await waitUntil {
            subtitleModel.state == .idle
                && presentation.stopCount == baselineStopCount + 2
        })

        window.contentView = NSView()
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

private struct VideoDetailLifecycleFixture: Sendable {
    let bvid = "BV1LifecycleFixture"
    let page = VideoPage(
        cid: 900_001,
        index: 1,
        title: "P1",
        durationSeconds: 120
    )

    var detail: VideoDetail {
        VideoDetail(
            bvid: bvid,
            title: "生命周期测试视频",
            summary: "手写测试数据",
            coverURL: nil,
            owner: VideoOwner(id: 10_001, name: "测试 UP 主"),
            statistics: VideoStatistics(
                viewCount: 10,
                danmakuCount: 2,
                likeCount: 3
            ),
            durationSeconds: 120,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    var playback: VideoPlayback {
        VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: [],
                audioRepresentations: []
            ),
            mediaHeaders: [:]
        )
    }
}

private actor VideoDetailLifecycleRepository: GuestContentRepository {
    let fixture: VideoDetailLifecycleFixture

    init(fixture: VideoDetailLifecycleFixture) {
        self.fixture = fixture
    }

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
        fixture.detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [fixture.page]
    }

    func playback(
        for bvid: String,
        cid: Int64,
        quality: Int
    ) async throws -> VideoPlayback {
        fixture.playback
    }
}

@MainActor
private final class ControlledFailingPlayback: PlaybackControlling {
    private(set) var loadCallCount = 0
    private var pendingLoad: CheckedContinuation<Void, any Error>?

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity
    ) async throws {
        loadCallCount += 1
        try await withCheckedThrowingContinuation { continuation in
            pendingLoad = continuation
        }
    }

    func pause() {}

    func stop() {}

    func failPendingLoad() {
        pendingLoad?.resume(throwing: ControlledPlaybackFailure())
        pendingLoad = nil
    }
}

private struct ControlledPlaybackFailure: Error {}

private actor EmptySubtitleRepository: SubtitleRepository {
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
private final class IdleTimeline: PlaybackTimelineProviding {
    let currentTimelineSnapshot = PlaybackTimelineSnapshot.idle

    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        AsyncStream { continuation in
            continuation.yield(.idle)
        }
    }
}

@MainActor
private final class RecordingPresentation: DanmakuPresentationControlling {
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCount = 0

    func start(for identity: PlaybackItemIdentity) {
        startedIdentities.append(identity)
    }

    func setEnabled(_ enabled: Bool) {}

    func setModeVisibility(
        scrolling: Bool,
        top: Bool,
        bottom: Bool
    ) {}

    func stop() {
        stopCount += 1
    }
}
