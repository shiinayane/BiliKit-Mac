import AVKit
import AppKit
import BiliApplication
import BiliBrowseFeature
import BiliDanmaku
import BiliModels
import SwiftUI
import Testing

@testable import BiliKit

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
                VideoPlaybackView(
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
        #expect(
            await waitUntil {
                presentation.stopCount > 0
            }
        )
        let baselineStopCount = presentation.stopCount

        videoModel.loadVideo(fixture.bvid)
        #expect(
            await waitUntil {
                player.loadCallCount == 1
                    && videoModel.presentedContext?.detail.bvid == fixture.bvid
                    && presentation.startedIdentities.count == 1
                    && subtitleModel.state != .idle
            }
        )

        player.failPendingLoad()
        await videoModel.waitForCurrentTask()
        #expect(
            await waitUntil {
                if case .failed = videoModel.state {
                    return videoModel.presentedContext?.detail.bvid
                        == fixture.bvid
                        && subtitleModel.state == .idle
                        && presentation.stopCount == baselineStopCount + 1
                }
                return false
            }
        )

        videoModel.loadVideo(fixture.bvid)
        #expect(
            await waitUntil {
                player.loadCallCount == 2
                    && presentation.startedIdentities.count == 2
                    && subtitleModel.state != .idle
            }
        )

        player.failPendingLoad()
        await videoModel.waitForCurrentTask()
        #expect(
            await waitUntil {
                subtitleModel.state == .idle
                    && presentation.stopCount == baselineStopCount + 2
            }
        )

        window.contentView = NSView()
    }

    @Test
    @MainActor
    func partPlaybackFailureRetryAndResetReplaceDependentIdentities() async {
        let fixture = VideoDetailLifecycleFixture()
        let secondPage = VideoPage(
            cid: 900_002,
            index: 2,
            title: "P2",
            durationSeconds: 180
        )
        let repository = PartLifecycleRepository(
            fixture: fixture,
            secondPage: secondPage
        )
        let player = FailingPartPlayback(failingCID: secondPage.cid)
        let videoModel = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
            playback: player
        )
        let subtitleModel = SubtitleViewModel(
            useCase: SubtitleUseCase(repository: EmptySubtitleRepository()),
            timeline: IdleTimeline()
        )
        let presentation = RecordingPresentation()
        let danmakuModel = DanmakuControlsViewModel(
            presentation: presentation
        )
        let hostingView = NSHostingView(
            rootView: AnyView(
                VideoPlaybackView(
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

        videoModel.loadVideo(fixture.bvid)
        await videoModel.waitForCurrentTask()
        #expect(
            await waitUntil {
                videoModel.presentedPlaybackIdentity == fixture.identity
                    && subtitleModel.state
                        == .unavailable(fixture.identity)
                    && presentation.startedIdentities.last
                        == fixture.identity
            }
        )
        let stopCountBeforeFailure = presentation.stopCount

        videoModel.selectPage(cid: secondPage.cid)
        await videoModel.waitForCurrentTask()
        #expect(
            await waitUntil {
                guard
                    case .failedPage(
                        _,
                        secondPage,
                        .playback
                    ) = videoModel.state
                else {
                    return false
                }
                return secondPage.cid == 900_002
                    && videoModel.requestedPlaybackIdentity
                        == PlaybackItemIdentity(
                            bvid: fixture.bvid,
                            cid: secondPage.cid
                        )
                    && videoModel.presentedPlaybackIdentity == nil
                    && subtitleModel.state == .idle
                    && presentation.stopCount > stopCountBeforeFailure
            }
        )

        videoModel.retry()
        await videoModel.waitForCurrentTask()
        let secondIdentity = PlaybackItemIdentity(
            bvid: fixture.bvid,
            cid: secondPage.cid
        )
        #expect(
            await waitUntil {
                guard case .ready(let context) = videoModel.state else {
                    return false
                }
                return context.selectedPage.cid == secondPage.cid
                    && videoModel.presentedPlaybackIdentity == secondIdentity
                    && subtitleModel.state == .unavailable(secondIdentity)
                    && presentation.startedIdentities.last == secondIdentity
            }
        )
        #expect(
            player.loadedIdentities == [
                fixture.identity,
                secondIdentity,
                secondIdentity,
            ]
        )

        let stopCountBeforeReset = presentation.stopCount
        videoModel.reset()
        #expect(
            await waitUntil {
                videoModel.state == .idle
                    && videoModel.requestedPlaybackIdentity == nil
                    && videoModel.presentedPlaybackIdentity == nil
                    && subtitleModel.state == .idle
                    && presentation.stopCount > stopCountBeforeReset
            }
        )

        window.contentView = NSView()
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func postReadyFailureStopsSubtitleAndDanmakuBeforeRetry() async {
        let fixture = VideoDetailLifecycleFixture()
        let player = PostReadyLifecyclePlayback()
        let videoModel = GuestVideoViewModel(
            useCase: GuestVideoUseCase(
                repository: VideoDetailLifecycleRepository(fixture: fixture)
            ),
            playback: player
        )
        let subtitleModel = SubtitleViewModel(
            useCase: SubtitleUseCase(repository: EmptySubtitleRepository()),
            timeline: IdleTimeline()
        )
        let presentation = RecordingPresentation()
        let danmakuModel = DanmakuControlsViewModel(
            presentation: presentation
        )
        let hostingView = NSHostingView(
            rootView: AnyView(
                VideoPlaybackView(
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

        videoModel.loadVideo(fixture.bvid)
        await videoModel.waitForCurrentTask()
        #expect(
            await waitUntil {
                videoModel.presentedPlaybackIdentity == fixture.identity
                    && subtitleModel.state
                        == .unavailable(fixture.identity)
                    && presentation.startedIdentities.last
                        == fixture.identity
            }
        )
        let stopCountBeforeFailure = presentation.stopCount

        player.fail(fixture.identity)
        await player.waitForStopCallCount(1)
        #expect(
            await waitUntil {
                guard case .failedPage(_, _, .playback) = videoModel.state else {
                    return false
                }
                return videoModel.presentedPlaybackIdentity == nil
                    && subtitleModel.state == .idle
                    && presentation.stopCount > stopCountBeforeFailure
            }
        )

        videoModel.retry()
        await videoModel.waitForCurrentTask()
        #expect(
            await waitUntil {
                videoModel.presentedPlaybackIdentity == fixture.identity
                    && subtitleModel.state
                        == .unavailable(fixture.identity)
                    && presentation.startedIdentities.last
                        == fixture.identity
            }
        )
        #expect(player.loadedIdentities == [fixture.identity, fixture.identity])

        videoModel.reset()
        window.contentView = NSView()
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func replacementKeepsPlayerSurfaceUntilReset() async throws {
        let first = VideoDetailLifecycleFixture(
            bvid: "BV1LifecycleFirst",
            cid: 900_001,
            title: "第一个视频"
        )
        let replacement = VideoDetailLifecycleFixture(
            bvid: "BV1LifecycleReplacement",
            cid: 900_002,
            title: "替换视频"
        )
        let repository = ReplacementLifecycleRepository(
            first: first,
            replacement: replacement
        )
        let player = ControlledReplacementPlayback()
        let videoModel = GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: repository),
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
        let hostedPlayer = AVPlayer()
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
        let coordinator = AppNavigationCoordinator(
            startPlayback: { bvid in
                videoModel.loadVideo(bvid)
            },
            stopPlayback: {
                videoModel.reset()
                subtitleModel.reset()
                danmakuModel.reset()
            }
        )
        let playerSurface = PlayerSurfaceRecorder()
        let hostingView = NSHostingView(
            rootView: AnyView(
                VideoPlaybackView(
                    model: videoModel,
                    subtitleModel: subtitleModel,
                    danmakuModel: danmakuModel,
                    onRetry: {}
                ) {
                    PlayerHostView(
                        player: hostedPlayer,
                        danmakuRenderer: renderer,
                        danmakuController: controller
                    ) {
                        PlayerSurfaceProbe(
                            recorder: playerSurface,
                            phase: PlayerSurfacePhase(videoModel.state)
                        )
                    }
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

        coordinator.openPlayback(first.bvid)
        #expect(
            await waitUntil {
                guard case .ready(let context) = videoModel.state else {
                    return false
                }
                return context.detail.bvid == first.bvid
                    && videoModel.presentedContext?.detail.bvid == first.bvid
                    && playerSurface.createdIdentities.count == 1
                    && self.playerViews(in: hostingView).count == 1
                    && presentation.startedIdentities.last?.bvid == first.bvid
            }
        )
        let surfaceIdentity = playerSurface.createdIdentities[0]
        let playerView = try #require(playerViews(in: hostingView).first)
        let playerViewIdentity = ObjectIdentifier(playerView)
        #expect(playerView.player === hostedPlayer)
        let stopCountBeforeReplacement = presentation.stopCount

        coordinator.openPlayback(replacement.bvid)
        #expect(
            await waitUntilAsync {
                guard
                    case .loading(let bvid) = videoModel.state,
                    bvid == replacement.bvid
                else {
                    return false
                }
                return await repository.replacementRequestHasStarted()
                    && videoModel.presentedContext?.detail.bvid == first.bvid
                    && playerSurface.lastUpdatedPhase == .loading
                    && subtitleModel.state == .idle
                    && presentation.stopCount
                        == stopCountBeforeReplacement + 1
            }
        )
        #expect(player.loadedIdentities == [first.identity])
        #expect(player.stopCallCount == 1)
        #expect(playerSurface.createdIdentities == [surfaceIdentity])
        #expect(playerSurface.dismantledIdentities.isEmpty)
        #expect(
            playerViews(in: hostingView).first.map(ObjectIdentifier.init)
                == Optional(playerViewIdentity)
        )

        await repository.failReplacementRequest()
        await videoModel.waitForCurrentTask()
        hostingView.layoutSubtreeIfNeeded()
        #expect(
            await waitUntil {
                if case .failed(let bvid, .content) = videoModel.state {
                    return bvid == replacement.bvid
                        && videoModel.presentedContext?.detail.bvid == first.bvid
                        && playerSurface.lastUpdatedPhase == .failed
                }
                return false
            }
        )
        #expect(playerSurface.createdIdentities == [surfaceIdentity])
        #expect(playerSurface.dismantledIdentities.isEmpty)
        #expect(
            playerViews(in: hostingView).first.map(ObjectIdentifier.init)
                == Optional(playerViewIdentity)
        )

        coordinator.retryPlayback()
        #expect(
            await waitUntil {
                guard
                    case .preparingPlayback(let context) = videoModel.state
                else {
                    return false
                }
                return context.detail.bvid == replacement.bvid
                    && videoModel.presentedContext?.detail.bvid
                        == replacement.bvid
                    && playerSurface.lastUpdatedPhase == .preparing
                    && player.loadedIdentities == [
                        first.identity,
                        replacement.identity,
                    ]
                    && presentation.startedIdentities.last?.bvid
                        == replacement.bvid
            }
        )
        #expect(playerSurface.createdIdentities == [surfaceIdentity])
        #expect(playerSurface.dismantledIdentities.isEmpty)
        #expect(
            playerViews(in: hostingView).first.map(ObjectIdentifier.init)
                == Optional(playerViewIdentity)
        )

        player.succeedPendingLoad()
        await videoModel.waitForCurrentTask()
        #expect(
            await waitUntil {
                if case .ready(let context) = videoModel.state {
                    return context.detail.bvid == replacement.bvid
                        && playerSurface.lastUpdatedPhase == .ready
                }
                return false
            }
        )
        #expect(playerSurface.createdIdentities == [surfaceIdentity])
        #expect(playerSurface.dismantledIdentities.isEmpty)
        #expect(
            playerViews(in: hostingView).first.map(ObjectIdentifier.init)
                == Optional(playerViewIdentity)
        )

        let stopCountBeforeBack = presentation.stopCount
        coordinator.playbackPath = []
        #expect(
            await waitUntil {
                playerSurface.dismantledIdentities == [surfaceIdentity]
                    && videoModel.presentedContext == nil
                    && subtitleModel.state == .idle
                    && self.playerViews(in: hostingView).isEmpty
                    && playerView.player == nil
            }
        )
        #expect(playerSurface.createdIdentities == [surfaceIdentity])
        #expect(player.stopCallCount == 3)
        #expect(
            presentation.startedIdentities == [
                first.identity,
                replacement.identity,
            ]
        )
        #expect(presentation.stopCount > stopCountBeforeBack)

        window.contentView = NSView()
    }

    @MainActor
    private func playerViews(in root: NSView) -> [AVPlayerView] {
        var matches: [AVPlayerView] = []
        if let playerView = root as? AVPlayerView {
            matches.append(playerView)
        }
        for child in root.subviews {
            matches.append(contentsOf: playerViews(in: child))
        }
        return matches
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
    private func waitUntilAsync(
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !(await condition()) {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}

private struct VideoDetailLifecycleFixture: Sendable {
    let bvid: String
    let page: VideoPage
    let title: String

    init(
        bvid: String = "BV1LifecycleFixture",
        cid: Int64 = 900_001,
        title: String = "生命周期测试视频"
    ) {
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
        cid: Int64
    ) async throws -> VideoPlayback {
        fixture.playback
    }
}

private actor ReplacementLifecycleRepository: GuestContentRepository {
    let first: VideoDetailLifecycleFixture
    let replacement: VideoDetailLifecycleFixture
    private var blocksReplacement = true
    private var replacementRequestStarted = false
    private var blockedRequest: CheckedContinuation<Void, any Error>?

    init(
        first: VideoDetailLifecycleFixture,
        replacement: VideoDetailLifecycleFixture
    ) {
        self.first = first
        self.replacement = replacement
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
        if bvid == replacement.bvid, blocksReplacement {
            try await withCheckedThrowingContinuation { continuation in
                blockedRequest = continuation
                replacementRequestStarted = true
            }
        }
        return fixture(for: bvid).detail
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        [fixture(for: bvid).page]
    }

    func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        fixture(for: bvid).playback
    }

    func replacementRequestHasStarted() -> Bool {
        replacementRequestStarted
    }

    func failReplacementRequest() {
        blocksReplacement = false
        blockedRequest?.resume(
            throwing: GuestApplicationError.transportFailure
        )
        blockedRequest = nil
    }

    private func fixture(
        for bvid: String
    ) -> VideoDetailLifecycleFixture {
        bvid == first.bvid ? first : replacement
    }
}

private actor PartLifecycleRepository: GuestContentRepository {
    let fixture: VideoDetailLifecycleFixture
    let secondPage: VideoPage

    init(
        fixture: VideoDetailLifecycleFixture,
        secondPage: VideoPage
    ) {
        self.fixture = fixture
        self.secondPage = secondPage
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
        [fixture.page, secondPage]
    }

    func playback(
        for bvid: String,
        cid: Int64
    ) async throws -> VideoPlayback {
        fixture.playback
    }
}

@MainActor
private final class ControlledFailingPlayback: PlaybackControlling {
    private(set) var loadCallCount = 0
    private var pendingLoad: CheckedContinuation<Void, any Error>?

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        finishedPlaybackFailureEvents()
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
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

@MainActor
private final class ControlledReplacementPlayback: PlaybackControlling {
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCallCount = 0
    private var pendingLoad: CheckedContinuation<Void, any Error>?

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        finishedPlaybackFailureEvents()
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        loadedIdentities.append(identity)
        guard loadedIdentities.count > 1 else { return }
        try await withCheckedThrowingContinuation { continuation in
            pendingLoad = continuation
        }
    }

    func pause() {}

    func stop() {
        stopCallCount += 1
    }

    func succeedPendingLoad() {
        pendingLoad?.resume()
        pendingLoad = nil
    }
}

@MainActor
private final class FailingPartPlayback: PlaybackControlling {
    private let failingCID: Int64
    private var hasFailedTarget = false
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []

    init(failingCID: Int64) {
        self.failingCID = failingCID
    }

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        finishedPlaybackFailureEvents()
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        loadedIdentities.append(identity)
        if identity.cid == failingCID, !hasFailedTarget {
            hasFailedTarget = true
            throw ControlledPlaybackFailure()
        }
    }

    func pause() {}

    func stop() {}
}

