@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing
@testable import BiliPlayback

struct LoopbackPlaybackServerTests {
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

        let masterURL = try server.url(for: "master.m3u8")
        let videoPlaylistURL = try server.url(for: "video.m3u8")
        let audioPlaylistURL = try server.url(for: "audio.m3u8")
        let videoMediaURL = try server.register(
            .inMemory(data: videoData, contentType: AVFileType.mp4.rawValue),
            at: "video.mp4"
        )
        let audioMediaURL = try server.register(
            .inMemory(data: audioData, contentType: AVFileType.mp4.rawValue),
            at: "audio.mp4"
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
            video: videoFixture.representation,
            videoPlaylistURI: videoPlaylistURL,
            audio: audioFixture.representation,
            audioPlaylistURI: audioPlaylistURL
        )
        _ = try server.register(
            .inMemory(
                data: Data(videoPlaylist.utf8),
                contentType: "application/vnd.apple.mpegurl"
            ),
            at: "video.m3u8"
        )
        _ = try server.register(
            .inMemory(
                data: Data(audioPlaylist.utf8),
                contentType: "application/vnd.apple.mpegurl"
            ),
            at: "audio.m3u8"
        )
        _ = try server.register(
            .inMemory(
                data: Data(masterPlaylist.utf8),
                contentType: "application/vnd.apple.mpegurl"
            ),
            at: "master.m3u8"
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
        _ = player
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

        let prepared = try await bridge.prepare(video: video, audio: audio)
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
                audioRepresentations: [audio]
            )
        )

        try await engine.load(request, identity: identity)
        let loadGeneration = engine.currentTimelineSnapshot
            .discontinuityGeneration
        #expect(engine.currentTimelineSnapshot.identity == identity)
        #expect(engine.currentTimelineSnapshot.state == .ready)

        try engine.setRate(2)
        engine.play()
        try await waitUntilPlaybackTime(engine.player, reaches: 0.15)
        #expect(engine.currentTimelineSnapshot.positionSeconds > 0)
        #expect(engine.currentTimelineSnapshot.rate > 1)
        #expect(engine.currentTimelineSnapshot.state == .playing)

        engine.pause()
        #expect(engine.currentTimelineSnapshot.rate == 0)
        #expect(engine.currentTimelineSnapshot.state == .paused)

        try await engine.seek(to: .seconds(0.7))
        #expect(engine.currentTimelineSnapshot.positionSeconds >= 0.65)
        #expect(
            engine.currentTimelineSnapshot.discontinuityGeneration
                > loadGeneration
        )

        #expect(throws: AVPlayerEngineError.invalidPlaybackRate) {
            try engine.setRate(0)
        }

        let seekGeneration = engine.currentTimelineSnapshot
            .discontinuityGeneration
        engine.stop()
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
                audioRepresentations: [oldAudio]
            )
        )
        let newRequest = PlaybackRequest(
            manifest: PlaybackManifest(
                videoRepresentations: [newVideo],
                audioRepresentations: [newAudio]
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
                audioRepresentations: [audio]
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

    private func makeFixtureTrack(
        id: Int,
        kind: MediaKind,
        codecs: String,
        bandwidth: Int,
        data: Data,
        primaryURL: URL? = nil,
        backupURLs: [URL] = []
    ) throws -> (representation: MediaRepresentation, index: SegmentIndex) {
        let sidx = try #require(firstTopLevelBox(named: "sidx", in: data))
        let representation = MediaRepresentation(
            id: id,
            kind: kind,
            codecs: codecs,
            mimeType: kind == .video ? "video/mp4" : "audio/mp4",
            bandwidth: bandwidth,
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
}

private actor FixtureRangeTransport: HTTPTransport {
    private let media: [URL: Data]
    private let failingURLs: Set<URL>
    private(set) var requests: [HTTPRequest] = []

    init(media: [URL: Data], failingURLs: Set<URL>) {
        self.media = media
        self.failingURLs = failingURLs
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
        return HTTPResponse(
            statusCode: 206,
            headers: [
                "Content-Range": "bytes \(range.start)-\(range.endInclusive)/\(data.count)",
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
                "Content-Range": "bytes \(requestedRange.start)-\(requestedRange.endInclusive)/\(data.count)",
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
