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
struct LoopbackPlaybackServerTests {
    @Test
    func independentProcessEnforcesLoopbackCapabilityBoundary() async throws {
        let server = LoopbackPlaybackServer()
        try await server.start()
        let url = try server.register(
            .inMemory(
                data: Data([0x4F, 0x4B]),
                contentType: "application/octet-stream"
            ),
            at: "boundary.bin"
        )
        guard let port = url.port else {
            throw LoopbackFixtureError.missingPort
        }

        let acceptedStatus = try independentHTTPStatus(
            port: port,
            target: url.path,
            host: "127.0.0.1:\(port)"
        )
        let rejectedTokenStatus = try independentHTTPStatus(
            port: port,
            target: "/00000000000000000000000000000000/boundary.bin",
            host: "127.0.0.1:\(port)"
        )
        let rejectedPathStatus = try independentHTTPStatus(
            port: port,
            target: "\(url.path)/extra",
            host: "127.0.0.1:\(port)"
        )
        let untrustedHostStatus = try independentHTTPStatus(
            port: port,
            target: url.path,
            host: "attacker.invalid"
        )
        let missingHostStatus = try independentHTTPStatus(
            port: port,
            target: url.path,
            hostHeaders: []
        )
        let duplicateHostStatus = try independentHTTPStatus(
            port: port,
            target: url.path,
            hostHeaders: [
                "127.0.0.1:\(port)",
                "attacker.invalid"
            ]
        )
        let malformedHostStatus = try independentHTTPStatus(
            port: port,
            target: url.path,
            host: "127.0.0.1:not-a-port"
        )

        #expect(acceptedStatus == 200)
        #expect(rejectedTokenStatus == 404)
        #expect(rejectedPathStatus == 404)
        #expect(untrustedHostStatus == 400)
        #expect(missingHostStatus == 400)
        #expect(duplicateHostStatus == 400)
        #expect(malformedHostStatus == 400)

        try exerciseIndependentDisconnects(
            port: port,
            target: url.path
        )
        // 半截请求后断开的客户端不能让 server 卡住或占住后续请求。
        #expect(
            try independentHTTPStatus(
                port: port,
                target: url.path,
                host: "127.0.0.1:\(port)"
            ) == 200
        )
        server.stop()
        try await waitForIndependentProcessToRejectConnections(port: port)
    }

    @Test
    func remoteResourceStaysOnItsPreparedSourceAcrossRanges() async throws {
        let primary = try #require(
            URL(string: "https://primary.example/media.mp4")
        )
        let backup = try #require(
            URL(string: "https://backup.example/media.mp4")
        )
        let transport = CrossIdentityFallbackTransport(
            primary: primary,
            backup: backup
        )
        let server = LoopbackPlaybackServer(
            rangeClient: HTTPRangeClient(transport: transport)
        )
        try await server.start()
        defer { server.stop() }
        let url = try server.register(
            .remote(
                try LoopbackRemoteResource(
                    sourceURL: primary,
                    contentLength: 4,
                    contentType: "video/mp4"
                )
            ),
            at: "remote.mp4"
        )

        var firstRequest = URLRequest(url: url)
        firstRequest.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        let (firstBody, firstResponse) = try await URLSession.shared.data(
            for: firstRequest
        )
        var secondRequest = URLRequest(url: url)
        secondRequest.setValue("bytes=2-3", forHTTPHeaderField: "Range")
        let (secondBody, secondResponse) = try await URLSession.shared.data(
            for: secondRequest
        )

        #expect((firstResponse as? HTTPURLResponse)?.statusCode == 206)
        #expect((secondResponse as? HTTPURLResponse)?.statusCode == 502)
        #expect(firstBody == Data([0x41, 0x41]))
        #expect(secondBody.isEmpty)
        let requestedURLs = await transport.requestedURLs
        #expect(requestedURLs == [primary, primary])
    }

    @Test(arguments: loopbackGETRangeCases)
    func loopbackGETServesSingleRangesAndIgnoresUnsupportedOnes(
        _ testCase: LoopbackGETRangeCase
    ) async throws {
        let (body, response) = try await requestFiveByteResource(
            method: "GET",
            range: testCase.range
        )

        #expect(response.statusCode == testCase.status)
        #expect(
            response.value(forHTTPHeaderField: "Content-Length")
                == String(testCase.body.count)
        )
        #expect(
            response.value(forHTTPHeaderField: "Content-Range")
                == testCase.contentRange
        )
        #expect(body == Data(testCase.body))
    }

    @Test(
        arguments: [
            nil, "bytes=1-3", "bytes=-2", "bytes=5-", "bytes=0-0,2-2", "items=0-1"
        ] as [String?]
    )
    func loopbackHEADIgnoresRange(_ range: String?) async throws {
        let (body, response) = try await requestFiveByteResource(
            method: "HEAD",
            range: range
        )

        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Length") == "5")
        #expect(response.value(forHTTPHeaderField: "Content-Range") == nil)
        #expect(body.isEmpty)
    }

    @Test
    func remoteRangeErrorsStayLocalAndSuffixIsForwardedAsClosedRange() async throws {
        let remoteURL = try #require(
            URL(string: "https://media.fixture.bilivideo.com/remote.mp4")
        )
        let media = Data([0, 1, 2, 3, 4])
        let transport = FixtureRangeTransport(
            media: [remoteURL: media],
            failingURLs: []
        )
        let server = LoopbackPlaybackServer(
            rangeClient: HTTPRangeClient(transport: transport)
        )
        try await server.start()
        defer { server.stop() }
        let url = try server.register(
            .remote(
                try LoopbackRemoteResource(
                    sourceURL: remoteURL,
                    contentLength: Int64(media.count),
                    contentType: "video/mp4"
                )
            ),
            at: "remote-range-errors.mp4"
        )

        for range in ["items=0-1", "bytes=0-0,2-2"] {
            var request = URLRequest(url: url)
            request.setValue(range, forHTTPHeaderField: "Range")
            let (body, response) = try await URLSession.shared.data(for: request)

            #expect((response as? HTTPURLResponse)?.statusCode == 400)
            #expect(body.isEmpty)
        }
        #expect(await transport.requests.isEmpty)

        var unsatisfiableRequest = URLRequest(url: url)
        unsatisfiableRequest.setValue(
            "bytes=5-",
            forHTTPHeaderField: "Range"
        )
        let (unsatisfiableBody, unsatisfiableResponse) =
            try await URLSession.shared.data(for: unsatisfiableRequest)
        let unsatisfiableHTTPResponse = try #require(
            unsatisfiableResponse as? HTTPURLResponse
        )
        #expect(unsatisfiableHTTPResponse.statusCode == 416)
        #expect(
            unsatisfiableHTTPResponse.value(
                forHTTPHeaderField: "Content-Range"
            ) == "bytes */5"
        )
        #expect(unsatisfiableBody.isEmpty)
        #expect(await transport.requests.isEmpty)

        var suffixRequest = URLRequest(url: url)
        suffixRequest.setValue("bytes=-2", forHTTPHeaderField: "Range")
        let (suffixBody, suffixResponse) = try await URLSession.shared.data(
            for: suffixRequest
        )
        #expect((suffixResponse as? HTTPURLResponse)?.statusCode == 206)
        #expect(suffixBody == Data([3, 4]))
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].headers["Range"] == "bytes=3-4")
    }

    @Test
    func bridgeIFramePlaylistAddressesFullSIDXFragments() async throws {
        let videoData = try markingTypeOneSAP(
            in: fixtureBase64Data(
                named: "video-avc-128x72-4s-global-sidx.mp4"
            )
        )
        let audioData = try fixtureBase64Data(
            named: "audio-aac-4s-global-sidx.mp4"
        )
        let videoURL = try #require(
            URL(string: "https://iframe-full-fragment.example/video.mp4")
        )
        let audioURL = try #require(
            URL(string: "https://iframe-full-fragment.example/audio.mp4")
        )
        let videoFixture = try makeFixtureTrack(
            id: 64,
            kind: .video,
            codecs: "avc1.4d400a",
            bandwidth: 50_000,
            data: videoData,
            primaryURL: videoURL
        )
        let audio = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 32_000,
            data: audioData,
            primaryURL: audioURL
        ).representation
        let bridge = DASHToHLSBridge(
            rangeClient: HTTPRangeClient(
                transport: FixtureRangeTransport(
                    media: [videoURL: videoData, audioURL: audioData],
                    failingURLs: []
                )
            )
        )

        let prepared = try await bridge.prepare(
            video: videoFixture.representation,
            audioTracks: [makeSelectedAudioTrack(representation: audio)]
        )
        defer { prepared.stop() }
        let master = try await fetchText(prepared.url)
        let iFramePlaylistURL = prepared.url.deletingLastPathComponent()
            .appending(path: "video/64-iframe.m3u8")
        let iFramePlaylist = try await fetchText(iFramePlaylistURL)
        let byteRangePrefix = "#EXT-X-BYTERANGE:"
        let iFrameByteRanges = iFramePlaylist.split(separator: "\n")
            .filter { $0.hasPrefix(byteRangePrefix) }
            .map { String($0.dropFirst(byteRangePrefix.count)) }
        let fullFragmentByteRanges = videoFixture.index.references.map {
            let range = $0.byteRange
            return "\(range.endInclusive - range.start + 1)@\(range.start)"
        }

        #expect(
            master.contains(
                #"URI="\#(iFramePlaylistURL.absoluteString)""#
            )
        )
        #expect(iFramePlaylist.contains("#EXT-X-I-FRAMES-ONLY"))
        #expect(!fullFragmentByteRanges.isEmpty)
        #expect(iFrameByteRanges == fullFragmentByteRanges)
    }

    @Test
    func bridgeRejectsUnsupportedAudioTrackCountsBeforeStartingServer()
        async throws
    {
        let video = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400b",
            bandwidth: 50_000,
            data: try fixtureData(named: "video-avc")
        ).representation
        let audio = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 96_000,
            data: try fixtureData(named: "audio-aac")
        ).representation
        let registry = LoopbackServerRegistry()
        let bridge = DASHToHLSBridge(
            rangeClient: HTTPRangeClient(),
            serverFactory: { rangeClient in
                registry.create(rangeClient: rangeClient)
            }
        )
        let original = makeSelectedAudioTrack(representation: audio)
        let alternate = makeSelectedAudioTrack(
            trackID: "alternate",
            representation: audio
        )

        await #expect(
            throws: DASHToHLSBridgeError.unsupportedAudioTrackCount(0)
        ) {
            try await bridge.prepare(video: video, audioTracks: [])
        }
        await #expect(
            throws: DASHToHLSBridgeError.unsupportedAudioTrackCount(2)
        ) {
            try await bridge.prepare(
                video: video,
                audioTracks: [original, alternate]
            )
        }
        let mismatched = SelectedPlaybackAudioTrack(
            track: original.track,
            representation: video
        )
        await #expect(
            throws: DASHToHLSBridgeError.invalidAudioTrackSelection(
                trackID: "original",
                representationID: video.id
            )
        ) {
            try await bridge.prepare(
                video: video,
                audioTracks: [mismatched]
            )
        }
        #expect(registry.servers.isEmpty)
    }

    @Test
    func bridgePublishesOriginalAndMachineGeneratedAudioRoutes() async throws {
        let videoData = try fixtureData(named: "video-avc")
        let audioData = try fixtureData(named: "audio-aac")
        let videoURL = try #require(
            URL(string: "https://multi-audio.example/video")
        )
        let originalURL = try #require(
            URL(string: "https://multi-audio.example/original")
        )
        let aiURL = try #require(
            URL(string: "https://multi-audio.example/ai-en")
        )
        let video = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400b",
            bandwidth: 50_000,
            data: videoData,
            primaryURL: videoURL
        ).representation
        let original = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 96_000,
            data: audioData,
            primaryURL: originalURL
        ).representation
        let ai = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 96_000,
            data: audioData,
            primaryURL: aiURL
        ).representation
        let transport = FixtureRangeTransport(
            media: [
                videoURL: videoData,
                originalURL: audioData,
                aiURL: audioData
            ],
            failingURLs: []
        )
        let bridge = DASHToHLSBridge(
            rangeClient: HTTPRangeClient(transport: transport)
        )

        let prepared = try await bridge.prepare(
            video: video,
            audioTracks: [
                makeSelectedAudioTrack(representation: original),
                makeSelectedAudioTrack(
                    trackID: "machine-generated:en",
                    displayName: "English（AI）",
                    languageTag: "en",
                    role: .machineGenerated,
                    isDefault: false,
                    representation: ai
                )
            ]
        )
        defer { prepared.stop() }
        let masterData = try await URLSession.shared.data(from: prepared.url).0
        let master = try #require(String(data: masterData, encoding: .utf8))

        #expect(master.contains(#"GROUP-ID="audio",NAME="原声""#))
        #expect(
            master.contains(
                #"NAME="English（AI）",LANGUAGE="en",CHARACTERISTICS="public.machine-generated""#
            )
        )
        #expect(master.contains("/audio/0/30280.m3u8"))
        #expect(master.contains("/audio/1/30280.m3u8"))
        #expect(!master.contains("public.translation"))

        prepared.stop()
        let fallbackTransport = FixtureRangeTransport(
            media: [
                videoURL: videoData,
                originalURL: audioData,
                aiURL: audioData
            ],
            failingURLs: [],
            unknownLengthURLs: [aiURL]
        )
        let fallbackBridge = DASHToHLSBridge(
            rangeClient: HTTPRangeClient(transport: fallbackTransport)
        )
        let fallbackPrepared = try await fallbackBridge.prepare(
            video: video,
            audioTracks: [
                makeSelectedAudioTrack(representation: original),
                makeSelectedAudioTrack(
                    trackID: "machine-generated:en",
                    displayName: "English（AI）",
                    languageTag: "en",
                    role: .machineGenerated,
                    isDefault: false,
                    representation: ai
                )
            ]
        )
        defer { fallbackPrepared.stop() }
        let fallbackData = try await URLSession.shared.data(
            from: fallbackPrepared.url
        ).0
        let fallbackMaster = try #require(
            String(data: fallbackData, encoding: .utf8)
        )
        #expect(fallbackMaster.contains(#"GROUP-ID="audio-30280",NAME="原声""#))
        #expect(!fallbackMaster.contains("English（AI）"))
    }

    @Test
    func bridgeOmitsMachineGeneratedAudioWithShiftedTimeline() async throws {
        let videoData = try fixtureData(named: "video-avc")
        let originalData = try fixtureData(named: "audio-aac")
        let shiftedAIData = try settingSIDXEarliestPresentationTime(
            90,
            in: originalData
        )
        let videoURL = try #require(
            URL(string: "https://multi-audio-timeline.example/video")
        )
        let originalURL = try #require(
            URL(string: "https://multi-audio-timeline.example/original")
        )
        let aiURL = try #require(
            URL(string: "https://multi-audio-timeline.example/ai-en")
        )
        let video = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400b",
            bandwidth: 50_000,
            data: videoData,
            primaryURL: videoURL
        ).representation
        let original = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 96_000,
            data: originalData,
            primaryURL: originalURL
        ).representation
        let ai = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 96_000,
            data: shiftedAIData,
            primaryURL: aiURL
        ).representation
        let bridge = DASHToHLSBridge(
            rangeClient: HTTPRangeClient(
                transport: FixtureRangeTransport(
                    media: [
                        videoURL: videoData,
                        originalURL: originalData,
                        aiURL: shiftedAIData
                    ],
                    failingURLs: []
                )
            )
        )

        let prepared = try await bridge.prepare(
            video: video,
            audioTracks: [
                makeSelectedAudioTrack(representation: original),
                makeSelectedAudioTrack(
                    trackID: "machine-generated:en",
                    displayName: "English（AI）",
                    languageTag: "en",
                    role: .machineGenerated,
                    isDefault: false,
                    representation: ai
                )
            ]
        )
        defer { prepared.stop() }
        let masterData = try await URLSession.shared.data(from: prepared.url).0
        let master = try #require(String(data: masterData, encoding: .utf8))

        #expect(master.contains(#"GROUP-ID="audio-30280",NAME="原声""#))
        #expect(!master.contains("English（AI）"))
        #expect(!master.contains("/audio/1/30280.m3u8"))
    }

    @Test
    func bridgeDoesNotBorrowAudioFormatFromDifferentCDN() async throws {
        let videoData = try fixtureData(named: "video-avc")
        let audioData = try fixtureData(named: "audio-aac")
        var primaryAudioData = audioData
        let movieBox = try #require(
            firstTopLevelBox(named: "moov", in: primaryAudioData)
        )
        primaryAudioData.replaceSubrange(
            (movieBox.offset + 4)..<(movieBox.offset + 8),
            with: Data("free".utf8)
        )

        let videoURL = try #require(
            URL(string: "https://format-source.example/video")
        )
        let primaryAudioURL = try #require(
            URL(string: "https://format-source.example/audio-primary")
        )
        let backupAudioURL = try #require(
            URL(string: "https://format-source.example/audio-backup")
        )
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
            primaryURL: primaryAudioURL,
            backupURLs: [backupAudioURL]
        ).representation
        let transport = FixtureRangeTransport(
            media: [
                videoURL: videoData,
                primaryAudioURL: primaryAudioData,
                backupAudioURL: audioData
            ],
            failingURLs: []
        )
        let bridge = DASHToHLSBridge(
            rangeClient: HTTPRangeClient(transport: transport)
        )

        let prepared = try await bridge.prepare(
            video: video,
            audioTracks: [makeSelectedAudioTrack(representation: audio)]
        )
        defer { prepared.stop() }
        let masterData = try await URLSession.shared.data(from: prepared.url).0
        let master = try #require(String(data: masterData, encoding: .utf8))
        let requests = await transport.requests

        #expect(!master.contains("CHANNELS="))
        #expect(!master.contains("BIT-DEPTH="))
        #expect(!master.contains("SAMPLE-RATE="))
        #expect(requests.filter { $0.url == primaryAudioURL }.count == 2)
        #expect(requests.allSatisfy { $0.url != backupAudioURL })
    }

    @Test
    func bridgeKeepsSuccessfulCDNsForLoopbackMediaRanges() async throws {
        let videoData = try fixtureData(named: "video-avc")
        let audioData = try fixtureData(named: "audio-aac")
        let primaryVideo = try #require(URL(string: "https://primary.example/video"))
        let backupVideo = try #require(URL(string: "https://backup.example/video"))
        let primaryAudio = try #require(URL(string: "https://primary.example/audio"))
        let backupAudio = try #require(URL(string: "https://backup.example/audio"))
        let video = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400b",
            bandwidth: 50_000,
            data: videoData,
            primaryURL: primaryVideo,
            backupURLs: [backupVideo]
        ).representation
        let audio = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 96_000,
            data: audioData,
            primaryURL: primaryAudio,
            backupURLs: [backupAudio]
        ).representation
        let transport = FixtureRangeTransport(
            media: [
                backupVideo: videoData,
                backupAudio: audioData
            ],
            failingURLs: [primaryVideo, primaryAudio]
        )
        let bridge = DASHToHLSBridge(
            rangeClient: HTTPRangeClient(transport: transport)
        )

        let prepared = try await bridge.prepare(
            video: video,
            audioTracks: [makeSelectedAudioTrack(representation: audio)]
        )
        defer { prepared.stop() }
        let preparationRequestCount = await transport.requests.count
        let sessionRoot = prepared.url.deletingLastPathComponent()
        for mediaPath in ["media/video/80.mp4", "media/audio/0/30280.mp4"] {
            var request = URLRequest(url: sessionRoot.appending(path: mediaPath))
            request.setValue("bytes=0-99", forHTTPHeaderField: "Range")
            let (body, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 206)
            #expect(body.count == 100)
        }

        let requests = await transport.requests
        #expect(
            requests.dropFirst(preparationRequestCount).map(\.url)
                == [backupVideo, backupAudio]
        )
        #expect(requests.filter { $0.url == primaryVideo }.count == 1)
        #expect(requests.filter { $0.url == primaryAudio }.count == 1)
    }

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
                        media: [videoURL: videoData, audioURL: audioData],
                        failingURLs: []
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
        let subtitleRepository = NativeSubtitleFixtureRepository()
        let engine = AVPlayerEngine(
            bridge: DASHToHLSBridge(
                rangeClient: HTTPRangeClient(
                    transport: FixtureRangeTransport(
                        media: fixture.media,
                        failingURLs: []
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

        await subtitleRepository.releaseCurrentReset()
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
        await subtitleRepository.releaseCurrentReset()
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
                    media: fixture.media,
                    failingURLs: []
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
        let repository = NoncooperativeNativeSubtitleRepository()
        let bridge = DASHToHLSBridge(
            rangeClient: HTTPRangeClient(
                transport: FixtureRangeTransport(
                    media: fixture.media,
                    failingURLs: []
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
        await repository.waitUntilStarted()
        let prepared = try await prepareTask.value
        defer { prepared.stop() }
        await repository.release()

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
            media: [videoURL: videoData, audioURL: audioData],
            failingURLs: []
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
        try await waitUntilPlaybackTime(engine.player, reaches: 0.15)
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
        try await waitUntilAsync {
            let snapshot = engine.currentTimelineSnapshot
            return snapshot.discontinuityGeneration > requestedSeekGeneration
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
            ],
            failingURLs: []
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

        try await waitUntilAsync {
            let identityCount = await failureRecorder.identities().count
            return identityCount == 1
                && engine.currentTimelineSnapshot.state == .failed
        }
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
        let transport = ReplacementRangeTransport(
            media: [
                oldVideoURL: videoData,
                oldAudioURL: audioData,
                newVideoURL: videoData,
                newAudioURL: audioData
            ],
            indexRanges: [
                oldVideoURL: oldVideo.segmentBase.index,
                oldAudioURL: oldAudio.segmentBase.index,
                newVideoURL: newVideo.segmentBase.index,
                newAudioURL: newAudio.segmentBase.index
            ],
            blockedMediaURLs: [oldVideoURL, oldAudioURL]
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
        await transport.waitForStartedMediaRequest()

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

        #expect(await transport.cancelledMediaRequestCount > 0)
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
                        media: fixture.media,
                        failingURLs: []
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

    private func requestFiveByteResource(
        method: String,
        range: String?
    ) async throws -> (Data, HTTPURLResponse) {
        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }
        let url = try server.register(
            .inMemory(
                data: Data([0, 1, 2, 3, 4]),
                contentType: "application/octet-stream"
            ),
            at: "range.bin"
        )
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(range, forHTTPHeaderField: "Range")
        let (body, response) = try await URLSession.shared.data(for: request)
        return (body, try #require(response as? HTTPURLResponse))
    }

    private func fetchText(_ url: URL) async throws -> String {
        let data = try await URLSession.shared.data(from: url).0
        return try #require(String(data: data, encoding: .utf8))
    }

    private func localizedRenditionNames(
        besideMaster masterURL: URL
    ) async throws -> [String: [String: String]] {
        let url = masterURL.deletingLastPathComponent()
            .appending(path: "metadata/localized-rendition-names.json")
        let data = try await URLSession.shared.data(from: url).0
        return try #require(
            try JSONSerialization.jsonObject(with: data)
                as? [String: [String: String]]
        )
    }

    /// 两秒 128x72 AVC 与 AAC fixture，挂在给定 host 的独立远端 URL 上。
    private func makeSimpleMedia(
        host: String
    ) throws -> (
        video: MediaRepresentation,
        audio: MediaRepresentation,
        media: [URL: Data]
    ) {
        let videoData = try fixtureData(named: "video-avc")
        let audioData = try fixtureData(named: "audio-aac")
        let videoURL = try #require(URL(string: "https://\(host)/video"))
        let audioURL = try #require(URL(string: "https://\(host)/audio"))
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
        return (video, audio, [videoURL: videoData, audioURL: audioData])
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "mp4",
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    private func fixtureBase64Data(named name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "base64",
                subdirectory: "Fixtures"
            )
        )
        return try #require(
            Data(
                base64Encoded: try Data(contentsOf: url),
                options: .ignoreUnknownCharacters
            )
        )
    }

    private func makeFixtureTrack(
        id: Int,
        kind: MediaKind,
        codecs: String,
        bandwidth: Int,
        data: Data,
        primaryURL: URL? = nil,
        backupURLs: [URL] = [],
        videoAttributes: VideoRepresentationAttributes? = nil
    ) throws -> (representation: MediaRepresentation, index: SegmentIndex) {
        let sidx = try #require(firstTopLevelBox(named: "sidx", in: data))
        let resolvedVideoAttributes: VideoRepresentationAttributes? =
            if kind == .video {
                if let videoAttributes {
                    videoAttributes
                } else {
                    try VideoRepresentationAttributes(
                        width: 128,
                        height: 72,
                        frameRate: 24
                    )
                }
            } else {
                nil
            }
        let representation = MediaRepresentation(
            id: id,
            kind: kind,
            codecs: codecs,
            mimeType: kind == .video ? "video/mp4" : "audio/mp4",
            bandwidth: bandwidth,
            videoAttributes: resolvedVideoAttributes,
            primaryURL: try primaryURL ?? #require(
                URL(string: "https://fixture.invalid/\(id)")
            ),
            backupURLs: backupURLs,
            segmentBase: SegmentBase(
                initialization: try MediaByteRange(
                    start: 0,
                    endInclusive: Int64(sidx.offset - 1)
                ),
                index: try MediaByteRange(
                    start: Int64(sidx.offset),
                    endInclusive: Int64(sidx.offset + sidx.size - 1)
                )
            )
        )
        let index = try SIDXParser().parse(
            data.subdata(in: sidx.offset..<(sidx.offset + sidx.size)),
            boxStartOffset: UInt64(sidx.offset)
        )
        return (representation, index)
    }

    private func makeSelectedAudioTrack(
        trackID: String = "original",
        displayName: String = "原声",
        languageTag: String? = nil,
        role: PlaybackAudioTrack.Role = .original,
        isDefault: Bool = true,
        isAutoselect: Bool = true,
        representation: MediaRepresentation
    ) -> SelectedPlaybackAudioTrack {
        let track = PlaybackAudioTrack(
            id: trackID,
            displayName: displayName,
            languageTag: languageTag,
            role: role,
            isDefault: isDefault,
            isAutoselect: isAutoselect,
            representations: [representation]
        )
        return SelectedPlaybackAudioTrack(
            track: track,
            representation: representation
        )
    }

    private func firstTopLevelBox(
        named expectedType: String,
        in data: Data
    ) -> (offset: Int, size: Int)? {
        var offset = 0
        while offset + 8 <= data.count {
            let size = Int(readUInt32(in: data, at: offset))
            let type = String(
                data: data.subdata(in: (offset + 4)..<(offset + 8)),
                encoding: .ascii
            )
            guard size >= 8, offset + size <= data.count else {
                return nil
            }
            if type == expectedType {
                return (offset, size)
            }
            offset += size
        }
        return nil
    }

    private func markingTypeOneSAP(in data: Data) throws -> Data {
        var result = data
        let sidx = try #require(firstTopLevelBox(named: "sidx", in: result))
        let version = result[sidx.offset + 8]
        let entriesOffset: Int
        switch version {
        case 0:
            entriesOffset = sidx.offset + 32
        case 1:
            entriesOffset = sidx.offset + 40
        default:
            throw LoopbackFixtureError.invalidFixture
        }
        let referenceCountOffset = entriesOffset - 2
        let referenceCount =
            Int(result[referenceCountOffset]) << 8
            | Int(result[referenceCountOffset + 1])
        guard referenceCount > 0,
            entriesOffset + referenceCount * 12 <= sidx.offset + sidx.size
        else {
            throw LoopbackFixtureError.invalidFixture
        }
        for referenceIndex in 0..<referenceCount {
            let sapOffset = entriesOffset + referenceIndex * 12 + 8
            guard result[sapOffset] & 0x80 != 0 else {
                throw LoopbackFixtureError.invalidFixture
            }
            result[sapOffset] = (result[sapOffset] & 0x8f) | 0x10
        }
        return result
    }

    private func settingSIDXEarliestPresentationTime(
        _ value: UInt64,
        in data: Data
    ) throws -> Data {
        var result = data
        let sidx = try #require(firstTopLevelBox(named: "sidx", in: result))
        let valueOffset = sidx.offset + 20
        switch result[sidx.offset + 8] {
        case 0:
            guard value <= UInt32.max else {
                throw LoopbackFixtureError.invalidFixture
            }
            var encoded = UInt32(value).bigEndian
            result.replaceSubrange(
                valueOffset..<(valueOffset + 4),
                with: withUnsafeBytes(of: &encoded) { Data($0) }
            )
        case 1:
            var encoded = value.bigEndian
            result.replaceSubrange(
                valueOffset..<(valueOffset + 8),
                with: withUnsafeBytes(of: &encoded) { Data($0) }
            )
        default:
            throw LoopbackFixtureError.invalidFixture
        }
        return result
    }

    private func readUInt32(in data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { value, byte in
            (value << 8) | UInt32(byte)
        }
    }

    /// 以 KVO 事件等待 AVPlayer 进入指定状态；固定时长只作超时。
    private func waitUntilTimeControlStatus(
        of player: AVPlayer,
        is expected: AVPlayer.TimeControlStatus
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let observationBox = KeyValueObservationBox()
                let statuses = AsyncStream<AVPlayer.TimeControlStatus> {
                    continuation in
                    let observation = player.observe(
                        \.timeControlStatus,
                        options: [.initial, .new]
                    ) { observedPlayer, _ in
                        continuation.yield(observedPlayer.timeControlStatus)
                    }
                    observationBox.store(observation)
                    continuation.onTermination = { _ in
                        observationBox.invalidate()
                    }
                }
                for await status in statuses where status == expected {
                    return
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw LoopbackFixtureError.timedOut
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func waitUntilPlaybackTime(
        _ player: AVPlayer,
        reaches target: Double
    ) async throws {
        for _ in 0..<100 {
            if player.currentTime().seconds >= target {
                return
            }
            if player.currentItem?.status == .failed {
                throw player.currentItem?.error
                    ?? LoopbackFixtureError.itemFailedWithoutError
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LoopbackFixtureError.timedOut
    }

    /// 旧 session 的 URL 只要不能再返回 200 即视为已释放：连接被拒绝，或端口被复用
    /// 但 session token 不同而返回 404。
    private func isServing(_ url: URL) async -> Bool {
        guard let (_, response) = try? await URLSession.shared.data(from: url)
        else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    @MainActor
    private func waitUntilAsync(
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !(await condition()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard await condition() else {
            throw LoopbackFixtureError.timedOut
        }
    }

    private func independentHTTPStatus(
        port: Int,
        target: String,
        host: String
    ) throws -> Int {
        try independentHTTPStatus(
            port: port,
            target: target,
            hostHeaders: [host]
        )
    }

    private func independentHTTPStatus(
        port: Int,
        target: String,
        hostHeaders: [String]
    ) throws -> Int {
        let hostHeaderBlock =
            hostHeaders
            .map { "Host: \($0)\r\n" }
            .joined()
        let request =
            "GET \(target) HTTP/1.1\r\n"
            + hostHeaderBlock
            + "Connection: close\r\n"
            + "\r\n"
        let result = try runNetcat(
            port: port,
            request: Data(request.utf8)
        )
        guard result.exitStatus == 0,
            let response = String(data: result.output, encoding: .utf8),
            let statusLine = response.components(
                separatedBy: "\r\n"
            ).first,
            let rawStatus = statusLine.split(separator: " ").dropFirst().first,
            let status = Int(rawStatus)
        else {
            throw LoopbackFixtureError.invalidIndependentResponse
        }
        return status
    }

    private func exerciseIndependentDisconnects(
        port: Int,
        target: String
    ) throws {
        var processes: [(process: Process, output: Pipe)] = []
        for _ in 0..<8 {
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            process.arguments = ["-w", "2", "127.0.0.1", String(port)]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            try input.fileHandleForWriting.write(
                contentsOf: Data("GET \(target) HTTP/1.1\r\n".utf8)
            )
            try input.fileHandleForWriting.close()
            processes.append((process, output))
        }
        for entry in processes {
            _ = entry.output.fileHandleForReading.readDataToEndOfFile()
            entry.process.waitUntilExit()
        }
    }

    private func independentProcessCanConnect(port: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = [
            "-z",
            "-w",
            "1",
            "127.0.0.1",
            String(port)
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func waitForIndependentProcessToRejectConnections(
        port: Int
    ) async throws {
        for _ in 0..<100 {
            if !independentProcessCanConnect(port: port) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LoopbackFixtureError.timedOut
    }

    private func runNetcat(
        port: Int,
        request: Data
    ) throws -> (exitStatus: Int32, output: Data) {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-w", "2", "127.0.0.1", String(port)]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: request)
        try input.fileHandleForWriting.close()
        let response = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, response)
    }
}

struct LoopbackGETRangeCase: Sendable, CustomTestStringConvertible {
    let range: String?
    let status: Int
    let contentRange: String?
    let body: [UInt8]

    var testDescription: String { range ?? "no Range" }
}

let loopbackGETRangeCases: [LoopbackGETRangeCase] = [
    .init(range: nil, status: 200, contentRange: nil, body: [0, 1, 2, 3, 4]),
    .init(range: "bytes=1-3", status: 206, contentRange: "bytes 1-3/5", body: [1, 2, 3]),
    .init(range: "bytes=2-", status: 206, contentRange: "bytes 2-4/5", body: [2, 3, 4]),
    .init(range: "bytes=-2", status: 206, contentRange: "bytes 3-4/5", body: [3, 4]),
    .init(range: "bytes=5-", status: 416, contentRange: "bytes */5", body: []),
    .init(range: "bytes=0-0,2-2", status: 200, contentRange: nil, body: [0, 1, 2, 3, 4]),
    .init(range: "items=0-1", status: 200, contentRange: nil, body: [0, 1, 2, 3, 4])
]

private final class KeyValueObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var isInvalidated = false

    func store(_ observation: NSKeyValueObservation) {
        let shouldInvalidate = lock.withLock { () -> Bool in
            guard !isInvalidated else { return true }
            self.observation = observation
            return false
        }
        if shouldInvalidate {
            observation.invalidate()
        }
    }

    func invalidate() {
        let observation = lock.withLock { () -> NSKeyValueObservation? in
            isInvalidated = true
            let observation = self.observation
            self.observation = nil
            return observation
        }
        observation?.invalidate()
    }
}

private final class LoopbackServerRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LoopbackPlaybackServer] = []

    var servers: [LoopbackPlaybackServer] {
        lock.withLock { storage }
    }

    func create(rangeClient: HTTPRangeClient) -> LoopbackPlaybackServer {
        let server = LoopbackPlaybackServer(rangeClient: rangeClient)
        lock.withLock {
            storage.append(server)
        }
        return server
    }
}

private enum LoopbackFixtureError: Error {
    case itemFailedWithoutError
    case timedOut
    case missingPort
    case invalidIndependentResponse
    case invalidFixture
}

private actor FixtureRangeTransport: HTTPTransport {
    private let media: [URL: Data]
    private let failingURLs: Set<URL>
    private let unknownLengthURLs: Set<URL>
    private(set) var requests: [HTTPRequest] = []

    init(
        media: [URL: Data],
        failingURLs: Set<URL>,
        unknownLengthURLs: Set<URL> = []
    ) {
        self.media = media
        self.failingURLs = failingURLs
        self.unknownLengthURLs = unknownLengthURLs
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if failingURLs.contains(request.url) {
            return HTTPResponse(statusCode: 403, body: Data())
        }
        guard let data = media[request.url],
            let rangeHeader = request.headers.first(where: { name, _ in
                name.caseInsensitiveCompare("Range") == .orderedSame
            })?.value,
            let range = parseRange(rangeHeader, contentLength: data.count)
        else {
            return HTTPResponse(statusCode: 400, body: Data())
        }

        let body = data.subdata(
            in: Int(range.start)..<(Int(range.endInclusive) + 1)
        )
        let completeLength =
            unknownLengthURLs.contains(request.url)
            ? "*" : String(data.count)
        return HTTPResponse(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes \(range.start)-\(range.endInclusive)/\(completeLength)"
            ],
            body: body
        )
    }

    private func parseRange(
        _ value: String,
        contentLength: Int
    ) -> (start: Int64, endInclusive: Int64)? {
        guard value.hasPrefix("bytes=") else { return nil }
        let bounds = value.dropFirst("bytes=".count).split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
            let start = Int64(bounds[0]),
            let end = Int64(bounds[1]),
            start >= 0,
            end >= start,
            end < Int64(contentLength)
        else {
            return nil
        }
        return (start, end)
    }
}

private actor ReplacementRangeTransport: HTTPTransport {
    private let media: [URL: Data]
    private let indexRanges: [URL: MediaByteRange]
    private let blockedMediaURLs: Set<URL>
    private(set) var startedMediaRequestCount = 0
    private(set) var cancelledMediaRequestCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        media: [URL: Data],
        indexRanges: [URL: MediaByteRange],
        blockedMediaURLs: Set<URL>
    ) {
        self.media = media
        self.indexRanges = indexRanges
        self.blockedMediaURLs = blockedMediaURLs
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let data = media[request.url],
            let rangeHeader = request.headers.first(where: { name, _ in
                name.caseInsensitiveCompare("Range") == .orderedSame
            })?.value,
            let requestedRange = parseRange(rangeHeader)
        else {
            return HTTPResponse(statusCode: 400, body: Data())
        }

        if blockedMediaURLs.contains(request.url),
            requestedRange != indexRanges[request.url]
        {
            startedMediaRequestCount += 1
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                cancelledMediaRequestCount += 1
                throw CancellationError()
            }
        }

        let body = data.subdata(
            in: Int(requestedRange.start)..<(Int(requestedRange.endInclusive) + 1)
        )
        return HTTPResponse(
            statusCode: 206,
            headers: [
                "Content-Range":
                    "bytes \(requestedRange.start)-\(requestedRange.endInclusive)/\(data.count)"
            ],
            body: body
        )
    }

    func waitForStartedMediaRequest() async {
        guard startedMediaRequestCount == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    private func parseRange(_ value: String) -> MediaByteRange? {
        guard value.hasPrefix("bytes=") else { return nil }
        let bounds = value.dropFirst("bytes=".count).split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
            let start = Int64(bounds[0]),
            let end = Int64(bounds[1])
        else {
            return nil
        }
        return try? MediaByteRange(start: start, endInclusive: end)
    }
}

private actor CrossIdentityFallbackTransport: HTTPTransport {
    private let primary: URL
    private let backup: URL
    private(set) var requestedURLs: [URL] = []

    init(primary: URL, backup: URL) {
        self.primary = primary
        self.backup = backup
    }

    func send(_ request: HTTPRequest) async -> HTTPResponse {
        requestedURLs.append(request.url)
        let range = request.headers.first(where: { name, _ in
            name.caseInsensitiveCompare("Range") == .orderedSame
        })?.value

        switch (request.url, range) {
        case (primary, "bytes=0-1"):
            return HTTPResponse(
                statusCode: 206,
                headers: ["Content-Range": "bytes 0-1/4"],
                body: Data([0x41, 0x41])
            )
        case (primary, "bytes=2-3"):
            return HTTPResponse(statusCode: 503, body: Data())
        case (backup, "bytes=2-3"):
            return HTTPResponse(
                statusCode: 206,
                headers: ["Content-Range": "bytes 2-3/4"],
                body: Data([0x42, 0x42])
            )
        default:
            return HTTPResponse(statusCode: 400, body: Data())
        }
    }
}

private actor PlaybackFailureRecorder {
    private var recordedEvents: [PlaybackFailureEvent] = []

    func append(_ event: PlaybackFailureEvent) {
        recordedEvents.append(event)
    }

    func identities() -> [PlaybackItemIdentity] {
        recordedEvents.map(\.identity)
    }
}

/// reset 会一直挂起到测试显式放行，用于固定 ABA 加载与 reset 的串行顺序。
private actor NativeSubtitleFixtureRepository: SubtitleRepository {
    private(set) var trackRequests: [PlaybackItemIdentity] = []
    private(set) var resetCalls: [PlaybackItemIdentity] = []
    private var resetContinuation: CheckedContinuation<Void, Never>?
    private var resetWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func tracks(
        for identity: PlaybackItemIdentity
    ) -> [SubtitleTrack] {
        trackRequests.append(identity)
        return [
            SubtitleTrack(
                id: "standard-zh",
                languageCode: "zh",
                displayName: "中文",
                kind: .standard
            )
        ]
    }

    func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) -> [SubtitleCue] {
        []
    }

    func reset(for identity: PlaybackItemIdentity) async {
        resetCalls.append(identity)
        let reached = resetWaiters.filter { $0.count <= resetCalls.count }
        resetWaiters.removeAll { $0.count <= resetCalls.count }
        for waiter in reached { waiter.continuation.resume() }
        await withCheckedContinuation { continuation in
            resetContinuation = continuation
        }
    }

    func waitForResetCalls(_ count: Int) async {
        guard resetCalls.count < count else { return }
        await withCheckedContinuation { resetWaiters.append((count, $0)) }
    }

    func releaseCurrentReset() {
        resetContinuation?.resume()
        resetContinuation = nil
    }
}

/// 两种不可用的原生字幕目录：拉取失败，或标签不安全／归一化后重名。
enum UnusableNativeSubtitleCatalog: CaseIterable, Sendable {
    case failing
    case unsafeLabels

    var repository: any SubtitleRepository {
        switch self {
        case .failing: FailingNativeSubtitleRepository()
        case .unsafeLabels: UnsafeLabelNativeSubtitleRepository()
        }
    }
}

private struct FailingNativeSubtitleRepository: SubtitleRepository {
    func tracks(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleTrack] {
        throw SubtitleApplicationError.transportFailure
    }

    func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) async throws -> [SubtitleCue] {
        throw SubtitleApplicationError.transportFailure
    }

    func reset(for identity: PlaybackItemIdentity) async {}
}

private struct UnsafeLabelNativeSubtitleRepository: SubtitleRepository {
    func tracks(
        for identity: PlaybackItemIdentity
    ) -> [SubtitleTrack] {
        [
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
        ]
    }

    func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) -> [SubtitleCue] {
        []
    }

    func reset(for identity: PlaybackItemIdentity) async {}
}

private actor NoncooperativeNativeSubtitleRepository: SubtitleRepository {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func tracks(
        for identity: PlaybackItemIdentity
    ) async -> [SubtitleTrack] {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return [
            SubtitleTrack(
                id: "late",
                languageCode: "zh",
                displayName: "中文",
                kind: .standard
            )
        ]
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) -> [SubtitleCue] {
        []
    }

    func reset(for identity: PlaybackItemIdentity) async {}

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
