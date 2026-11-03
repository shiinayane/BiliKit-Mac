@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliPlayback

/// AVPlayer 引擎的起播、生命周期与字幕三组测试共用真实 AVPlayer 与 loopback server，
/// 放在同一个串行父 Suite 下，组与组之间也不并行。
@Suite(.serialized, .timeLimit(.minutes(2)))
enum AVPlayerEngineSuites {}

extension AVPlayerEngineSuites {
    /// 固定引擎生命周期契约：时间线随播放、倍速、seek、替换与停止发布，就绪后的失败通知去重，
    /// 每次 `playbackFailureEvents()` 是独立订阅、取消其中一个不影响其他订阅，progressive item 就绪时
    /// 带有效的正向结束时间，替换 load 取消旧媒体请求，替换与释放停止此前所有 loopback 会话。
    @Suite(.serialized, .timeLimit(.minutes(2)))
    struct AVPlayerEngineLifecycleTests {
        @Test
        @MainActor
        func enginePublishesTimelineAndClearsItWhenStopped() async throws {
            let videoData = try fixtureData(named: "video-avc")
            let audioData = try fixtureData(named: "audio-aac")
            let videoURL = try #require(URL(string: "https://timeline.fixture.bilivideo.com/video"))
            let audioURL = try #require(URL(string: "https://timeline.fixture.bilivideo.com/audio"))
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
            let engine = makeFixtureEngine(
                bridge: makeFixtureBridge(transport)
            )
            engine.player.isMuted = true
            let identity = PlaybackItemIdentity(
                bvid: "BV1TimelineFixture",
                cid: 900_001
            )
            let request = PlaybackRequest(
                media: .dash(
                    PlaybackManifest(
                        videoRepresentations: [video],
                        audioTracks: [.original(representations: [audio], loudnessMetadata: nil)]
                    )
                )
            )

            #expect(!engine.requestSeek(to: .seconds(0.5)))
            try await engine.load(request, identity: identity)
            let firstItem = try #require(engine.player.currentItem)
            let loadGeneration = engine.currentTimelineSnapshot
                .discontinuityGeneration
            #expect(engine.currentTimelineSnapshot.identity == identity)
            #expect(engine.currentTimelineSnapshot.state == .ready)

            engine.player.defaultRate = 1.25
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
            engine.player.defaultRate = 1.5
            engine.endMomentaryPlaybackRate(sessionID: userOverrideSession)
            #expect(abs(engine.player.rate - 1.5) < 0.01)
            engine.player.defaultRate = 1.25

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

            let playingSeekGeneration = engine.currentTimelineSnapshot
                .discontinuityGeneration
            #expect(engine.requestSeek(to: .seconds(0.7)))
            try await waitForTimeline(of: engine) { snapshot in
                snapshot.discontinuityGeneration > playingSeekGeneration
                    && snapshot.positionSeconds >= 0.65
            }
            #expect(
                engine.currentTimelineSnapshot.discontinuityGeneration
                    > loadGeneration
            )

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
                URL(string: "https://failure-event.fixture.bilivideo.com/video.mp4")
            )
            let audioURL = try #require(
                URL(string: "https://failure-event.fixture.bilivideo.com/audio.mp4")
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
            let engine = makeFixtureEngine(
                bridge: makeFixtureBridge(transport)
            )
            let failureRecorder = PlaybackFailureRecorder()
            let failureEvents = engine.playbackFailureEvents()
            let failureTask = Task {
                for await event in failureEvents {
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
                    media: .dash(
                        PlaybackManifest(
                            videoRepresentations: [video],
                            audioTracks: [
                                .original(representations: [audio], loudnessMetadata: nil)
                            ]
                        )
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
        func everyLiveSubscriberReceivesTheFailureAfterAnotherIsCancelled() async throws {
            let fixture = try makeSimpleMedia(host: "failure-subscribers.fixture.bilivideo.com")
            let engine = makeFixtureEngine(
                bridge: makeFixtureBridge(FixtureRangeTransport(media: fixture.media))
            )
            engine.player.isMuted = true
            defer { engine.stop() }
            let cancelled = engine.playbackFailureEvents()
            var first = engine.playbackFailureEvents().makeAsyncIterator()
            var second = engine.playbackFailureEvents().makeAsyncIterator()
            let cancelledConsumer = Task {
                for await _ in cancelled {}
            }
            cancelledConsumer.cancel()
            await cancelledConsumer.value
            let identity = PlaybackItemIdentity(bvid: "BV1FailureSubscribers", cid: 900_020)

            try await engine.load(
                PlaybackRequest(
                    media: .dash(
                        PlaybackManifest(
                            videoRepresentations: [fixture.video],
                            audioTracks: [
                                .original(representations: [fixture.audio], loudnessMetadata: nil)
                            ]
                        )
                    )
                ),
                identity: identity
            )
            let item = try #require(engine.player.currentItem)
            NotificationCenter.default.post(
                name: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: item
            )

            #expect(await first.next()?.identity == identity)
            #expect(await second.next()?.identity == identity)
        }

        @Test
        @MainActor
        func progressiveItemCarriesForwardPlaybackEndTime() async throws {
            let source = try #require(
                URL(string: "https://primary.fixture.bilivideo.com/video.mp4")
            )
            let body = try fixtureData(named: "video-avc")
            let engine = makeFixtureEngine(
                bridge: makeFixtureBridge(FixtureRangeTransport(media: [source: body]))
            )
            defer { engine.stop() }

            try await engine.load(
                PlaybackRequest(
                    media: .progressive(
                        ProgressivePlaybackSource(
                            primaryURL: source,
                            contentLength: Int64(body.count),
                            durationMilliseconds: 1_000,
                            contentType: "video/mp4",
                            container: .mp4
                        )
                    )
                ),
                identity: PlaybackItemIdentity(bvid: "BVProgressiveFixture", cid: 1)
            )

            let item = try #require(engine.player.currentItem)
            #expect(item.forwardPlaybackEndTime.isValid)
            #expect(item.forwardPlaybackEndTime.seconds > 0)
        }

        @Test
        @MainActor
        func replacingEngineLoadCancelsOldMediaRequests() async throws {
            let videoData = try fixtureData(named: "video-avc")
            let audioData = try fixtureData(named: "audio-aac")
            let oldVideoURL = try #require(URL(string: "https://old.fixture.bilivideo.com/video"))
            let oldAudioURL = try #require(URL(string: "https://old.fixture.bilivideo.com/audio"))
            let newVideoURL = try #require(URL(string: "https://new.fixture.bilivideo.com/video"))
            let newAudioURL = try #require(URL(string: "https://new.fixture.bilivideo.com/audio"))
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
            let engine = makeFixtureEngine(
                bridge: makeFixtureBridge(transport)
            )
            engine.player.isMuted = true
            let oldRequest = PlaybackRequest(
                media: .dash(
                    PlaybackManifest(
                        videoRepresentations: [oldVideo],
                        audioTracks: [.original(representations: [oldAudio], loudnessMetadata: nil)]
                    )
                )
            )
            let newRequest = PlaybackRequest(
                media: .dash(
                    PlaybackManifest(
                        videoRepresentations: [newVideo],
                        audioTracks: [.original(representations: [newAudio], loudnessMetadata: nil)]
                    )
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
            let fixture = try makeSimpleMedia(host: "media.fixture.bilivideo.com")
            var engine: AVPlayerEngine? = makeFixtureEngine(
                bridge: makeFixtureBridge(
                    FixtureRangeTransport(
                        media: fixture.media
                    )
                )
            )
            engine?.player.isMuted = true
            let request = PlaybackRequest(
                media: .dash(
                    PlaybackManifest(
                        videoRepresentations: [fixture.video],
                        audioTracks: [
                            .original(representations: [fixture.audio], loudnessMetadata: nil)
                        ]
                    )
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
}
