@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliPlayback

// Swift Testing macros reference their diagnostic comment type without qualification.
private typealias Comment = Testing.Comment

@Suite(.serialized, .timeLimit(.minutes(2)))
struct AVPlayerEngineLifecycleTests {
    @Test
    @MainActor
    func engineBeginPlaybackIsIntentGuardedAndRestartsOnce() async throws {
        let videoData = try fixtureBase64Data(
            named: "video-avc-256x144-4s-global-sidx.mp4"
        )
        let audioData = try fixtureBase64Data(
            named: "audio-aac-4s-global-sidx.mp4"
        )
        let videoURL = try #require(
            URL(string: "https://begin-playback.example/video")
        )
        let audioURL = try #require(
            URL(string: "https://begin-playback.example/audio")
        )
        let video = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400c",
            bandwidth: 100_000,
            data: videoData,
            primaryURL: videoURL,
            videoAttributes: try VideoRepresentationAttributes(
                width: 256,
                height: 144,
                frameRate: 24
            )
        ).representation
        let audio = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 32_000,
            data: audioData,
            primaryURL: audioURL
        ).representation
        let engine = AVPlayerEngine(
            bridge: DASHToHLSBridge(
                rangeClient: HTTPRangeClient(
                    transport: FixtureRangeTransport(
                        media: [videoURL: videoData, audioURL: audioData]
                    )
                )
            )
        )
        engine.player.isMuted = true
        defer { engine.stop() }
        let identity = PlaybackItemIdentity(
            bvid: "BV1BeginPlaybackFixture",
            cid: 900_002
        )
        let request = PlaybackRequest(
            manifest: PlaybackManifest(
                videoRepresentations: [video],
                originalAudioRepresentations: [audio]
            )
        )

        // 过期 intent、过期 identity 或已观察到的用户暂停都不能自动起播。
        let loadIntent = PlaybackLoadIntent()
        try await engine.load(request, identity: identity, intent: loadIntent)
        #expect(
            await engine.beginPlayback(
                identity: identity,
                intent: PlaybackLoadIntent(),
                initialPositionSeconds: nil
            ) == .rejected
        )
        #expect(
            await engine.beginPlayback(
                identity: PlaybackItemIdentity(
                    bvid: "BV1StalePlayback",
                    cid: identity.cid
                ),
                intent: loadIntent,
                initialPositionSeconds: nil
            ) == .rejected
        )
        engine.pause()
        #expect(
            await engine.beginPlayback(
                identity: identity,
                intent: loadIntent,
                initialPositionSeconds: nil
            ) == .rejected
        )

        // 起播前的用户 seek 同样优先于自动起播。
        engine.stop()
        let seekedIntent = PlaybackLoadIntent()
        try await engine.load(request, identity: identity, intent: seekedIntent)
        try await engine.seek(to: .milliseconds(100))
        #expect(
            await engine.beginPlayback(
                identity: identity,
                intent: seekedIntent,
                initialPositionSeconds: nil
            ) == .rejected
        )

        // 同一 intent 最多起播一次。
        engine.stop()
        let playableIntent = PlaybackLoadIntent()
        try await engine.load(request, identity: identity, intent: playableIntent)
        #expect(
            await engine.beginPlayback(
                identity: identity,
                intent: playableIntent,
                initialPositionSeconds: nil
            ) == .startedAtBeginning
        )
        #expect(
            await engine.beginPlayback(
                identity: identity,
                intent: playableIntent,
                initialPositionSeconds: nil
            ) == .rejected
        )
        try await waitUntilTimeControlStatus(of: engine.player, is: .playing)

        // 断点续播 token 只允许一次“从头播放”，重叠调用只有一个成功。
        engine.stop()
        let resumeIntent = PlaybackLoadIntent()
        try await engine.load(request, identity: identity, intent: resumeIntent)
        let resumeOutcome = await engine.beginPlayback(
            identity: identity,
            intent: resumeIntent,
            initialPositionSeconds: 0.3
        )
        guard case .resumed(_, let resumeToken, _) = resumeOutcome else {
            Issue.record("有效首次断点未完成 seek-before-play：\(resumeOutcome)")
            return
        }
        try await waitUntilTimeControlStatus(of: engine.player, is: .playing)

        async let firstRestart = engine.restartFromBeginning(
            identity: identity,
            intent: resumeIntent,
            resumeToken: resumeToken
        )
        async let overlappingRestart = engine.restartFromBeginning(
            identity: identity,
            intent: resumeIntent,
            resumeToken: resumeToken
        )
        let restartResults = await [firstRestart, overlappingRestart]
        #expect(restartResults.filter { $0 }.count == 1)
        #expect(
            !(await engine.restartFromBeginning(
                identity: identity,
                intent: resumeIntent,
                resumeToken: resumeToken
            ))
        )
    }

    @Test
    @MainActor
    func engineSerializesSubtitleResetAcrossABALoads() async throws {
        let fixture = try makeSimpleMedia(host: "native-subtitle.example")
        let subtitleRepository = FixtureSubtitleRepository(
            catalog: .tracks([
                SubtitleTrack(
                    id: "standard-zh",
                    languageCode: "zh",
                    displayName: "中文",
                    kind: .standard
                )
            ]),
            holdsReset: true
        )
        let engine = AVPlayerEngine(
            bridge: DASHToHLSBridge(
                rangeClient: HTTPRangeClient(
                    transport: FixtureRangeTransport(
                        media: fixture.media
                    )
                )
            ),
            subtitleUseCase: SubtitleUseCase(
                repository: subtitleRepository
            )
        )
        engine.player.isMuted = true
        let request = PlaybackRequest(
            manifest: PlaybackManifest(
                videoRepresentations: [fixture.video],
                originalAudioRepresentations: [fixture.audio]
            )
        )
        let firstA = PlaybackItemIdentity(bvid: "BV1NativeA", cid: 101)
        let itemB = PlaybackItemIdentity(bvid: "BV1NativeB", cid: 202)

        try await engine.load(request, identity: firstA)

        let blockedBLoad = Task {
            try await engine.load(request, identity: itemB)
        }
        await subtitleRepository.waitForResetCalls(1)
        let replacementALoad = Task {
            try await engine.load(request, identity: firstA)
        }
        #expect(await subtitleRepository.trackRequests == [firstA])

        await subtitleRepository.releaseReset()
        do {
            try await blockedBLoad.value
            Issue.record("Superseded B load unexpectedly completed")
        } catch is CancellationError {
            // The newer A generation must reject B after the old reset returns.
        }
        try await replacementALoad.value
        #expect(await subtitleRepository.trackRequests == [firstA, firstA])

        let stoppedBLoad = Task {
            try await engine.load(request, identity: itemB)
        }
        await subtitleRepository.waitForResetCalls(2)
        engine.stop()
        await subtitleRepository.releaseReset()
        do {
            try await stoppedBLoad.value
            Issue.record("Stopped B load unexpectedly completed")
        } catch is CancellationError {
            // stop invalidates the queued load before subtitle preparation.
        }
        #expect(await subtitleRepository.trackRequests == [firstA, firstA])
        #expect(await subtitleRepository.resetCalls == [firstA, firstA])
        #expect(engine.player.currentItem == nil)
    }

    @Test(arguments: UnusableNativeSubtitleCatalog.allCases)
    func unusableSubtitleCatalogFallsBackToMediaOnly(
        _ catalog: UnusableNativeSubtitleCatalog
    ) async throws {
        let fixture = try makeSimpleMedia(host: "media-only.example")
        let bridge = DASHToHLSBridge(
            rangeClient: HTTPRangeClient(
                transport: FixtureRangeTransport(
                    media: fixture.media
                )
            )
        )

        let prepared = try await bridge.prepare(
            videos: [fixture.video],
            audioTracks: [makeSelectedAudioTrack(representation: fixture.audio)],
            headers: [:],
            subtitleSource: NativeSubtitleSource(
                useCase: SubtitleUseCase(repository: catalog.repository),
                identity: PlaybackItemIdentity(bvid: "BV1MediaOnly", cid: 303)
            )
        )
        defer { prepared.stop() }
        let master = try await fetchText(prepared.url)
        let localizedNames = try await localizedRenditionNames(
            besideMaster: prepared.url
        )

        #expect(master.contains("#EXT-X-STREAM-INF:"))
        #expect(!master.contains("TYPE=SUBTITLES"))
        #expect(localizedNames["原声"]?["en"] == "Original audio")
    }

    @Test
    func subtitleCatalogGraceDoesNotWaitForNoncooperativeRepository() async throws {
        let fixture = try makeSimpleMedia(host: "subtitle-timeout.example")
        let repository = FixtureSubtitleRepository(
            catalog: .heldUntilReleased([
                SubtitleTrack(
                    id: "late",
                    languageCode: "zh",
                    displayName: "中文",
                    kind: .standard
                )
            ])
        )
        let bridge = DASHToHLSBridge(
            rangeClient: HTTPRangeClient(
                transport: FixtureRangeTransport(
                    media: fixture.media
                )
            ),
            subtitleCatalogGrace: .milliseconds(20),
            serverFactory: { LoopbackPlaybackServer(rangeClient: $0) }
        )
        let source = NativeSubtitleSource(
            useCase: SubtitleUseCase(repository: repository),
            identity: PlaybackItemIdentity(
                bvid: "BV1SubtitleTimeout",
                cid: 305
            )
        )
        let prepareTask = Task {
            try await bridge.prepare(
                videos: [fixture.video],
                audioTracks: [makeSelectedAudioTrack(representation: fixture.audio)],
                headers: [:],
                subtitleSource: source
            )
        }
        await repository.waitForTrackRequests(1)
        let prepared = try await prepareTask.value
        defer { prepared.stop() }
        await repository.releaseTracks()

        let master = try await fetchText(prepared.url)
        #expect(!master.contains("TYPE=SUBTITLES"))
    }

    @Test
    @MainActor
    func enginePublishesTimelineAndClearsItWhenStopped() async throws {
        let videoData = try fixtureData(named: "video-avc")
        let audioData = try fixtureData(named: "audio-aac")
        let videoURL = try #require(URL(string: "https://timeline.example/video"))
        let audioURL = try #require(URL(string: "https://timeline.example/audio"))
        let video = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400b",
            bandwidth: 50_000,
            data: videoData,
            primaryURL: videoURL
        ).representation
        let audio = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 96_000,
            data: audioData,
            primaryURL: audioURL
        ).representation
        let transport = FixtureRangeTransport(
            media: [videoURL: videoData, audioURL: audioData]
        )
        let engine = AVPlayerEngine(
            bridge: DASHToHLSBridge(
                rangeClient: HTTPRangeClient(transport: transport)
            )
        )
        engine.player.isMuted = true
        let identity = PlaybackItemIdentity(
            bvid: "BV1TimelineFixture",
            cid: 900_001
        )
        let request = PlaybackRequest(
            manifest: PlaybackManifest(
                videoRepresentations: [video],
                originalAudioRepresentations: [audio]
            )
        )

        #expect(!engine.requestSeek(to: .seconds(0.5)))
        try await engine.load(request, identity: identity)
        let firstItem = try #require(engine.player.currentItem)
        let loadGeneration = engine.currentTimelineSnapshot
            .discontinuityGeneration
        #expect(engine.currentTimelineSnapshot.identity == identity)
        #expect(engine.currentTimelineSnapshot.state == .ready)

        try engine.setRate(1.25)
        engine.play()
        let playing = try await waitForTimeline(of: engine) {
            $0.positionSeconds >= 0.15 || $0.state == .failed
        }
        #expect(playing.state != .failed)
        #expect(engine.currentTimelineSnapshot.positionSeconds > 0)
        #expect(engine.currentTimelineSnapshot.rate > 1)
        #expect(engine.currentTimelineSnapshot.state == .playing)

        let normalMomentarySession = try #require(
            try engine.beginMomentaryPlaybackRate(2)
        )
        #expect(abs(engine.player.rate - 2) < 0.01)
        engine.endMomentaryPlaybackRate(
            sessionID: normalMomentarySession
        )
        #expect(abs(engine.player.rate - 1.25) < 0.01)

        let pausedMomentarySession = try #require(
            try engine.beginMomentaryPlaybackRate(0.5)
        )
        engine.pause()
        engine.endMomentaryPlaybackRate(
            sessionID: pausedMomentarySession
        )
        #expect(engine.currentTimelineSnapshot.rate == 0)
        #expect(engine.currentTimelineSnapshot.state == .paused)
        engine.play()
        #expect(abs(engine.player.rate - 1.25) < 0.01)

        let userOverrideSession = try #require(
            try engine.beginMomentaryPlaybackRate(2)
        )
        try engine.setRate(1.5)
        engine.endMomentaryPlaybackRate(sessionID: userOverrideSession)
        #expect(abs(engine.player.rate - 1.5) < 0.01)
        try engine.setRate(1.25)

        engine.pause()
        let requestedSeekGeneration = engine.currentTimelineSnapshot
            .discontinuityGeneration
        #expect(engine.requestSeek(to: .seconds(0.2)))
        #expect(engine.requestSeek(to: .seconds(0.5)))
        try await waitForTimeline(of: engine) { snapshot in
            snapshot.discontinuityGeneration > requestedSeekGeneration
                && abs(snapshot.positionSeconds - 0.5) < 0.05
        }
        #expect(
            engine.currentTimelineSnapshot.discontinuityGeneration
                == requestedSeekGeneration + 1
        )
        #expect(abs(engine.currentTimelineSnapshot.positionSeconds - 0.5) < 0.05)
        #expect(!engine.requestSeek(to: .seconds(10)))
        engine.play()

        try await engine.seek(to: .seconds(0.7))
        #expect(engine.currentTimelineSnapshot.positionSeconds >= 0.65)
        #expect(
            engine.currentTimelineSnapshot.discontinuityGeneration
                > loadGeneration
        )

        #expect(throws: AVPlayerEngineError.invalidPlaybackRate) {
            try engine.setRate(0)
        }

        let replacementIdentity = PlaybackItemIdentity(
            bvid: "BV1TimelineReplacement",
            cid: 900_002
        )
        let staleMomentarySession = try #require(
            try engine.beginMomentaryPlaybackRate(2)
        )
        #expect(engine.requestSeek(to: .seconds(0.2)))
        try await engine.load(request, identity: replacementIdentity)
        engine.endMomentaryPlaybackRate(sessionID: staleMomentarySession)
        #expect(engine.player.currentItem !== firstItem)
        NotificationCenter.default.post(
            name: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: firstItem
        )
        await Task { @MainActor in }.value
        #expect(engine.currentTimelineSnapshot.identity == replacementIdentity)
        #expect(engine.currentTimelineSnapshot.state == .ready)
        engine.play()
        #expect(abs(engine.player.rate - 1.25) < 0.01)

        let seekGeneration = engine.currentTimelineSnapshot
            .discontinuityGeneration
        let stoppedMomentarySession = try #require(
            try engine.beginMomentaryPlaybackRate(0.5)
        )
        #expect(engine.requestSeek(to: .seconds(0.2)))
        engine.stop()
        engine.endMomentaryPlaybackRate(sessionID: stoppedMomentarySession)
        await Task { @MainActor in }.value
        #expect(engine.player.currentItem == nil)
        #expect(engine.currentTimelineSnapshot.identity == nil)
        #expect(engine.currentTimelineSnapshot.state == .idle)
        #expect(
            engine.currentTimelineSnapshot.discontinuityGeneration
                > seekGeneration
        )
    }

    @Test
    @MainActor
    func engineDeduplicatesFailureNotificationAfterReady() async throws {
        let videoData = try fixtureBase64Data(
            named: "video-avc-256x144-4s-global-sidx.mp4"
        )
        let audioData = try fixtureBase64Data(
            named: "audio-aac-4s-global-sidx.mp4"
        )
        let videoURL = try #require(
            URL(string: "https://failure-event.example/video.mp4")
        )
        let audioURL = try #require(
            URL(string: "https://failure-event.example/audio.mp4")
        )
        let video = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400c",
            bandwidth: 100_000,
            data: videoData,
            primaryURL: videoURL
        ).representation
        let audio = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 32_000,
            data: audioData,
            primaryURL: audioURL
        ).representation
        let transport = FixtureRangeTransport(
            media: [
                videoURL: videoData,
                audioURL: audioData
            ]
        )
        let engine = AVPlayerEngine(
            bridge: DASHToHLSBridge(
                rangeClient: HTTPRangeClient(transport: transport)
            )
        )
        let failureRecorder = PlaybackFailureRecorder()
        let failureTask = Task {
            for await event in engine.playbackFailureEvents() {
                await failureRecorder.append(event)
            }
        }
        defer {
            failureTask.cancel()
            engine.stop()
        }
        let identity = PlaybackItemIdentity(
            bvid: "BV1FailureEventFixture",
            cid: 900_003
        )

        try await engine.load(
            PlaybackRequest(
                manifest: PlaybackManifest(
                    videoRepresentations: [video],
                    originalAudioRepresentations: [audio]
                )
            ),
            identity: identity
        )
        let item = try #require(engine.player.currentItem)

        NotificationCenter.default.post(
            name: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item
        )
        NotificationCenter.default.post(
            name: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item
        )

        await failureRecorder.waitForEvents(1)
        try await waitForTimeline(of: engine) { $0.state == .failed }
        let failureIdentities = await failureRecorder.identities()

        #expect(engine.currentTimelineSnapshot.state == .failed)
        #expect(failureIdentities == [identity])
        #expect(engine.player.currentItem == nil)
    }

    @Test
    @MainActor
    func replacingEngineLoadCancelsOldMediaRequests() async throws {
        let videoData = try fixtureData(named: "video-avc")
        let audioData = try fixtureData(named: "audio-aac")
        let oldVideoURL = try #require(URL(string: "https://old.example/video"))
        let oldAudioURL = try #require(URL(string: "https://old.example/audio"))
        let newVideoURL = try #require(URL(string: "https://new.example/video"))
        let newAudioURL = try #require(URL(string: "https://new.example/audio"))
        let oldVideo = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400b",
            bandwidth: 50_000,
            data: videoData,
            primaryURL: oldVideoURL
        ).representation
        let oldAudio = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 96_000,
            data: audioData,
            primaryURL: oldAudioURL
        ).representation
        let newVideo = try makeFixtureTrack(
            id: 64,
            kind: .video,
            codecs: "avc1.4d400b",
            bandwidth: 50_000,
            data: videoData,
            primaryURL: newVideoURL
        ).representation
        let newAudio = try makeFixtureTrack(
            id: 30_232,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 96_000,
            data: audioData,
            primaryURL: newAudioURL
        ).representation
        let transport = FixtureRangeTransport(
            media: [
                oldVideoURL: videoData,
                oldAudioURL: audioData,
                newVideoURL: videoData,
                newAudioURL: audioData
            ],
            blockingURLIndexRanges: [
                oldVideoURL: oldVideo.segmentBase.index,
                oldAudioURL: oldAudio.segmentBase.index
            ]
        )
        let engine = AVPlayerEngine(
            bridge: DASHToHLSBridge(
                rangeClient: HTTPRangeClient(transport: transport)
            )
        )
        engine.player.isMuted = true
        let oldRequest = PlaybackRequest(
            manifest: PlaybackManifest(
                videoRepresentations: [oldVideo],
                originalAudioRepresentations: [oldAudio]
            )
        )
        let newRequest = PlaybackRequest(
            manifest: PlaybackManifest(
                videoRepresentations: [newVideo],
                originalAudioRepresentations: [newAudio]
            )
        )

        let oldLoad = Task { @MainActor in
            try await engine.load(
                oldRequest,
                identity: PlaybackItemIdentity(
                    bvid: "BV1OldFixture",
                    cid: 900_001
                )
            )
        }
        await transport.waitForBlockedRequest()

        try await engine.load(
            newRequest,
            identity: PlaybackItemIdentity(
                bvid: "BV1NewFixture",
                cid: 900_002
            )
        )
        await #expect(throws: CancellationError.self) {
            try await oldLoad.value
        }

        #expect(await transport.cancelledBlockedRequestCount > 0)
        #expect(engine.player.currentItem?.status == .readyToPlay)
    }

    @Test
    @MainActor
    func replacementAndReleaseStopEveryPreviousLoopbackSession() async throws {
        let fixture = try makeSimpleMedia(host: "fixture.example")
        var engine: AVPlayerEngine? = AVPlayerEngine(
            bridge: DASHToHLSBridge(
                rangeClient: HTTPRangeClient(
                    transport: FixtureRangeTransport(
                        media: fixture.media
                    )
                )
            )
        )
        engine?.player.isMuted = true
        let request = PlaybackRequest(
            manifest: PlaybackManifest(
                videoRepresentations: [fixture.video],
                originalAudioRepresentations: [fixture.audio]
            )
        )

        var masterURLs: [URL] = []
        for cid in 1...3 {
            try await engine?.load(
                request,
                identity: PlaybackItemIdentity(
                    bvid: "BV1LoopFixture",
                    cid: Int64(900_000 + cid)
                )
            )
            let asset = try #require(
                engine?.player.currentItem?.asset as? AVURLAsset
            )
            masterURLs.append(asset.url)
            #expect(await isServing(asset.url))
            for previousURL in masterURLs.dropLast() {
                #expect(!(await isServing(previousURL)))
            }
        }

        weak let releasedEngine = engine
        engine = nil
        #expect(releasedEngine == nil)
        for url in masterURLs {
            #expect(!(await isServing(url)))
        }
    }
}

/// 两种不可用的原生字幕目录：拉取失败，或标签不安全／归一化后重名。
enum UnusableNativeSubtitleCatalog: CaseIterable, Sendable {
    case failing
    case unsafeLabels

    var repository: any SubtitleRepository {
        switch self {
        case .failing:
            FixtureSubtitleRepository(catalog: .failure)
        case .unsafeLabels:
            FixtureSubtitleRepository(
                catalog: .tracks([
                    SubtitleTrack(
                        id: "unsafe",
                        languageCode: "unknown",
                        displayName: "unsafe\\label",
                        kind: .unknown
                    ),
                    SubtitleTrack(
                        id: "authored-duplicate-label",
                        languageCode: "zh",
                        displayName: "中文（AI）",
                        kind: .standard
                    ),
                    SubtitleTrack(
                        id: "automatic-duplicate-label",
                        languageCode: "ai-zh",
                        displayName: "中文",
                        kind: .automatic
                    )
                ])
            )
        }
    }
}