@MainActor
private final class PostReadyLifecyclePlayback: PlaybackControlling {
    private struct StopWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let failures: AsyncStream<PlaybackFailureEvent>
    private let failureContinuation: AsyncStream<PlaybackFailureEvent>.Continuation
    private var stopWaiters: [StopWaiter] = []
    private var loadedIntents: [PlaybackItemIdentity: PlaybackLoadIntent] = [:]
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCallCount = 0

    init() {
        let stream = AsyncStream<PlaybackFailureEvent>.makeStream()
        failures = stream.stream
        failureContinuation = stream.continuation
    }

    deinit {
        failureContinuation.finish()
    }

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        failures
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async throws {
        loadedIdentities.append(identity)
        loadedIntents[identity] = intent
    }

    func pause() {}

    func stop() {
        stopCallCount += 1
        let ready = stopWaiters.filter {
            stopCallCount >= $0.expectedCount
        }
        stopWaiters.removeAll {
            stopCallCount >= $0.expectedCount
        }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func fail(_ identity: PlaybackItemIdentity) {
        guard let intent = loadedIntents[identity] else { return }
        failureContinuation.yield(
            PlaybackFailureEvent(identity: identity, intent: intent)
        )
    }

    func waitForStopCallCount(_ expectedCount: Int) async {
        guard stopCallCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append(
                StopWaiter(
                    expectedCount: expectedCount,
                    continuation: continuation
                )
            )
        }
    }
}

