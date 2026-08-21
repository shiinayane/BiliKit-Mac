@preconcurrency import AVFoundation
import AppKit
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import QuartzCore
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
                "attacker.invalid",
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
        try await waitForLoopbackConnectionsToDrain(server)
        server.stop()
        try await waitForIndependentProcessToRejectConnections(port: port)
    }

    @Test
    func servesStrictPartialContentOnLoopbackOnly() async throws {
        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }
        let url = try server.register(
            .inMemory(
                data: Data([0, 1, 2, 3, 4]),
                contentType: "application/octet-stream"
            ),
            at: "fixture.bin"
        )
        var request = URLRequest(url: url)
        request.setValue("bytes=1-3", forHTTPHeaderField: "Range")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)

        #expect(url.host == "127.0.0.1")
        #expect(httpResponse.statusCode == 206)
        #expect(httpResponse.value(forHTTPHeaderField: "Content-Range") == "bytes 1-3/5")
        #expect(data == Data([1, 2, 3]))
    }

    @Test
    func cancellingStartDoesNotLeaveListenerRunning() async throws {
        let server = LoopbackPlaybackServer()
        defer { server.stop() }
        let startTask = Task {
            try await server.start()
        }
        startTask.cancel()

        var cancellationObserved = false
        do {
            try await startTask.value
        } catch is CancellationError {
            cancellationObserved = true
        }
        let diagnostics = server.diagnosticsSnapshot()

        #expect(cancellationObserved)
        #expect(!diagnostics.isRunning)

        try await server.start()
        #expect(server.diagnosticsSnapshot().isRunning)
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

    @Test
    func loopbackRangeAndHeadResponseMatrix() async throws {
        struct ExpectedResponse {
            let status: Int
            let contentLength: String
            let contentRange: String?
            let body: Data
        }
        struct Case {
            let name: String
            let method: String
            let range: String?
            let expected: ExpectedResponse
        }

        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }
        let url = try server.register(
            .inMemory(
                data: Data([0, 1, 2, 3, 4]),
                contentType: "application/octet-stream"
            ),
            at: "range-matrix.bin"
        )
        let cases = [
            Case(
                name: "GET full",
                method: "GET",
                range: nil,
                expected: ExpectedResponse(
                    status: 200,
                    contentLength: "5",
                    contentRange: nil,
                    body: Data([0, 1, 2, 3, 4])
                )
            ),
            Case(
                name: "GET closed",
                method: "GET",
                range: "bytes=1-3",
                expected: ExpectedResponse(
                    status: 206,
                    contentLength: "3",
                    contentRange: "bytes 1-3/5",
                    body: Data([1, 2, 3])
                )
            ),
            Case(
                name: "GET open",
                method: "GET",
                range: "bytes=2-",
                expected: ExpectedResponse(
                    status: 206,
                    contentLength: "3",
                    contentRange: "bytes 2-4/5",
                    body: Data([2, 3, 4])
                )
            ),
            Case(
                name: "GET suffix",
                method: "GET",
                range: "bytes=-2",
                expected: ExpectedResponse(
                    status: 206,
                    contentLength: "2",
                    contentRange: "bytes 3-4/5",
                    body: Data([3, 4])
                )
            ),
            Case(
                name: "GET unsatisfiable",
                method: "GET",
                range: "bytes=5-",
                expected: ExpectedResponse(
                    status: 416,
                    contentLength: "0",
                    contentRange: "bytes */5",
                    body: Data()
                )
            ),
            Case(
                name: "GET multi range ignored",
                method: "GET",
                range: "bytes=0-0,2-2",
                expected: ExpectedResponse(
                    status: 200,
                    contentLength: "5",
                    contentRange: nil,
                    body: Data([0, 1, 2, 3, 4])
                )
            ),
            Case(
                name: "GET malformed range ignored",
                method: "GET",
                range: "items=0-1",
                expected: ExpectedResponse(
                    status: 200,
                    contentLength: "5",
                    contentRange: nil,
                    body: Data([0, 1, 2, 3, 4])
                )
            ),
            Case(
                name: "HEAD full",
                method: "HEAD",
                range: nil,
                expected: ExpectedResponse(
                    status: 200,
                    contentLength: "5",
                    contentRange: nil,
                    body: Data()
                )
            ),
            Case(
                name: "HEAD range ignored",
                method: "HEAD",
                range: "bytes=1-3",
                expected: ExpectedResponse(
                    status: 200,
                    contentLength: "5",
                    contentRange: nil,
                    body: Data()
                )
            ),
            Case(
                name: "HEAD suffix ignored",
                method: "HEAD",
                range: "bytes=-2",
                expected: ExpectedResponse(
                    status: 200,
                    contentLength: "5",
                    contentRange: nil,
                    body: Data()
                )
            ),
            Case(
                name: "HEAD unsatisfiable ignored",
                method: "HEAD",
                range: "bytes=5-",
                expected: ExpectedResponse(
                    status: 200,
                    contentLength: "5",
                    contentRange: nil,
                    body: Data()
                )
            ),
            Case(
                name: "HEAD multi range ignored",
                method: "HEAD",
                range: "bytes=0-0,2-2",
                expected: ExpectedResponse(
                    status: 200,
                    contentLength: "5",
                    contentRange: nil,
                    body: Data()
                )
            ),
            Case(
                name: "HEAD unknown unit ignored",
                method: "HEAD",
                range: "items=0-1",
                expected: ExpectedResponse(
                    status: 200,
                    contentLength: "5",
                    contentRange: nil,
                    body: Data()
                )
            ),
        ]

        for testCase in cases {
            var request = URLRequest(url: url)
            request.httpMethod = testCase.method
            if let range = testCase.range {
                request.setValue(range, forHTTPHeaderField: "Range")
            }
            let (body, response) = try await URLSession.shared.data(for: request)
            let httpResponse = try #require(
                response as? HTTPURLResponse,
                "Missing HTTP response for \(testCase.name)"
            )
            #expect(
                httpResponse.statusCode == testCase.expected.status,
                Testing.Comment(rawValue: testCase.name)
            )
            #expect(
                httpResponse.value(
                    forHTTPHeaderField: "Content-Length"
                ) == testCase.expected.contentLength,
                Testing.Comment(rawValue: testCase.name)
            )
            #expect(
                httpResponse.value(
                    forHTTPHeaderField: "Content-Range"
                ) == testCase.expected.contentRange,
                Testing.Comment(rawValue: testCase.name)
            )
            #expect(
                body == testCase.expected.body,
                Testing.Comment(rawValue: testCase.name)
            )
        }
    }

    @Test
    func remoteRangeErrorsStayLocalAndSuffixIsForwardedAsClosedRange() async throws {
        let remoteURL = try #require(
            URL(string: "https://media.example.invalid/remote.mp4")
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
    func syntheticAVCAndAACReachReadyToPlayThroughLoopbackHLS() async throws {
        let videoData = try fixtureData(named: "video-avc")
        let audioData = try fixtureData(named: "audio-aac")
        let videoFixture = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400b",
            bandwidth: 50_000,
            data: videoData
        )
        let audioFixture = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 96_000,
            data: audioData
        )

        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }

        let diagnosticSentinel = "M501_DIAGNOSTIC_SENTINEL_20260728_B"
        let masterURL = try server.url(
            for: "\(diagnosticSentinel)/master.m3u8"
        )
        let videoPlaylistURL = try server.url(
            for: "\(diagnosticSentinel)/video.m3u8"
        )
        let audioPlaylistURL = try server.url(
            for: "\(diagnosticSentinel)/audio.m3u8"
        )
        let videoMediaURL = try server.register(
            .inMemory(data: videoData, contentType: AVFileType.mp4.rawValue),
            at: "\(diagnosticSentinel)/video.mp4"
        )
        let audioMediaURL = try server.register(
            .inMemory(data: audioData, contentType: AVFileType.mp4.rawValue),
            at: "\(diagnosticSentinel)/audio.mp4"
        )

        let videoPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: videoFixture.representation,
            index: videoFixture.index,
            mediaURI: videoMediaURL
        )
        let audioPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: audioFixture.representation,
            index: audioFixture.index,
            mediaURI: audioMediaURL
        )
        let masterPlaylist = try HLSMasterPlaylistBuilder().build(
            videoVariants: [
                HLSVideoVariant(
                    representation: videoFixture.representation,
                    index: videoFixture.index,
                    playlistURI: videoPlaylistURL
                )
            ],
            audioRenditions: [
                makeHLSAudioRendition(
                    representation: audioFixture.representation,
                    index: audioFixture.index,
                    playlistURI: audioPlaylistURL
                )
            ]
        )
        _ = try server.register(
            .inMemory(
                data: Data(videoPlaylist.utf8),
                contentType: "application/vnd.apple.mpegurl"
            ),
            at: "\(diagnosticSentinel)/video.m3u8"
        )
        _ = try server.register(
            .inMemory(
                data: Data(audioPlaylist.utf8),
                contentType: "application/vnd.apple.mpegurl"
            ),
            at: "\(diagnosticSentinel)/audio.m3u8"
        )
        _ = try server.register(
            .inMemory(
                data: Data(masterPlaylist.utf8),
                contentType: "application/vnd.apple.mpegurl"
            ),
            at: "\(diagnosticSentinel)/master.m3u8"
        )

        let asset = AVURLAsset(url: masterURL)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true

        try await waitUntilReadyToPlay(item)
        let duration = try await asset.load(.duration)
        player.play()
        try await waitUntilPlaybackTime(player, reaches: 0.15)
        player.pause()

        let didSeekForward = await player.seek(
            to: CMTime(seconds: 0.70, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        let forwardTime = player.currentTime().seconds
        let didSeekBackward = await player.seek(
            to: CMTime(seconds: 0.10, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        player.play()
        try await waitUntilPlaybackTime(player, reaches: 0.25)
        player.pause()

        #expect(item.status == .readyToPlay)
        #expect(duration.seconds > 0)
        #expect(didSeekForward)
        #expect(forwardTime >= 0.65)
        #expect(didSeekBackward)
        let accessEvents = try #require(item.accessLog()?.events)
        #expect(!accessEvents.isEmpty)
        #expect(
            accessEvents.contains {
                $0.uri?.contains(diagnosticSentinel) == true
            }
        )
        #expect(
            accessEvents.contains {
                !($0.serverAddress ?? "").isEmpty
            }
        )
        _ = player
    }

    @Test
    @MainActor
    func bridgeUsesFullFragmentsForOnDemandIFrameTrickPlay() async throws {
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
            primaryURL: videoURL,
            videoAttributes: try VideoRepresentationAttributes(
                width: 128,
                height: 72,
                frameRate: 24
            )
        )
        let audioFixture = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 32_000,
            data: audioData,
            primaryURL: audioURL
        )
        let transport = FixtureRangeTransport(
            media: [
                videoURL: videoData,
                audioURL: audioData,
            ],
            failingURLs: []
        )
        let registry = LoopbackServerRegistry()
        let bridge = DASHToHLSBridge(
            rangeClient: HTTPRangeClient(transport: transport),
            serverFactory: { rangeClient in
                registry.create(rangeClient: rangeClient)
            }
        )
        let prepared = try await bridge.prepare(
            video: videoFixture.representation,
            audioTracks: [
                makeSelectedAudioTrack(
                    representation: audioFixture.representation
                )
            ]
        )
        defer { prepared.stop() }
        let server = try #require(registry.servers.last)
        let masterData = try await URLSession.shared.data(from: prepared.url).0
        let master = try #require(String(data: masterData, encoding: .utf8))

        #expect(master.contains("#EXT-X-I-FRAME-STREAM-INF:"))
        #expect(master.contains("/video/64-iframe.m3u8"))

        let item = AVPlayerItem(url: prepared.url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        try await waitUntilReadyToPlay(item)

        #expect(item.canPlayFastForward)
        #expect(item.canPlayFastReverse)
        #expect(
            try server.requestCount(
                method: "GET",
                at: "video/64-iframe.m3u8"
            ) == 0
        )
        let requestsBeforeFastForward = await transport.requests.count

        player.playImmediately(atRate: 4)
        try await waitUntilRequest(
            method: "GET",
            at: "video/64-iframe.m3u8",
            on: server
        )
        try await waitUntilRequestCount(
            exceeds: requestsBeforeFastForward,
            on: transport
        )
        player.pause()

        let fastForwardRequests = await transport.requests.dropFirst(
            requestsBeforeFastForward
        )
        let fullFragmentRanges = Set(
            videoFixture.index.references.map(
                \.byteRange.httpRangeHeaderValue
            )
        )
        #expect(
            fastForwardRequests.contains { request in
                request.url == videoURL
                    && request.headers.contains { name, value in
                        name.caseInsensitiveCompare("Range") == .orderedSame
                            && fullFragmentRanges.contains(value)
                    }
            }
        )
        #expect(
            fastForwardRequests.allSatisfy { request in
                request.headers.keys.allSatisfy {
                    $0.caseInsensitiveCompare("Cookie") != .orderedSame
                        && $0.caseInsensitiveCompare("Authorization")
                            != .orderedSame
                }
            }
        )

        #expect(item.status == .readyToPlay)
        _ = player
    }

    @Test
    @MainActor
    func unifiedMasterExposesAdaptiveVariantsAndNativeSubtitles() async throws {
        let lowVideoData = try fixtureData(named: "video-avc")
        let highVideoData = try fixtureBase64Data(
            named: "video-avc-256x144.mp4"
        )
        let audioData = try fixtureData(named: "audio-aac")
        let lowVideoFixture = try makeFixtureTrack(
            id: 64,
            kind: .video,
            codecs: "avc1.4d400b",
            bandwidth: 50_000,
            data: lowVideoData
        )
        let highVideoFixture = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400c",
            bandwidth: 100_000,
            data: highVideoData
        )
        let audioFixture = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 96_000,
            data: audioData
        )
        let subtitleMPEGTimestamp = try mpegTSTimestamp(
            for: lowVideoFixture.index
        )
        #expect(subtitleMPEGTimestamp == 7_500)
        let subtitleBody = """
            WEBVTT
            X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:\(subtitleMPEGTimestamp)

            00:00:00.000 --> 00:00:01.500
            本地原生字幕验证

            """

        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }

        let masterURL = try server.url(for: "unified/master.m3u8")
        let highMasterURL = try server.url(
            for: "unified/high-master.m3u8"
        )
        let lowVideoPlaylistURL = try server.url(
            for: "unified/video-low.m3u8"
        )
        let highVideoPlaylistURL = try server.url(
            for: "unified/video-high.m3u8"
        )
        let audioPlaylistURL = try server.url(for: "unified/audio.m3u8")
        let subtitlePlaylistURL = try server.url(
            for: "unified/subtitles-zh.m3u8"
        )
        let aiSubtitlePlaylistURL = try server.url(
            for: "unified/subtitles-zh-ai.m3u8"
        )
        let englishSubtitlePlaylistURL = try server.url(
            for: "unified/subtitles-en.m3u8"
        )
        let lowVideoMediaURL = try server.register(
            .inMemory(
                data: lowVideoData,
                contentType: AVFileType.mp4.rawValue
            ),
            at: "unified/video-low.mp4"
        )
        let highVideoMediaURL = try server.register(
            .inMemory(
                data: highVideoData,
                contentType: AVFileType.mp4.rawValue
            ),
            at: "unified/video-high.mp4"
        )
        let audioMediaURL = try server.register(
            .inMemory(data: audioData, contentType: AVFileType.mp4.rawValue),
            at: "unified/audio.mp4"
        )

        let lowVideoPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: lowVideoFixture.representation,
            index: lowVideoFixture.index,
            mediaURI: lowVideoMediaURL
        )
        let highVideoPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: highVideoFixture.representation,
            index: highVideoFixture.index,
            mediaURI: highVideoMediaURL
        )
        let audioPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: audioFixture.representation,
            index: audioFixture.index,
            mediaURI: audioMediaURL
        )
        let subtitlePlaylist = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:3
            #EXT-X-MEDIA-SEQUENCE:0
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:2.083,
            subtitles-zh.vtt
            #EXT-X-ENDLIST

            """
        let aiSubtitlePlaylist = subtitlePlaylist.replacingOccurrences(
            of: "subtitles-zh.vtt",
            with: "subtitles-zh-ai.vtt"
        )
        let englishSubtitlePlaylist = subtitlePlaylist.replacingOccurrences(
            of: "subtitles-zh.vtt",
            with: "subtitles-en.vtt"
        )
        let masterPlaylist = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="\(audioPlaylistURL.absoluteString)"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="中文",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,URI="\(subtitlePlaylistURL.absoluteString)"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="中文（AI）",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,URI="\(aiSubtitlePlaylistURL.absoluteString)"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="English",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,URI="\(englishSubtitlePlaylistURL.absoluteString)"
            #EXT-X-STREAM-INF:BANDWIDTH=196000,AVERAGE-BANDWIDTH=196000,RESOLUTION=256x144,FRAME-RATE=24.000,CODECS="avc1.4d400c,mp4a.40.2",AUDIO="audio",SUBTITLES="subtitles"
            \(highVideoPlaylistURL.absoluteString)
            #EXT-X-STREAM-INF:BANDWIDTH=146000,AVERAGE-BANDWIDTH=146000,RESOLUTION=128x72,FRAME-RATE=24.000,CODECS="avc1.4d400b,mp4a.40.2",AUDIO="audio",SUBTITLES="subtitles"
            \(lowVideoPlaylistURL.absoluteString)

            """

        _ = try server.register(
            playlistResource(lowVideoPlaylist),
            at: "unified/video-low.m3u8"
        )
        _ = try server.register(
            playlistResource(highVideoPlaylist),
            at: "unified/video-high.m3u8"
        )
        _ = try server.register(
            playlistResource(audioPlaylist),
            at: "unified/audio.m3u8"
        )
        _ = try server.register(
            playlistResource(subtitlePlaylist),
            at: "unified/subtitles-zh.m3u8"
        )
        _ = try server.register(
            playlistResource(aiSubtitlePlaylist),
            at: "unified/subtitles-zh-ai.m3u8"
        )
        _ = try server.register(
            playlistResource(englishSubtitlePlaylist),
            at: "unified/subtitles-en.m3u8"
        )
        _ = try server.register(
            .inMemory(
                data: Data(subtitleBody.utf8),
                contentType: "text/vtt"
            ),
            at: "unified/subtitles-zh.vtt"
        )
        _ = try server.register(
            .inMemory(
                data: Data(subtitleBody.utf8),
                contentType: "text/vtt"
            ),
            at: "unified/subtitles-zh-ai.vtt"
        )
        _ = try server.register(
            .inMemory(
                data: Data(subtitleBody.utf8),
                contentType: "text/vtt"
            ),
            at: "unified/subtitles-en.vtt"
        )
        _ = try server.register(
            playlistResource(masterPlaylist),
            at: "unified/master.m3u8"
        )
        _ = try server.register(
            playlistResource(masterPlaylist),
            at: "unified/high-master.m3u8"
        )

        let asset = AVURLAsset(url: masterURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredMaximumResolution = CGSize(width: 128, height: 72)
        item.startsOnFirstEligibleVariant = true
        let player = AVPlayer(playerItem: item)
        player.isMuted = true

        try await waitUntilReadyToPlay(item)
        let variants = try await asset.load(.variants)
        let audibleGroup = try #require(
            try await asset.loadMediaSelectionGroup(for: .audible)
        )
        let legibleGroup = try #require(
            try await asset.loadMediaSelectionGroup(for: .legible)
        )

        #expect(variants.count == 2)
        #expect(
            variants.compactMap(\.peakBitRate).sorted()
                == [146_000.0, 196_000.0]
        )
        #expect(
            variants.compactMap(\.videoAttributes?.presentationSize)
                .sorted { $0.width < $1.width }
                == [
                    CGSize(width: 128, height: 72),
                    CGSize(width: 256, height: 144),
                ]
        )
        #expect(
            variants.allSatisfy {
                $0.videoAttributes?.nominalFrameRate == 24
            }
        )
        #expect(player.appliesMediaSelectionCriteriaAutomatically)
        #expect(
            item.currentMediaSelection.selectedMediaOption(in: audibleGroup)
                != nil
        )
        #expect(legibleGroup.options.count == 3)
        #expect(
            Set(legibleGroup.options.map(\.displayName))
                == ["中文", "中文（AI）", "English"]
        )
        #expect(
            item.currentMediaSelection.selectedMediaOption(
                in: legibleGroup
            ) == nil
        )
        player.play()
        try await waitUntilPlaybackTime(player, reaches: 0.15)
        player.pause()
        #expect(
            try server.requestCount(
                method: "GET",
                at: "unified/subtitles-zh.vtt"
            ) == 0
        )
        #expect(
            try server.requestCount(
                method: "GET",
                at: "unified/subtitles-zh-ai.vtt"
            ) == 0
        )
        #expect(
            try server.requestCount(
                method: "GET",
                at: "unified/subtitles-en.vtt"
            ) == 0
        )

        let subtitleOption = try #require(
            legibleGroup.options.first(where: { $0.displayName == "中文" })
        )
        item.select(subtitleOption, in: legibleGroup)
        #expect(
            item.currentMediaSelection.selectedMediaOption(
                in: legibleGroup
            ) == subtitleOption
        )
        player.play()
        try await waitUntilRequest(
            method: "GET",
            at: "unified/subtitles-zh.vtt",
            on: server
        )
        player.pause()

        #expect(
            item.accessLog()?.events.contains {
                $0.indicatedBitrate == 146_000
            } == true
        )

        let highAsset = AVURLAsset(url: highMasterURL)
        let highItem = AVPlayerItem(asset: highAsset)
        highItem.preferredMaximumResolution = CGSize(width: 256, height: 144)
        highItem.startsOnFirstEligibleVariant = true
        let highPlayer = AVPlayer(playerItem: highItem)
        highPlayer.isMuted = true

        try await waitUntilReadyToPlay(highItem)
        highPlayer.play()
        try await waitUntilPlaybackTime(highPlayer, reaches: 0.15)
        highPlayer.pause()

        #expect(
            highItem.accessLog()?.events.contains {
                $0.indicatedBitrate == 196_000
            } == true
        )

        let manualAsset = AVURLAsset(url: masterURL)
        let manualItem = AVPlayerItem(asset: manualAsset)
        let manualPlayer = AVPlayer()
        manualPlayer.appliesMediaSelectionCriteriaAutomatically = false
        manualPlayer.replaceCurrentItem(with: manualItem)
        try await waitUntilReadyToPlay(manualItem)
        let manualAudibleGroup = try #require(
            try await manualAsset.loadMediaSelectionGroup(for: .audible)
        )
        let manualLegibleGroup = try #require(
            try await manualAsset.loadMediaSelectionGroup(for: .legible)
        )

        #expect(!manualPlayer.appliesMediaSelectionCriteriaAutomatically)
        #expect(
            manualItem.currentMediaSelection.selectedMediaOption(
                in: manualAudibleGroup
            ) != nil
        )
        #expect(
            manualItem.currentMediaSelection.selectedMediaOption(
                in: manualLegibleGroup
            ) == nil
        )
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment[
                "BILIKIT_RUN_ABR_POLICY_PROBE"
            ] == "1",
            "AVPlayer network adaptation timing is not deterministic across OS versions."
        )
    )
    @MainActor
    func automaticABRDowngradesWithinOnePlayerItem()
        async throws
    {
        let lowVideoData = try fixtureBase64Data(
            named: "video-avc-128x72-4s-global-sidx.mp4"
        )
        let highVideoData = try fixtureBase64Data(
            named: "video-avc-256x144-4s-global-sidx.mp4"
        )
        let audioData = try fixtureBase64Data(
            named: "audio-aac-4s-global-sidx.mp4"
        )
        let lowRemoteURL = try #require(
            URL(string: "https://media.example.invalid/abr-low.mp4")
        )
        let highRemoteURL = try #require(
            URL(string: "https://media.example.invalid/abr-high.mp4")
        )
        let audioRemoteURL = try #require(
            URL(string: "https://media.example.invalid/abr-audio.mp4")
        )
        let lowVideoFixture = try makeFixtureTrack(
            id: 64,
            kind: .video,
            codecs: "avc1.4d400a",
            bandwidth: 50_000,
            data: lowVideoData,
            primaryURL: lowRemoteURL
        )
        let highVideoFixture = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400c",
            bandwidth: 100_000,
            data: highVideoData,
            primaryURL: highRemoteURL
        )
        let audioFixture = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 32_000,
            data: audioData,
            primaryURL: audioRemoteURL
        )
        let transport = AdaptiveFixtureRangeTransport(
            media: [
                lowRemoteURL: lowVideoData,
                highRemoteURL: highVideoData,
                audioRemoteURL: audioData,
            ],
            lowVideoURL: lowRemoteURL,
            highVideoURL: highRemoteURL
        )
        let server = LoopbackPlaybackServer(
            rangeClient: HTTPRangeClient(transport: transport)
        )
        try await server.start()
        defer { server.stop() }

        let masterURL = try server.url(for: "abr/master.m3u8")
        let lowPlaylistURL = try server.url(for: "abr/low.m3u8")
        let highPlaylistURL = try server.url(for: "abr/high.m3u8")
        let audioPlaylistURL = try server.url(for: "abr/audio.m3u8")
        let lowMediaURL = try server.register(
            .remote(
                try LoopbackRemoteResource(
                    sourceURL: lowRemoteURL,
                    contentLength: Int64(lowVideoData.count),
                    contentType: AVFileType.mp4.rawValue
                )
            ),
            at: "abr/low.mp4"
        )
        let highMediaURL = try server.register(
            .remote(
                try LoopbackRemoteResource(
                    sourceURL: highRemoteURL,
                    contentLength: Int64(highVideoData.count),
                    contentType: AVFileType.mp4.rawValue
                )
            ),
            at: "abr/high.mp4"
        )
        let audioMediaURL = try server.register(
            .remote(
                try LoopbackRemoteResource(
                    sourceURL: audioRemoteURL,
                    contentLength: Int64(audioData.count),
                    contentType: AVFileType.mp4.rawValue
                )
            ),
            at: "abr/audio.mp4"
        )
        let lowPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: lowVideoFixture.representation,
            index: lowVideoFixture.index,
            mediaURI: lowMediaURL
        )
        let highPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: highVideoFixture.representation,
            index: highVideoFixture.index,
            mediaURI: highMediaURL
        )
        let audioPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: audioFixture.representation,
            index: audioFixture.index,
            mediaURI: audioMediaURL
        )
        let masterPlaylist = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="\(audioPlaylistURL.absoluteString)"
            #EXT-X-STREAM-INF:BANDWIDTH=132000,AVERAGE-BANDWIDTH=132000,RESOLUTION=256x144,FRAME-RATE=24.000,CODECS="avc1.4d400c,mp4a.40.2",AUDIO="audio"
            \(highPlaylistURL.absoluteString)
            #EXT-X-STREAM-INF:BANDWIDTH=82000,AVERAGE-BANDWIDTH=82000,RESOLUTION=128x72,FRAME-RATE=24.000,CODECS="avc1.4d400a,mp4a.40.2",AUDIO="audio"
            \(lowPlaylistURL.absoluteString)

            """

        _ = try server.register(
            playlistResource(lowPlaylist),
            at: "abr/low.m3u8"
        )
        _ = try server.register(
            playlistResource(highPlaylist),
            at: "abr/high.m3u8"
        )
        _ = try server.register(
            playlistResource(audioPlaylist),
            at: "abr/audio.m3u8"
        )
        _ = try server.register(
            playlistResource(masterPlaylist),
            at: "abr/master.m3u8"
        )

        let asset = AVURLAsset(url: masterURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0.25
        item.startsOnFirstEligibleVariant = true
        let videoOutput = AVPlayerItemVideoOutput()
        item.add(videoOutput)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = CGRect(x: 0, y: 0, width: 256, height: 144)
        let surfaceView = NSView(
            frame: CGRect(x: 0, y: 0, width: 256, height: 144)
        )
        surfaceView.wantsLayer = true
        surfaceView.layer?.addSublayer(playerLayer)
        let surfaceWindow = NSWindow(
            contentRect: surfaceView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        surfaceWindow.contentView = surfaceView
        surfaceWindow.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        surfaceWindow.orderFrontRegardless()
        defer {
            playerLayer.player = nil
            surfaceWindow.orderOut(nil)
        }

        try await waitUntilReadyToPlay(item)
        player.play()
        try await waitUntilVideoFrame(videoOutput, on: item)
        try await waitUntilPlayerLayerReady(playerLayer, on: item)
        do {
            try await waitUntilIndicatedBitrate(
                132_000,
                appearsAfterEventCount: 0,
                on: item
            )
        } catch {
            print(
                "M501 ABR initial events="
                    + "\(item.accessLog()?.events.map(\.indicatedBitrate) ?? [])"
                    + " high-requests="
                    + "\(await transport.requestCount(for: highRemoteURL))"
                    + " low-requests="
                    + "\(await transport.requestCount(for: lowRemoteURL))"
            )
            throw error
        }
        let highEventCount = item.accessLog()?.events.count ?? 0
        await transport.setConstrained(true)

        do {
            try await waitUntilIndicatedBitrate(
                82_000,
                appearsAfterEventCount: highEventCount,
                on: item
            )
        } catch {
            print(
                "M501 ABR constrained events="
                    + "\(item.accessLog()?.events.map(\.indicatedBitrate) ?? [])"
                    + " high-requests="
                    + "\(await transport.requestCount(for: highRemoteURL))"
                    + " low-requests="
                    + "\(await transport.requestCount(for: lowRemoteURL))"
            )
            throw error
        }
        player.pause()

        #expect(player.currentItem === item)
        #expect(
            await transport.requestCount(for: highRemoteURL) > 0
        )
        #expect(
            await transport.requestCount(for: lowRemoteURL) > 0
        )
        print(
            "M501 native ABR sequence="
                + "\(item.accessLog()?.events.map(\.indicatedBitrate) ?? [])"
                + " same-item=true"
        )
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment[
                "BILIKIT_RUN_PLAYER_RECOVERY_POLICY_PROBE"
            ] == "1",
            "AVPlayer recovery timing after range starvation is not deterministic across OS versions."
        )
    )
    @MainActor
    func automaticWaitingRecoversFromRangeStarvation() async throws {
        let systemDefault = try await recoverableStallTrial()

        #expect(
            systemDefault.stallStatus == .waitingToPlayAtSpecifiedRate
        )
        #expect(systemDefault.blockedRequestCount >= 1)
        #expect(systemDefault.recoveredAutomatically)
    }

    @Test
    @MainActor
    func playerUsesSystemAutomaticWaitingByDefault() {
        let player = AVPlayer()

        #expect(player.automaticallyWaitsToMinimizeStalling)
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment[
                "BILIKIT_RUN_EXACT_QUALITY_HANDOFF_PROBE"
            ] == "1",
            "AVPlayer dual-player handoff timing is not deterministic across OS versions."
        )
    )
    @MainActor
    func runtimeResolutionCapAndExactQualityReplacementTradeoffs()
        async throws
    {
        let lowVideoData = try fixtureBase64Data(
            named: "video-avc-128x72-4s-global-sidx.mp4"
        )
        let highVideoData = try fixtureBase64Data(
            named: "video-avc-256x144-4s-global-sidx.mp4"
        )
        let audioData = try fixtureBase64Data(
            named: "audio-aac-4s-global-sidx.mp4"
        )
        let lowRemoteURL = try #require(
            URL(string: "https://media.example.invalid/switch-low.mp4")
        )
        let highRemoteURL = try #require(
            URL(string: "https://media.example.invalid/switch-high.mp4")
        )
        let audioRemoteURL = try #require(
            URL(string: "https://media.example.invalid/switch-audio.mp4")
        )
        let lowVideoFixture = try makeFixtureTrack(
            id: 64,
            kind: .video,
            codecs: "avc1.4d400a",
            bandwidth: 50_000,
            data: lowVideoData,
            primaryURL: lowRemoteURL
        )
        let highVideoFixture = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400c",
            bandwidth: 100_000,
            data: highVideoData,
            primaryURL: highRemoteURL
        )
        let audioFixture = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 32_000,
            data: audioData,
            primaryURL: audioRemoteURL
        )
        let transport = DelayedFixtureRangeTransport(
            media: [
                lowRemoteURL: lowVideoData,
                highRemoteURL: highVideoData,
                audioRemoteURL: audioData,
            ]
        )
        let server = LoopbackPlaybackServer(
            rangeClient: HTTPRangeClient(transport: transport)
        )
        try await server.start()
        defer { server.stop() }

        let masterURL = try server.url(for: "switch/master.m3u8")
        let lowPlaylistURL = try server.url(for: "switch/low.m3u8")
        let highPlaylistURL = try server.url(for: "switch/high.m3u8")
        let audioPlaylistURL = try server.url(for: "switch/audio.m3u8")
        let subtitlePlaylistURL = try server.url(
            for: "switch/subtitles-zh.m3u8"
        )
        let lowMediaURL = try server.register(
            .remote(
                try LoopbackRemoteResource(
                    sourceURL: lowRemoteURL,
                    contentLength: Int64(lowVideoData.count),
                    contentType: AVFileType.mp4.rawValue
                )
            ),
            at: "switch/low.mp4"
        )
        let highMediaURL = try server.register(
            .remote(
                try LoopbackRemoteResource(
                    sourceURL: highRemoteURL,
                    contentLength: Int64(highVideoData.count),
                    contentType: AVFileType.mp4.rawValue
                )
            ),
            at: "switch/high.mp4"
        )
        let audioMediaURL = try server.register(
            .remote(
                try LoopbackRemoteResource(
                    sourceURL: audioRemoteURL,
                    contentLength: Int64(audioData.count),
                    contentType: AVFileType.mp4.rawValue
                )
            ),
            at: "switch/audio.mp4"
        )
        let lowPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: lowVideoFixture.representation,
            index: lowVideoFixture.index,
            mediaURI: lowMediaURL
        )
        let highPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: highVideoFixture.representation,
            index: highVideoFixture.index,
            mediaURI: highMediaURL
        )
        let audioPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: audioFixture.representation,
            index: audioFixture.index,
            mediaURI: audioMediaURL
        )
        let subtitlePlaylist = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:4
            #EXT-X-MEDIA-SEQUENCE:0
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:4.000,
            subtitles-zh.vtt
            #EXT-X-ENDLIST

            """
        let masterPlaylist = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="\(audioPlaylistURL.absoluteString)"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="中文",LANGUAGE="zh",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,URI="\(subtitlePlaylistURL.absoluteString)"
            #EXT-X-STREAM-INF:BANDWIDTH=132000,AVERAGE-BANDWIDTH=132000,RESOLUTION=256x144,FRAME-RATE=24.000,CODECS="avc1.4d400c,mp4a.40.2",AUDIO="audio",SUBTITLES="subtitles"
            \(highPlaylistURL.absoluteString)
            #EXT-X-STREAM-INF:BANDWIDTH=82000,AVERAGE-BANDWIDTH=82000,RESOLUTION=128x72,FRAME-RATE=24.000,CODECS="avc1.4d400a,mp4a.40.2",AUDIO="audio",SUBTITLES="subtitles"
            \(lowPlaylistURL.absoluteString)

            """

        _ = try server.register(
            playlistResource(lowPlaylist),
            at: "switch/low.m3u8"
        )
        _ = try server.register(
            playlistResource(highPlaylist),
            at: "switch/high.m3u8"
        )
        _ = try server.register(
            playlistResource(audioPlaylist),
            at: "switch/audio.m3u8"
        )
        _ = try server.register(
            playlistResource(subtitlePlaylist),
            at: "switch/subtitles-zh.m3u8"
        )
        _ = try server.register(
            .inMemory(
                data: Data(
                    """
                    WEBVTT

                    00:00:00.000 --> 00:00:03.500
                    运行时清晰度切换字幕保持验证

                    """.utf8
                ),
                contentType: "text/vtt"
            ),
            at: "switch/subtitles-zh.vtt"
        )
        _ = try server.register(
            playlistResource(masterPlaylist),
            at: "switch/master.m3u8"
        )

        let asset = AVURLAsset(url: masterURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredMaximumResolution = CGSize(width: 256, height: 144)
        item.preferredForwardBufferDuration = 1
        item.startsOnFirstEligibleVariant = true
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true

        try await waitUntilReadyToPlay(item)
        let legibleGroup = try #require(
            try await asset.loadMediaSelectionGroup(for: .legible)
        )
        let subtitleOption = try #require(legibleGroup.options.first)
        item.select(subtitleOption, in: legibleGroup)
        player.play()
        try await waitUntilPlaybackTime(player, reaches: 1.2)
        try await waitUntilIndicatedBitrate(
            132_000,
            appearsAfterEventCount: 0,
            on: item
        )
        let highEventCount = item.accessLog()?.events.count ?? 0

        item.preferredMaximumResolution = CGSize(width: 128, height: 72)
        try await waitUntilIndicatedBitrate(
            82_000,
            appearsAfterEventCount: highEventCount,
            on: item
        )

        #expect(player.currentItem === item)
        #expect(
            item.currentMediaSelection.selectedMediaOption(
                in: legibleGroup
            ) == subtitleOption
        )

        let replacementAsset = AVURLAsset(url: masterURL)
        let replacementItem = AVPlayerItem(asset: replacementAsset)
        replacementItem.preferredMaximumResolution = CGSize(
            width: 256,
            height: 144
        )
        replacementItem.preferredForwardBufferDuration = 1
        replacementItem.startsOnFirstEligibleVariant = true
        let replacementVideoOutput = AVPlayerItemVideoOutput()
        replacementItem.add(replacementVideoOutput)

        let replacementIsPlayable = try await replacementAsset.load(.isPlayable)
        _ = try await replacementAsset.load(.duration)
        #expect(replacementIsPlayable)
        let replacementLegibleGroup = try #require(
            try await replacementAsset.loadMediaSelectionGroup(for: .legible)
        )
        let replacementSubtitleOption = try #require(
            replacementLegibleGroup.options.first
        )
        replacementItem.select(
            replacementSubtitleOption,
            in: replacementLegibleGroup
        )

        let targetTime = player.currentTime()
        let wasPlaying = player.rate > 0
        let switchStart = ContinuousClock.now
        player.pause()
        player.replaceCurrentItem(with: replacementItem)
        try await waitUntilReadyToPlay(replacementItem)
        let didRestorePosition = await player.seek(
            to: targetTime,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        #expect(didRestorePosition)
        if wasPlaying {
            player.play()
        }
        try await waitUntilVideoFrame(
            replacementVideoOutput,
            on: replacementItem
        )
        let firstFrameDelay = switchStart.duration(
            to: ContinuousClock.now
        )
        try await waitUntilPlaybackTime(
            player,
            reaches: targetTime.seconds + 0.05
        )
        let resumedDelay = switchStart.duration(to: ContinuousClock.now)

        try await waitUntilIndicatedBitrate(
            132_000,
            appearsAfterEventCount: 0,
            on: replacementItem
        )
        let resumedTime = player.currentTime()

        #expect(player.currentItem === replacementItem)
        #expect(replacementItem.status == .readyToPlay)
        #expect(wasPlaying ? player.rate > 0 : player.rate == 0)
        #expect(abs(resumedTime.seconds - targetTime.seconds) < 0.5)
        #expect(
            replacementItem.currentMediaSelection.selectedMediaOption(
                in: replacementLegibleGroup
            ) == replacementSubtitleOption
        )
        print(
            "M501 exact-quality single-player replacement"
                + " first-frame-ms=\(milliseconds(firstFrameDelay))"
                + " resumed-progress-ms=\(milliseconds(resumedDelay))"
                + " timeline-error-ms=\(Int(abs(resumedTime.seconds - targetTime.seconds) * 1_000))"
                + " item-replaced=true subtitles-restored=true"
        )

        let didRestartActivePlayer = await player.seek(
            to: CMTime(seconds: 0.5, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        #expect(didRestartActivePlayer)
        player.play()

        let stagedPreparationStart = ContinuousClock.now
        let stagedAsset = AVURLAsset(url: masterURL)
        let stagedItem = AVPlayerItem(asset: stagedAsset)
        stagedItem.preferredMaximumResolution = CGSize(
            width: 128,
            height: 72
        )
        stagedItem.preferredForwardBufferDuration = 1
        stagedItem.startsOnFirstEligibleVariant = true
        let stagedVideoOutput = AVPlayerItemVideoOutput()
        stagedItem.add(stagedVideoOutput)
        let stagedPlayer = AVPlayer(playerItem: stagedItem)
        stagedPlayer.automaticallyWaitsToMinimizeStalling = false
        stagedPlayer.isMuted = true

        try await waitUntilReadyToPlay(stagedItem)
        let stagedLegibleGroup = try #require(
            try await stagedAsset.loadMediaSelectionGroup(for: .legible)
        )
        let stagedSubtitleOption = try #require(
            stagedLegibleGroup.options.first
        )
        stagedItem.select(stagedSubtitleOption, in: stagedLegibleGroup)
        let stagedTargetTime = player.currentTime()
        let didStageSeek = await stagedPlayer.seek(
            to: stagedTargetTime,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        #expect(didStageSeek)
        stagedPlayer.play()
        try await waitUntilVideoFrame(stagedVideoOutput, on: stagedItem)
        try await waitUntilPlaybackTime(
            stagedPlayer,
            reaches: stagedTargetTime.seconds + 0.05
        )
        let stagedPreparationDelay = stagedPreparationStart.duration(
            to: ContinuousClock.now
        )
        let handoffDrift = abs(
            player.currentTime().seconds - stagedPlayer.currentTime().seconds
        )

        #expect(stagedItem.status == .readyToPlay)
        #expect(handoffDrift < 0.5)
        #expect(
            stagedItem.currentMediaSelection.selectedMediaOption(
                in: stagedLegibleGroup
            ) == stagedSubtitleOption
        )
        print(
            "M501 exact-quality dual-player staging"
                + " background-prepare-ms=\(milliseconds(stagedPreparationDelay))"
                + " handoff-drift-ms=\(Int(handoffDrift * 1_000))"
                + " staged-frame=true subtitles-restored=true"
                + " surface-swap-unverified=true"
        )
        stagedPlayer.pause()
        player.pause()
    }

    @Test
    @MainActor
    func frozenMasterDoesNotExposeLateSubtitleRoutes() async throws {
        let videoData = try fixtureData(named: "video-avc")
        let audioData = try fixtureData(named: "audio-aac")
        let videoFixture = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400b",
            bandwidth: 50_000,
            data: videoData
        )
        let audioFixture = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 96_000,
            data: audioData
        )

        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }

        let masterURL = try server.url(for: "frozen/master.m3u8")
        let videoPlaylistURL = try server.url(for: "frozen/video.m3u8")
        let audioPlaylistURL = try server.url(for: "frozen/audio.m3u8")
        let videoMediaURL = try server.register(
            .inMemory(
                data: videoData,
                contentType: AVFileType.mp4.rawValue
            ),
            at: "frozen/video.mp4"
        )
        let audioMediaURL = try server.register(
            .inMemory(
                data: audioData,
                contentType: AVFileType.mp4.rawValue
            ),
            at: "frozen/audio.mp4"
        )
        let videoPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: videoFixture.representation,
            index: videoFixture.index,
            mediaURI: videoMediaURL
        )
        let audioPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: audioFixture.representation,
            index: audioFixture.index,
            mediaURI: audioMediaURL
        )
        let masterPlaylist = try HLSMasterPlaylistBuilder().build(
            videoVariants: [
                HLSVideoVariant(
                    representation: videoFixture.representation,
                    index: videoFixture.index,
                    playlistURI: videoPlaylistURL
                )
            ],
            audioRenditions: [
                makeHLSAudioRendition(
                    representation: audioFixture.representation,
                    index: audioFixture.index,
                    playlistURI: audioPlaylistURL
                )
            ]
        )

        _ = try server.register(
            playlistResource(videoPlaylist),
            at: "frozen/video.m3u8"
        )
        _ = try server.register(
            playlistResource(audioPlaylist),
            at: "frozen/audio.m3u8"
        )
        _ = try server.register(
            playlistResource(masterPlaylist),
            at: "frozen/master.m3u8"
        )

        let asset = AVURLAsset(url: masterURL)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        try await waitUntilReadyToPlay(item)
        let legibleGroupBeforeLateSubtitle =
            try await asset.loadMediaSelectionGroup(for: .legible)
        let legibleOptionsBeforeLateSubtitle =
            legibleGroupBeforeLateSubtitle?.options.map(\.displayName) ?? []

        let frozenMasterResponse = try await URLSession.shared.data(
            from: masterURL
        ).0
        let routeCountBeforeLateSubtitle = server.diagnosticsSnapshot()
            .registeredRouteCount

        _ = try server.register(
            playlistResource(
                """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:3
                #EXT-X-MEDIA-SEQUENCE:0
                #EXT-X-PLAYLIST-TYPE:VOD
                #EXTINF:2.083,
                subtitles-zh.vtt
                #EXT-X-ENDLIST

                """
            ),
            at: "frozen/subtitles-zh.m3u8"
        )
        _ = try server.register(
            .inMemory(
                data: Data(
                    """
                    WEBVTT

                    00:00:00.000 --> 00:00:01.500
                    迟到字幕不应进入已冻结 master

                    """.utf8
                ),
                contentType: "text/vtt"
            ),
            at: "frozen/subtitles-zh.vtt"
        )

        #expect(
            server.diagnosticsSnapshot().registeredRouteCount
                == routeCountBeforeLateSubtitle + 2
        )
        #expect(
            try await URLSession.shared.data(from: masterURL).0
                == frozenMasterResponse
        )
        let legibleGroupAfterLateSubtitle =
            try await asset.loadMediaSelectionGroup(for: .legible)
        #expect(
            legibleGroupAfterLateSubtitle?.options.map(\.displayName) ?? []
                == legibleOptionsBeforeLateSubtitle
        )
        if let legibleGroupAfterLateSubtitle {
            #expect(
                item.currentMediaSelection.selectedMediaOption(
                    in: legibleGroupAfterLateSubtitle
                ) == nil
            )
        }
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
    func bridgeOmitsOptionalAudioFormatWhenInitializationCannotBeParsed()
        async throws
    {
        let videoData = try fixtureData(named: "video-avc")
        let audioData = try fixtureData(named: "audio-aac")
        let videoURL = try #require(
            URL(string: "https://format-fallback.example/video")
        )
        let audioURL = try #require(
            URL(string: "https://format-fallback.example/audio")
        )
        let video = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400b",
            bandwidth: 50_000,
            data: videoData,
            primaryURL: videoURL
        ).representation
        let validAudio = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 96_000,
            data: audioData,
            primaryURL: audioURL
        ).representation
        let audio = MediaRepresentation(
            id: validAudio.id,
            kind: validAudio.kind,
            codecs: validAudio.codecs,
            mimeType: validAudio.mimeType,
            bandwidth: validAudio.bandwidth,
            primaryURL: validAudio.primaryURL,
            segmentBase: SegmentBase(
                initialization: try MediaByteRange(
                    start: 0,
                    endInclusive: 7
                ),
                index: validAudio.segmentBase.index
            )
        )
        let transport = FixtureRangeTransport(
            media: [videoURL: videoData, audioURL: audioData],
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

        #expect(master.contains("#EXT-X-VERSION:7\n"))
        #expect(master.contains("CHARACTERISTICS=\"public.original-content\""))
        #expect(!master.contains("CHANNELS="))
        #expect(!master.contains("BIT-DEPTH="))
        #expect(!master.contains("SAMPLE-RATE="))
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
                aiURL: audioData,
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
                ),
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
                aiURL: audioData,
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
                ),
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
                        aiURL: shiftedAIData,
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
                ),
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
                backupAudioURL: audioData,
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
    func bridgeKeepsSuccessfulCDNsForAVPlayerMediaRanges() async throws {
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
                backupAudio: audioData,
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
        let item = AVPlayerItem(url: prepared.url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true

        try await waitUntilReadyToPlay(item)
        player.play()
        try await waitUntilPlaybackTime(player, reaches: 0.15)
        player.pause()

        let requests = await transport.requests
        #expect(requests.filter { $0.url == primaryVideo }.count == 1)
        #expect(requests.filter { $0.url == primaryAudio }.count == 1)
        #expect(requests.contains { $0.url == backupVideo })
        #expect(requests.contains { $0.url == backupAudio })
        #expect(item.status == .readyToPlay)
        _ = player
    }

    @Test
    @MainActor
    func engineBuildsOneAdaptiveItemFromAllVideoRepresentations() async throws {
        let lowVideoData = try fixtureBase64Data(
            named: "video-avc-128x72-4s-global-sidx.mp4"
        )
        let highVideoData = try fixtureBase64Data(
            named: "video-avc-256x144-4s-global-sidx.mp4"
        )
        let audioData = try fixtureBase64Data(
            named: "audio-aac-4s-global-sidx.mp4"
        )
        let lowURL = try #require(
            URL(string: "https://adaptive.example/video-low")
        )
        let highURL = try #require(
            URL(string: "https://adaptive.example/video-high")
        )
        let audioURL = try #require(
            URL(string: "https://adaptive.example/audio")
        )
        let alternateAudioURL = try #require(
            URL(string: "https://adaptive.example/audio-alternate")
        )
        let lowVideo = try makeFixtureTrack(
            id: 64,
            kind: .video,
            codecs: "avc1.4d400a",
            bandwidth: 50_000,
            data: lowVideoData,
            primaryURL: lowURL,
            videoAttributes: try VideoRepresentationAttributes(
                width: 128,
                height: 72,
                frameRate: 24
            )
        ).representation
        let highVideo = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400c",
            bandwidth: 100_000,
            data: highVideoData,
            primaryURL: highURL,
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
        let alternateAudio = try makeFixtureTrack(
            id: 30_216,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 16_000,
            data: audioData,
            primaryURL: alternateAudioURL
        ).representation
        let transport = FixtureRangeTransport(
            media: [
                lowURL: lowVideoData,
                highURL: highVideoData,
                audioURL: audioData,
            ],
            failingURLs: []
        )
        let engine = AVPlayerEngine(
            bridge: DASHToHLSBridge(
                rangeClient: HTTPRangeClient(transport: transport)
            )
        )
        engine.player.isMuted = true
        let identity = PlaybackItemIdentity(
            bvid: "BV1AdaptiveFixture",
            cid: 900_002
        )

        let duplicateTrack = PlaybackAudioTrack(
            id: "duplicate",
            displayName: "原声",
            role: .original,
            isDefault: true,
            isAutoselect: true,
            representations: [audio]
        )
        let duplicateAITrack = PlaybackAudioTrack(
            id: "duplicate",
            displayName: "English（AI）",
            languageTag: "en",
            role: .machineGenerated,
            isDefault: false,
            isAutoselect: true,
            representations: [alternateAudio]
        )
        await #expect(
            throws: AVPlayerEngineError.duplicateAudioTrackID("duplicate")
        ) {
            try await engine.load(
                PlaybackRequest(
                    manifest: PlaybackManifest(
                        videoRepresentations: [highVideo, lowVideo],
                        audioTracks: [duplicateTrack, duplicateAITrack]
                    )
                ),
                identity: identity
            )
        }
        #expect(engine.player.currentItem == nil)
        #expect(engine.currentTimelineSnapshot == .idle)

        let request = PlaybackRequest(
            manifest: PlaybackManifest(
                videoRepresentations: [highVideo, lowVideo],
                originalAudioRepresentations: [audio, alternateAudio]
            )
        )
        let loadIntent = PlaybackLoadIntent()
        try await engine.load(
            request,
            identity: identity,
            intent: loadIntent
        )
        let item = try #require(engine.player.currentItem)
        let asset = try #require(item.asset as? AVURLAsset)
        let variants = try await asset.load(.variants)
        let audibleGroup = try #require(
            try await asset.loadMediaSelectionGroup(for: .audible)
        )
        let masterData = try await URLSession.shared.data(from: asset.url).0
        let master = try #require(String(data: masterData, encoding: .utf8))
        let localizedNamesURL = asset.url.deletingLastPathComponent()
            .appending(path: "metadata/localized-rendition-names.json")
        let localizedNamesData = try await URLSession.shared.data(
            from: localizedNamesURL
        ).0
        let localizedNames = try #require(
            try JSONSerialization.jsonObject(with: localizedNamesData)
                as? [String: [String: String]]
        )

        #expect(variants.count == 2)
        #expect(audibleGroup.options.count == 1)
        #expect(
            audibleGroup.options[0].hasMediaCharacteristic(
                .isOriginalContent
            )
        )
        #expect(item.preferredPeakBitRate == 0)
        #expect(item.preferredMaximumResolution == .zero)
        #expect(item.preferredForwardBufferDuration == 0)
        #expect(!item.startsOnFirstEligibleVariant)
        #expect(engine.currentTimelineSnapshot.state == .ready)
        #expect(master.contains("#EXT-X-VERSION:7\n"))
        #expect(
            master.contains(
                #"NAME="原声",LANGUAGE="und",CHARACTERISTICS="public.original-content",CHANNELS="2",BIT-DEPTH=16,SAMPLE-RATE=48000,DEFAULT=YES,AUTOSELECT=YES"#
            )
        )
        #expect(master.contains("CLOSED-CAPTIONS=NONE"))
        #expect(
            master.contains(
                #"DATA-ID="_hls.localized-rendition-names""#
            )
        )
        #expect(localizedNames.isEmpty)
        #expect(
            Set(
                variants.compactMap {
                    $0.videoAttributes?.presentationSize
                }
            ) == [
                CGSize(width: 128, height: 72),
                CGSize(width: 256, height: 144),
            ]
        )
        #expect(
            await transport.requests.contains { $0.url == lowURL }
        )
        #expect(
            await transport.requests.contains { $0.url == highURL }
        )
        #expect(
            await transport.requests.allSatisfy {
                $0.url != alternateAudioURL
            }
        )

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

        engine.stop()
        let restartedIntent = PlaybackLoadIntent()
        try await engine.load(
            request,
            identity: identity,
            intent: restartedIntent
        )
        try await engine.seek(to: .milliseconds(100))
        #expect(
            await engine.beginPlayback(
                identity: identity,
                intent: restartedIntent,
                initialPositionSeconds: nil
            ) == .rejected
        )

        engine.stop()
        let playableIntent = PlaybackLoadIntent()
        try await engine.load(
            request,
            identity: identity,
            intent: playableIntent
        )
        let playableItemIdentity = engine.player.currentItem.map(
            ObjectIdentifier.init
        )
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
        try await waitUntilPlaybackTime(engine.player, reaches: 0.15)
        #expect(
            engine.player.currentItem.map(ObjectIdentifier.init)
                == playableItemIdentity
        )
        engine.stop()

        let resumeIntent = PlaybackLoadIntent()
        try await engine.load(
            request,
            identity: identity,
            intent: resumeIntent
        )
        let resumeOutcome = await engine.beginPlayback(
            identity: identity,
            intent: resumeIntent,
            initialPositionSeconds: 0.3
        )
        let diagnosticDuration = engine.player.currentItem?.duration.seconds ?? -1
        let diagnosticSeekableCount =
            engine.player.currentItem?.seekableTimeRanges.count ?? -1
        let diagnosticLoadedCount =
            engine.player.currentItem?.loadedTimeRanges.count ?? -1
        guard case .resumed(let position, let resumeToken, _) = resumeOutcome
        else {
            let diagnostic =
                "有效首次断点未完成 seek-before-play；state=\(engine.currentTimelineSnapshot.state)，time=\(engine.player.currentTime().seconds)，duration=\(diagnosticDuration)，seekable=\(diagnosticSeekableCount)，loaded=\(diagnosticLoadedCount)"
            Issue.record(Testing.Comment(rawValue: diagnostic))
            engine.stop()
            return
        }
        #expect(position >= 0.05)
        #expect(engine.player.currentTime().seconds >= 0.05)
        try await waitUntilPlaybackStarts(engine.player)

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
        #expect(restartResults.filter { !$0 }.count == 1)
        #expect(engine.player.currentTime().seconds < 0.25)
        #expect(
            !(await engine.restartFromBeginning(
                identity: identity,
                intent: resumeIntent,
                resumeToken: resumeToken
            ))
        )
        engine.stop()
    }

    @Test
    func momentaryRateRestorationPreservesPauseAndRecoversBuffering() {
        #expect(
            MomentaryRateRestorationPolicy.action(
                timeControlStatus: .paused,
                currentRate: 0,
                momentaryRate: 2
            ) == .none
        )
        #expect(
            MomentaryRateRestorationPolicy.action(
                timeControlStatus: .playing,
                currentRate: 2,
                momentaryRate: 2
            ) == .setCurrentRate
        )
        #expect(
            MomentaryRateRestorationPolicy.action(
                timeControlStatus: .waitingToPlayAtSpecifiedRate,
                currentRate: 0,
                momentaryRate: 2
            ) == .resumeAtDefaultRate
        )
        #expect(
            MomentaryRateRestorationPolicy.action(
                timeControlStatus: .waitingToPlayAtSpecifiedRate,
                currentRate: 1.5,
                momentaryRate: 2
            ) == .none
        )
    }

    @Test
    @MainActor
    func engineFreezesNativeCatalogDefaultsOffAndSerializesResetAcrossABA()
        async throws
    {
        let videoData = try fixtureBase64Data(
            named: "video-avc-256x144-4s-global-sidx.mp4"
        )
        let audioData = try fixtureBase64Data(
            named: "audio-aac-4s-global-sidx.mp4"
        )
        let videoURL = try #require(
            URL(string: "https://native-subtitle.example/video")
        )
        let audioURL = try #require(
            URL(string: "https://native-subtitle.example/audio")
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
        let transport = FixtureRangeTransport(
            media: [videoURL: videoData, audioURL: audioData],
            failingURLs: []
        )
        let subtitleRepository = NativeSubtitleFixtureRepository()
        let engine = AVPlayerEngine(
            bridge: DASHToHLSBridge(
                rangeClient: HTTPRangeClient(transport: transport)
            ),
            subtitleUseCase: SubtitleUseCase(
                repository: subtitleRepository
            )
        )
        engine.player.isMuted = true
        let request = PlaybackRequest(
            manifest: PlaybackManifest(
                videoRepresentations: [video],
                originalAudioRepresentations: [audio]
            )
        )
        let firstA = PlaybackItemIdentity(bvid: "BV1NativeA", cid: 101)
        let itemB = PlaybackItemIdentity(bvid: "BV1NativeB", cid: 202)

        try await engine.load(request, identity: firstA)
        let item = try #require(engine.player.currentItem)
        let group = try #require(
            try await item.asset.loadMediaSelectionGroup(for: .legible)
        )
        let asset = try #require(item.asset as? AVURLAsset)
        let localizedNamesURL = asset.url.deletingLastPathComponent()
            .appending(path: "metadata/localized-rendition-names.json")
        let localizedNamesData = try await URLSession.shared.data(
            from: localizedNamesURL
        ).0
        let localizedNames = try #require(
            try JSONSerialization.jsonObject(with: localizedNamesData)
                as? [String: [String: String]]
        )
        let machineGenerated = AVMediaCharacteristic(
            rawValue: "public.machine-generated"
        )
        let automaticSubtitles = group.options.filter {
            $0.hasMediaCharacteristic(machineGenerated)
        }
        let authoredSubtitle = try #require(
            group.options.first {
                !$0.hasMediaCharacteristic(machineGenerated)
            }
        )
        // AVFoundation may localize or collapse display names differently
        // across OS releases; exact HLS names stay covered at the builder and
        // localized metadata boundaries.
        #expect(group.options.count == 3)
        #expect(group.options.allSatisfy { !$0.displayName.isEmpty })
        #expect(automaticSubtitles.count == 2)
        #expect(localizedNames["中文"]?["zh"] == "中文")
        #expect(localizedNames["中文（AI）"]?["zh"] == "中文")
        #expect(localizedNames["English（AI）"]?["en"] == "English")
        #expect(
            group.options.allSatisfy {
                !$0.hasMediaCharacteristic(.isOriginalContent)
            }
        )
        #expect(
            item.currentMediaSelection.selectedMediaOption(in: group) == nil
        )
        #expect(await subtitleRepository.cueRequestCount == 0)

        let enabledResult = await engine.toggleNativeSubtitles()
        let selectedByShortcut = try #require(
            item.currentMediaSelection.selectedMediaOption(in: group)
        )
        #expect(enabledResult == .enabled(label: selectedByShortcut.displayName))
        #expect(await engine.toggleNativeSubtitles() == .disabled)
        #expect(
            item.currentMediaSelection.selectedMediaOption(in: group) == nil
        )

        item.select(authoredSubtitle, in: group)
        engine.play()
        try await waitUntilAsync {
            await subtitleRepository.cueRequestCount == 1
        }
        engine.pause()

        let blockedBLoad = Task {
            try await engine.load(request, identity: itemB)
        }
        try await waitUntilAsync {
            await subtitleRepository.resetCalls.count == 1
        }
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
        try await waitUntilAsync {
            await subtitleRepository.resetCalls.count == 2
        }
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

    @Test
    @MainActor
    func nativeCatalogFailureFallsBackToMediaOnly() async throws {
        let videoData = try fixtureData(named: "video-avc")
        let audioData = try fixtureData(named: "audio-aac")
        let videoURL = try #require(
            URL(string: "https://media-only.example/video")
        )
        let audioURL = try #require(
            URL(string: "https://media-only.example/audio")
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
            primaryURL: audioURL
        ).representation
        let transport = FixtureRangeTransport(
            media: [videoURL: videoData, audioURL: audioData],
            failingURLs: []
        )
        let engine = AVPlayerEngine(
            bridge: DASHToHLSBridge(
                rangeClient: HTTPRangeClient(transport: transport)
            ),
            subtitleUseCase: SubtitleUseCase(
                repository: FailingNativeSubtitleRepository()
            )
        )
        engine.player.isMuted = true

        try await engine.load(
            PlaybackRequest(
                manifest: PlaybackManifest(
                    videoRepresentations: [video],
                    originalAudioRepresentations: [audio]
                )
            ),
            identity: PlaybackItemIdentity(
                bvid: "BV1MediaOnly",
                cid: 303
            )
        )

        let item = try #require(engine.player.currentItem)
        let asset = try #require(item.asset as? AVURLAsset)
        let masterBody = try await URLSession.shared.data(from: asset.url).0
        let master = try #require(
            String(data: masterBody, encoding: .utf8)
        )
        #expect(!master.contains("TYPE=SUBTITLES"))
        #expect(item.status == .readyToPlay)
        engine.stop()
    }

    @Test
    @MainActor
    func unsafeNativeSubtitleLabelFallsBackToMediaOnly() async throws {
        let videoData = try fixtureData(named: "video-avc")
        let audioData = try fixtureData(named: "audio-aac")
        let videoURL = try #require(
            URL(string: "https://unsafe-subtitle.example/video")
        )
        let audioURL = try #require(
            URL(string: "https://unsafe-subtitle.example/audio")
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
            primaryURL: audioURL
        ).representation
        let transport = FixtureRangeTransport(
            media: [videoURL: videoData, audioURL: audioData],
            failingURLs: []
        )
        let engine = AVPlayerEngine(
            bridge: DASHToHLSBridge(
                rangeClient: HTTPRangeClient(transport: transport)
            ),
            subtitleUseCase: SubtitleUseCase(
                repository: UnsafeLabelNativeSubtitleRepository()
            )
        )
        engine.player.isMuted = true

        try await engine.load(
            PlaybackRequest(
                manifest: PlaybackManifest(
                    videoRepresentations: [video],
                    originalAudioRepresentations: [audio]
                )
            ),
            identity: PlaybackItemIdentity(
                bvid: "BV1UnsafeSubtitle",
                cid: 304
            )
        )

        let item = try #require(engine.player.currentItem)
        let asset = try #require(item.asset as? AVURLAsset)
        let masterBody = try await URLSession.shared.data(from: asset.url).0
        let master = try #require(String(data: masterBody, encoding: .utf8))
        let localizedNamesURL = asset.url.deletingLastPathComponent()
            .appending(path: "metadata/localized-rendition-names.json")
        let localizedNamesData = try await URLSession.shared.data(
            from: localizedNamesURL
        ).0
        let localizedNames = try #require(
            try JSONSerialization.jsonObject(with: localizedNamesData)
                as? [String: [String: String]]
        )
        #expect(!master.contains("TYPE=SUBTITLES"))
        #expect(localizedNames.isEmpty)
        #expect(item.status == .readyToPlay)
        engine.stop()
    }

    @Test
    func subtitleCatalogGraceDoesNotWaitForNoncooperativeRepository() async throws {
        let videoData = try fixtureData(named: "video-avc")
        let audioData = try fixtureData(named: "audio-aac")
        let videoURL = try #require(
            URL(string: "https://subtitle-timeout.example/video")
        )
        let audioURL = try #require(
            URL(string: "https://subtitle-timeout.example/audio")
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
            primaryURL: audioURL
        ).representation
        let transport = FixtureRangeTransport(
            media: [videoURL: videoData, audioURL: audioData],
            failingURLs: []
        )
        let repository = NoncooperativeNativeSubtitleRepository()
        let bridge = DASHToHLSBridge(
            rangeClient: HTTPRangeClient(transport: transport),
            subtitleCatalogGrace: .milliseconds(20)
        )
        let source = NativeSubtitleSource(
            useCase: SubtitleUseCase(repository: repository),
            identity: PlaybackItemIdentity(
                bvid: "BV1SubtitleTimeout",
                cid: 305
            )
        )
        let clock = ContinuousClock()
        let prepareTask = Task {
            try await bridge.prepare(
                videos: [video],
                audioTracks: [makeSelectedAudioTrack(representation: audio)],
                headers: [:],
                subtitleSource: source
            )
        }
        try await waitUntilAsync { await repository.started }
        let start = clock.now
        let prepared = try await prepareTask.value
        defer { prepared.stop() }
        let elapsed = start.duration(to: clock.now)
        await repository.release()

        let masterBody = try await URLSession.shared.data(from: prepared.url).0
        let master = try #require(String(data: masterBody, encoding: .utf8))
        #expect(elapsed < .milliseconds(500))
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
            engine.currentTimelineSnapshot.discontinuityGeneration
                > requestedSeekGeneration
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

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment[
                "BILIKIT_RUN_PLAYER_FAILURE_POLICY_PROBE"
            ] == "1",
            "AVPlayer failure timing after repeated HTTP errors is not deterministic."
        )
    )
    @MainActor
    func nativePlayerFailureTimingAfterRangeErrors() async throws {
        let videoData = try fixtureBase64Data(
            named: "video-avc-256x144-4s-global-sidx.mp4"
        )
        let audioData = try fixtureBase64Data(
            named: "audio-aac-4s-global-sidx.mp4"
        )
        let videoURL = try #require(
            URL(string: "https://post-ready.example/video.mp4")
        )
        let audioURL = try #require(
            URL(string: "https://post-ready.example/audio.mp4")
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
        let transport = PostReadyFailureRangeTransport(
            media: [
                videoURL: videoData,
                audioURL: audioData,
            ],
            indexRanges: [
                videoURL: video.segmentBase.index,
                audioURL: audio.segmentBase.index,
            ],
            allowedMediaRequestsPerURL: 2
        )
        let engine = AVPlayerEngine(
            bridge: DASHToHLSBridge(
                rangeClient: HTTPRangeClient(transport: transport)
            )
        )
        engine.player.automaticallyWaitsToMinimizeStalling = false
        engine.player.isMuted = true
        let eventRecorder = PlayerEventRecorder()
        let eventTask = Task {
            for await event in engine.events {
                await eventRecorder.append(event)
            }
        }
        defer {
            eventTask.cancel()
            engine.stop()
        }
        let identity = PlaybackItemIdentity(
            bvid: "BV1PostReadyFailure",
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
        let nativeFailureRecorder = NativeItemFailureRecorder(item: item)
        defer { nativeFailureRecorder.stop() }

        engine.play()
        try await waitUntilPlaybackTime(engine.player, reaches: 0.15)
        for _ in 0..<200 {
            if await transport.blockedRequestCount >= 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(await transport.blockedRequestCount >= 1)
        await transport.failBlockedAndFutureMediaRequests()

        var nativeFailureObserved = false
        for _ in 0..<400 {
            if item.status == .failed || nativeFailureRecorder.failureCount > 0 {
                nativeFailureObserved = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let failureEventCount = await eventRecorder.events.count {
            if case .failed = $0 { return true }
            return false
        }
        print(
            "M501 native post-ready failure observed="
                + "\(nativeFailureObserved)"
                + " item-status=\(item.status.rawValue)"
                + " notification-count=\(nativeFailureRecorder.failureCount)"
                + " engine-event-count=\(failureEventCount)"
                + " timeline-state=\(engine.currentTimelineSnapshot.state)"
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
                audioURL: audioData,
            ],
            failingURLs: []
        )
        let engine = AVPlayerEngine(
            bridge: DASHToHLSBridge(
                rangeClient: HTTPRangeClient(transport: transport)
            )
        )
        let eventRecorder = PlayerEventRecorder()
        let eventTask = Task {
            for await event in engine.events {
                await eventRecorder.append(event)
            }
        }
        let failureRecorder = PlaybackFailureRecorder()
        let failureTask = Task {
            for await event in engine.playbackFailureEvents() {
                await failureRecorder.append(event)
            }
        }
        defer {
            eventTask.cancel()
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
            let eventCount = await eventRecorder.failureEvents().count
            let identityCount = await failureRecorder.identities().count
            return eventCount == 1
                && identityCount == 1
                && engine.currentTimelineSnapshot.state == .failed
        }
        let failureEvents = await eventRecorder.failureEvents()
        let failureIdentities = await failureRecorder.identities()

        #expect(
            failureEvents
                == [.failed(message: "PlaybackItemFailed")]
        )
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
                newAudioURL: audioData,
            ],
            indexRanges: [
                oldVideoURL: oldVideo.segmentBase.index,
                oldAudioURL: oldAudio.segmentBase.index,
                newVideoURL: newVideo.segmentBase.index,
                newAudioURL: newAudio.segmentBase.index,
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
        for _ in 0..<200 {
            if await transport.startedMediaRequestCount > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.startedMediaRequestCount > 0)

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
    func repeatedReplacementStopsOldServersAndReleasesResources() async throws {
        let videoData = try fixtureData(named: "video-avc")
        let audioData = try fixtureData(named: "audio-aac")
        let videoURL = try #require(URL(string: "https://fixture.example/video"))
        let audioURL = try #require(URL(string: "https://fixture.example/audio"))
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
            media: [
                videoURL: videoData,
                audioURL: audioData,
            ],
            failingURLs: []
        )
        let registry = LoopbackServerRegistry()
        let bridge = DASHToHLSBridge(
            rangeClient: HTTPRangeClient(transport: transport),
            serverFactory: { rangeClient in
                registry.create(rangeClient: rangeClient)
            }
        )
        var engine: AVPlayerEngine? = AVPlayerEngine(bridge: bridge)
        engine?.player.isMuted = true
        let request = PlaybackRequest(
            manifest: PlaybackManifest(
                videoRepresentations: [video],
                originalAudioRepresentations: [audio]
            )
        )

        for expectedServerCount in 1...12 {
            try await engine?.load(
                request,
                identity: PlaybackItemIdentity(
                    bvid: "BV1LoopFixture",
                    cid: Int64(900_000 + expectedServerCount)
                )
            )
            let servers = registry.servers
            #expect(servers.count == expectedServerCount)
            for server in servers.dropLast() {
                #expect(
                    server.diagnosticsSnapshot()
                        == LoopbackPlaybackServerDiagnostics(
                            isRunning: false,
                            registeredRouteCount: 0,
                            activeConnectionCount: 0,
                            activeTaskCount: 0
                        )
                )
            }
        }

        engine = nil
        for _ in 0..<100 {
            if registry.servers.allSatisfy({ !$0.diagnosticsSnapshot().isRunning }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        for server in registry.servers {
            #expect(
                server.diagnosticsSnapshot()
                    == LoopbackPlaybackServerDiagnostics(
                        isRunning: false,
                        registeredRouteCount: 0,
                        activeConnectionCount: 0,
                        activeTaskCount: 0
                    )
            )
        }
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

    private func playlistResource(
        _ playlist: String
    ) -> LoopbackPlaybackResource {
        .inMemory(
            data: Data(playlist.utf8),
            contentType: "application/vnd.apple.mpegurl"
        )
    }

    private func mpegTSTimestamp(for index: SegmentIndex) throws -> UInt64 {
        guard index.timescale > 0 else {
            throw LoopbackFixtureError.invalidTimestampMap
        }
        let product = index.earliestPresentationTime
            .multipliedReportingOverflow(by: 90_000)
        guard !product.overflow else {
            throw LoopbackFixtureError.invalidTimestampMap
        }
        return product.partialValue / UInt64(index.timescale)
    }

    @MainActor
    private func recoverableStallTrial() async throws -> RecoverableStallResult {
        let videoData = try fixtureBase64Data(
            named: "video-avc-256x144-4s-global-sidx.mp4"
        )
        let audioData = try fixtureBase64Data(
            named: "audio-aac-4s-global-sidx.mp4"
        )
        let videoRemoteURL = try #require(
            URL(string: "https://media.example.invalid/stall-video.mp4")
        )
        let audioRemoteURL = try #require(
            URL(string: "https://media.example.invalid/stall-audio.mp4")
        )
        let video = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400c",
            bandwidth: 100_000,
            data: videoData,
            primaryURL: videoRemoteURL
        )
        let audio = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 32_000,
            data: audioData,
            primaryURL: audioRemoteURL
        )
        let transport = RecoverableStallRangeTransport(
            media: [
                videoRemoteURL: videoData,
                audioRemoteURL: audioData,
            ],
            allowedRequestsPerURL: 2
        )
        let server = LoopbackPlaybackServer(
            rangeClient: HTTPRangeClient(transport: transport)
        )
        try await server.start()
        defer {
            Task { await transport.release() }
            server.stop()
        }

        let masterURL = try server.url(for: "stall/master.m3u8")
        let videoPlaylistURL = try server.url(for: "stall/video.m3u8")
        let audioPlaylistURL = try server.url(for: "stall/audio.m3u8")
        let videoMediaURL = try server.register(
            .remote(
                try LoopbackRemoteResource(
                    sourceURL: videoRemoteURL,
                    contentLength: Int64(videoData.count),
                    contentType: AVFileType.mp4.rawValue
                )
            ),
            at: "stall/video.mp4"
        )
        let audioMediaURL = try server.register(
            .remote(
                try LoopbackRemoteResource(
                    sourceURL: audioRemoteURL,
                    contentLength: Int64(audioData.count),
                    contentType: AVFileType.mp4.rawValue
                )
            ),
            at: "stall/audio.mp4"
        )
        let videoPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: video.representation,
            index: video.index,
            mediaURI: videoMediaURL
        )
        let audioPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: audio.representation,
            index: audio.index,
            mediaURI: audioMediaURL
        )
        let masterPlaylist = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="\(audioPlaylistURL.absoluteString)"
            #EXT-X-STREAM-INF:BANDWIDTH=132000,AVERAGE-BANDWIDTH=132000,RESOLUTION=256x144,FRAME-RATE=24.000,CODECS="avc1.4d400c,mp4a.40.2",AUDIO="audio"
            \(videoPlaylistURL.absoluteString)

            """
        _ = try server.register(
            playlistResource(videoPlaylist),
            at: "stall/video.m3u8"
        )
        _ = try server.register(
            playlistResource(audioPlaylist),
            at: "stall/audio.m3u8"
        )
        _ = try server.register(
            playlistResource(masterPlaylist),
            at: "stall/master.m3u8"
        )

        let item = AVPlayerItem(url: masterURL)
        item.preferredForwardBufferDuration = 0.25
        let player = AVPlayer(playerItem: item)
        #expect(player.automaticallyWaitsToMinimizeStalling)
        player.isMuted = true
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = CGRect(x: 0, y: 0, width: 256, height: 144)
        let surfaceView = NSView(frame: playerLayer.frame)
        surfaceView.wantsLayer = true
        surfaceView.layer?.addSublayer(playerLayer)
        let surfaceWindow = NSWindow(
            contentRect: surfaceView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        surfaceWindow.contentView = surfaceView
        surfaceWindow.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        surfaceWindow.orderFrontRegardless()
        defer {
            player.pause()
            playerLayer.player = nil
            surfaceWindow.orderOut(nil)
        }

        try await waitUntilReadyToPlay(item)
        player.play()
        try await waitUntilPlayerLayerReady(playerLayer, on: item)
        try await waitUntilPlaybackTime(player, reaches: 0.15)
        for _ in 0..<200 {
            if await transport.blockedRequestCount >= 1,
                player.timeControlStatus != .playing
            {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let blockedRequestCount = await transport.blockedRequestCount
        let stallStatus = player.timeControlStatus
        let stalledTime = player.currentTime().seconds
        let duration = item.duration.seconds
        await transport.release()

        var recoveredAutomatically = false
        let recoveryTarget = min(stalledTime + 0.25, duration - 0.05)
        for _ in 0..<200 {
            if player.currentTime().seconds >= recoveryTarget {
                recoveredAutomatically = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return RecoverableStallResult(
            stallStatus: stallStatus,
            recoveredAutomatically: recoveredAutomatically,
            stalledTime: stalledTime,
            finalTime: player.currentTime().seconds,
            blockedRequestCount: blockedRequestCount
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

    private func makeHLSAudioRendition(
        representation: MediaRepresentation,
        index: SegmentIndex,
        playlistURI: URL
    ) -> HLSAudioRendition {
        HLSAudioRendition(
            selectedTrack: makeSelectedAudioTrack(
                representation: representation
            ),
            index: index,
            playlistURI: playlistURI
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

    private func waitUntilReadyToPlay(_ item: AVPlayerItem) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let observationBox = PlayerItemObservationBox()
                let statuses = AsyncStream<AVPlayerItem.Status> { continuation in
                    let observation = item.observe(
                        \.status,
                        options: [.initial, .new]
                    ) { observedItem, _ in
                        continuation.yield(observedItem.status)
                    }
                    observationBox.store(observation)
                    continuation.onTermination = { _ in
                        observationBox.invalidate()
                    }
                }

                for await status in statuses {
                    switch status {
                    case .readyToPlay:
                        return
                    case .failed:
                        throw item.error ?? LoopbackFixtureError.itemFailedWithoutError
                    case .unknown:
                        continue
                    @unknown default:
                        throw LoopbackFixtureError.unknownItemStatus
                    }
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

    private func waitUntilPlaybackStarts(_ player: AVPlayer) async throws {
        for _ in 0..<100 {
            if player.timeControlStatus == .playing {
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

    private func waitUntilRequest(
        method: String,
        at relativePath: String,
        on server: LoopbackPlaybackServer
    ) async throws {
        for _ in 0..<100 {
            if try server.requestCount(
                method: method,
                at: relativePath
            ) > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LoopbackFixtureError.timedOut
    }

    private func waitUntilRequestCount(
        exceeds count: Int,
        on transport: FixtureRangeTransport
    ) async throws {
        for _ in 0..<100 {
            if await transport.requests.count > count {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LoopbackFixtureError.timedOut
    }

    private func waitUntilIndicatedBitrate(
        _ bitrate: Double,
        appearsAfterEventCount initialEventCount: Int,
        on item: AVPlayerItem
    ) async throws {
        for _ in 0..<200 {
            if item.accessLog()?.events.dropFirst(initialEventCount).contains(
                where: { $0.indicatedBitrate == bitrate }
            ) == true {
                return
            }
            if item.status == .failed {
                throw item.error ?? LoopbackFixtureError.itemFailedWithoutError
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LoopbackFixtureError.timedOut
    }

    private func waitUntilVideoFrame(
        _ output: AVPlayerItemVideoOutput,
        on item: AVPlayerItem
    ) async throws {
        for _ in 0..<200 {
            let itemTime = output.itemTime(
                forHostTime: CACurrentMediaTime()
            )
            if output.hasNewPixelBuffer(forItemTime: itemTime) {
                var displayTime = CMTime.invalid
                if output.copyPixelBuffer(
                    forItemTime: itemTime,
                    itemTimeForDisplay: &displayTime
                ) != nil {
                    return
                }
            }
            if item.status == .failed {
                throw item.error ?? LoopbackFixtureError.itemFailedWithoutError
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LoopbackFixtureError.timedOut
    }

    private func waitUntilPlayerLayerReady(
        _ layer: AVPlayerLayer,
        on item: AVPlayerItem
    ) async throws {
        for _ in 0..<200 {
            if layer.isReadyForDisplay {
                return
            }
            if item.status == .failed {
                throw item.error ?? LoopbackFixtureError.itemFailedWithoutError
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LoopbackFixtureError.timedOut
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

    private func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let seconds = Double(components.seconds)
        let attoseconds = Double(components.attoseconds)
        return Int(
            (seconds + attoseconds / 1_000_000_000_000_000_000) * 1_000
        )
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

    private func waitForLoopbackConnectionsToDrain(
        _ server: LoopbackPlaybackServer
    ) async throws {
        for _ in 0..<100 {
            let diagnostics = server.diagnosticsSnapshot()
            if diagnostics.activeConnectionCount == 0,
                diagnostics.activeTaskCount == 0
            {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LoopbackFixtureError.timedOut
    }

    private func independentProcessCanConnect(port: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = [
            "-z",
            "-w",
            "1",
            "127.0.0.1",
            String(port),
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

private final class PlayerItemObservationBox: @unchecked Sendable {
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
    case unknownItemStatus
    case timedOut
    case missingPort
    case invalidIndependentResponse
    case invalidTimestampMap
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

private actor DelayedFixtureRangeTransport: HTTPTransport {
    private let media: [URL: Data]

    init(media: [URL: Data]) {
        self.media = media
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let data = media[request.url],
            let rangeHeader = request.headers.first(where: { name, _ in
                name.caseInsensitiveCompare("Range") == .orderedSame
            })?.value,
            let range = parseRange(rangeHeader, contentLength: data.count)
        else {
            return HTTPResponse(statusCode: 400, body: Data())
        }

        try await Task.sleep(for: .milliseconds(150))
        let body = data.subdata(
            in: Int(range.start)..<(Int(range.endInclusive) + 1)
        )
        return HTTPResponse(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes \(range.start)-\(range.endInclusive)/\(data.count)"
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

private actor AdaptiveFixtureRangeTransport: HTTPTransport {
    private let media: [URL: Data]
    private let lowVideoURL: URL
    private let highVideoURL: URL
    private var isConstrained = false
    private var requestCounts: [URL: Int] = [:]

    init(
        media: [URL: Data],
        lowVideoURL: URL,
        highVideoURL: URL
    ) {
        self.media = media
        self.lowVideoURL = lowVideoURL
        self.highVideoURL = highVideoURL
    }

    func setConstrained(_ isConstrained: Bool) {
        self.isConstrained = isConstrained
    }

    func requestCount(for url: URL) -> Int {
        requestCounts[url, default: 0]
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestCounts[request.url, default: 0] += 1
        let requestOrdinal = requestCounts[request.url, default: 0]
        guard let data = media[request.url],
            let rangeHeader = request.headers.first(where: { name, _ in
                name.caseInsensitiveCompare("Range") == .orderedSame
            })?.value,
            let range = parseRange(rangeHeader, contentLength: data.count)
        else {
            return HTTPResponse(statusCode: 400, body: Data())
        }

        if request.url == highVideoURL, requestOrdinal > 2 {
            while !isConstrained {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        let delay: Duration
        if isConstrained, request.url == highVideoURL,
            requestOrdinal == 3
        {
            delay = .milliseconds(1_000)
        } else if isConstrained, request.url == highVideoURL {
            while isConstrained {
                try await Task.sleep(for: .milliseconds(25))
            }
            delay = .milliseconds(5)
        } else if isConstrained, request.url == lowVideoURL {
            delay = .milliseconds(20)
        } else {
            delay = .milliseconds(5)
        }
        try await Task.sleep(for: delay)
        let body = data.subdata(
            in: Int(range.start)..<(Int(range.endInclusive) + 1)
        )
        return HTTPResponse(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes \(range.start)-\(range.endInclusive)/\(data.count)"
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

private struct RecoverableStallResult {
    let stallStatus: AVPlayer.TimeControlStatus
    let recoveredAutomatically: Bool
    let stalledTime: Double
    let finalTime: Double
    let blockedRequestCount: Int
}

private actor RecoverableStallRangeTransport: HTTPTransport {
    private let media: [URL: Data]
    private let allowedRequestsPerURL: Int
    private var requestCounts: [URL: Int] = [:]
    private var isReleased = false
    private(set) var blockedRequestCount = 0

    init(media: [URL: Data], allowedRequestsPerURL: Int) {
        self.media = media
        self.allowedRequestsPerURL = allowedRequestsPerURL
    }

    func release() {
        isReleased = true
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let data = media[request.url],
            let rangeHeader = request.headers.first(where: { name, _ in
                name.caseInsensitiveCompare("Range") == .orderedSame
            })?.value,
            let range = parseRange(rangeHeader, contentLength: data.count)
        else {
            return HTTPResponse(statusCode: 400, body: Data())
        }

        requestCounts[request.url, default: 0] += 1
        if requestCounts[request.url, default: 0] > allowedRequestsPerURL,
            !isReleased
        {
            blockedRequestCount += 1
            while !isReleased {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let body = data.subdata(
            in: Int(range.start)..<(Int(range.endInclusive) + 1)
        )
        return HTTPResponse(
            statusCode: 206,
            headers: [
                "Content-Range":
                    "bytes \(range.start)-\(range.endInclusive)/\(data.count)"
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

private actor PlayerEventRecorder {
    private(set) var events: [PlayerEvent] = []

    func append(_ event: PlayerEvent) {
        events.append(event)
    }

    func failureEvents() -> [PlayerEvent] {
        events.filter {
            if case .failed = $0 { return true }
            return false
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

private actor NativeSubtitleFixtureRepository: SubtitleRepository {
    private(set) var cueRequestCount = 0
    private(set) var trackRequests: [PlaybackItemIdentity] = []
    private(set) var resetCalls: [PlaybackItemIdentity] = []
    private var resetContinuation: CheckedContinuation<Void, Never>?

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
            ),
            SubtitleTrack(
                id: "automatic-zh",
                languageCode: "ai-zh",
                displayName: "中文",
                kind: .automatic
            ),
            SubtitleTrack(
                id: "automatic-en",
                languageCode: "ai-en",
                displayName: "English",
                kind: .automatic
            ),
        ]
    }

    func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) -> [SubtitleCue] {
        cueRequestCount += 1
        return [
            SubtitleCue(
                startSeconds: 0,
                endSeconds: 3,
                text: "Native subtitle fixture"
            )
        ]
    }

    func reset(for identity: PlaybackItemIdentity) async {
        resetCalls.append(identity)
        await withCheckedContinuation { continuation in
            resetContinuation = continuation
        }
    }

    func releaseCurrentReset() {
        resetContinuation?.resume()
        resetContinuation = nil
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
            ),
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
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func tracks(
        for identity: PlaybackItemIdentity
    ) async -> [SubtitleTrack] {
        started = true
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

private final class NativeItemFailureRecorder: @unchecked Sendable {
    var failureCount: Int {
        lock.withLock { recordedFailureCount }
    }

    private let lock = NSLock()
    private var recordedFailureCount = 0
    private var token: (any NSObjectProtocol)?

    init(item: AVPlayerItem) {
        token = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.lock.withLock {
                self?.recordedFailureCount += 1
            }
        }
    }

    func stop() {
        guard let token else { return }
        NotificationCenter.default.removeObserver(token)
        self.token = nil
    }

    deinit {
        stop()
    }
}

private actor PostReadyFailureRangeTransport: HTTPTransport {
    private enum Mode {
        case blocking
        case failing
    }

    private let media: [URL: Data]
    private let indexRanges: [URL: MediaByteRange]
    private let allowedMediaRequestsPerURL: Int
    private var mediaRequestCounts: [URL: Int] = [:]
    private var mode: Mode = .blocking
    private(set) var blockedRequestCount = 0

    init(
        media: [URL: Data],
        indexRanges: [URL: MediaByteRange],
        allowedMediaRequestsPerURL: Int
    ) {
        self.media = media
        self.indexRanges = indexRanges
        self.allowedMediaRequestsPerURL = allowedMediaRequestsPerURL
    }

    func failBlockedAndFutureMediaRequests() {
        mode = .failing
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let data = media[request.url],
            let rangeHeader = request.headers.first(where: { name, _ in
                name.caseInsensitiveCompare("Range") == .orderedSame
            })?.value,
            let range = parseRange(rangeHeader)
        else {
            return HTTPResponse(statusCode: 400, body: Data())
        }

        if range != indexRanges[request.url] {
            mediaRequestCounts[request.url, default: 0] += 1
            if mediaRequestCounts[request.url, default: 0]
                > allowedMediaRequestsPerURL
            {
                blockedRequestCount += 1
                while mode == .blocking {
                    try await Task.sleep(for: .milliseconds(10))
                }
                return HTTPResponse(statusCode: 503, body: Data())
            }
        }

        let body = data.subdata(
            in: Int(range.start)..<(Int(range.endInclusive) + 1)
        )
        return HTTPResponse(
            statusCode: 206,
            headers: [
                "Content-Range":
                    "bytes \(range.start)-\(range.endInclusive)/\(data.count)"
            ],
            body: body
        )
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