private struct ControlledPlaybackFailure: Error {}

private func finishedPlaybackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
    AsyncStream { continuation in
        continuation.finish()
    }
}

@MainActor
private final class PlayerSurfaceRecorder {
    private(set) var createdIdentities: [ObjectIdentifier] = []
    private(set) var dismantledIdentities: [ObjectIdentifier] = []
    private(set) var updatedPhases: [PlayerSurfacePhase] = []

    var lastUpdatedPhase: PlayerSurfacePhase? {
        updatedPhases.last
    }

    func recordCreation(of view: NSView) {
        createdIdentities.append(ObjectIdentifier(view))
    }

    func recordDismantle(of view: NSView) {
        dismantledIdentities.append(ObjectIdentifier(view))
    }

    func recordUpdate(phase: PlayerSurfacePhase) {
        updatedPhases.append(phase)
    }
}

private struct PlayerSurfaceProbe: NSViewRepresentable {
    let recorder: PlayerSurfaceRecorder
    let phase: PlayerSurfacePhase

    func makeCoordinator() -> PlayerSurfaceRecorder {
        recorder
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.recordCreation(of: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.recordUpdate(phase: phase)
    }

    static func dismantleNSView(
        _ nsView: NSView,
        coordinator: PlayerSurfaceRecorder
    ) {
        coordinator.recordDismantle(of: nsView)
    }
}

private enum PlayerSurfacePhase: Equatable {
    case idle
    case loading
    case preparing
    case ready
    case failed

    init(_ state: GuestVideoState) {
        switch state {
        case .idle:
            self = .idle
        case .loading:
            self = .loading
        case .loadingPage:
            self = .loading
        case .preparingPlayback:
            self = .preparing
        case .ready:
            self = .ready
        case .failed:
            self = .failed
        case .failedPage:
            self = .failed
        }
    }
}

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
