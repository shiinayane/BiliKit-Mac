@preconcurrency import AVFoundation
import AppKit
import BiliAPI
import BiliApplication
import BiliAuth
import BiliModels
import BiliNetworking
import BiliPlayback
import Foundation
import XCTest

final class M501MediaSubtitleTimingProbeTests: XCTestCase {
    @MainActor
    func testRealMultivariantPlaybackWhenExplicitlyConfigured()
        async throws
    {
        guard let input = try LocalProbeInput.load() else {
            throw XCTSkip(
                "仅在显式提供安全本机 probe 输入文件时运行真实 multivariant 播放探针"
            )
        }
        guard let bvid = input["bvid"],
            Self.isValidBVID(bvid)
        else {
            throw LocalProbeInputError.invalidValue
        }

        let transport = M501UniformBandwidthTransport(
            underlying: Self.ephemeralTransport()
        )
        let api = BiliAPIClient(
            requestAuthorizer: BiliCredentialRequestAuthorizer(),
            transportFactory: { transport }
        )
        let repository = BiliGuestRepository(client: api)
        let pages = try await repository.pages(for: bvid)
        let page = try XCTUnwrap(pages.first)
        let playback = try await repository.playback(
            for: bvid,
            cid: page.cid,
            quality: 80
        )
        let representations = playback.manifest.videoRepresentations
            .sorted {
                if $0.id == $1.id {
                    return ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0)
                }
                return $0.id < $1.id
            }
        let qualityIDs = Array(Set(representations.map(\.id))).sorted()
        guard let lowID = qualityIDs.first,
            let highID = qualityIDs.last,
            lowID != highID,
            let low = representations.first(where: { $0.id == lowID }),
            let high = representations.last(where: { $0.id == highID }),
            let audio = playback.manifest.audioRepresentations.max(by: {
                ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0)
            })
        else {
            XCTContext.runActivity(
                named: "m501-real-abr-playback variants="
                    + "\(qualityIDs.count) comparison=unavailable "
                    + "cleanup=complete"
            ) { _ in }
            return
        }

        let rangeClient = HTTPRangeClient(transport: transport)
        let loader = RepresentationIndexLoader(rangeClient: rangeClient)
        async let loadedLow = loader.load(
            for: low,
            headers: playback.mediaHeaders
        )
        async let loadedHigh = loader.load(
            for: high,
            headers: playback.mediaHeaders
        )
        async let loadedAudio = loader.load(
            for: audio,
            headers: playback.mediaHeaders
        )
        let (lowIndex, highIndex, audioIndex) = try await (
            loadedLow,
            loadedHigh,
            loadedAudio
        )
        let server = LoopbackPlaybackServer(rangeClient: rangeClient)
        try await server.start()
        defer { server.stop() }

        let masterURL = try server.url(for: "real-abr/master.m3u8")
        let lowPlaylistURL = try server.url(
            for: "real-abr/video-\(low.id).m3u8"
        )
        let highPlaylistURL = try server.url(
            for: "real-abr/video-\(high.id).m3u8"
        )
        let audioPlaylistURL = try server.url(
            for: "real-abr/audio-\(audio.id).m3u8"
        )
        let lowMediaURL = try Self.registerRemote(
            low,
            loaded: lowIndex,
            headers: playback.mediaHeaders,
            path: "real-abr/video-\(low.id).mp4",
            on: server
        )
        let highMediaURL = try Self.registerRemote(
            high,
            loaded: highIndex,
            headers: playback.mediaHeaders,
            path: "real-abr/video-\(high.id).mp4",
            on: server
        )
        let audioMediaURL = try Self.registerRemote(
            audio,
            loaded: audioIndex,
            headers: playback.mediaHeaders,
            path: "real-abr/audio-\(audio.id).mp4",
            on: server
        )
        let builder = HLSMediaPlaylistBuilder()
        let lowPlaylist = try builder.build(
            representation: low,
            index: lowIndex.index,
            mediaURI: lowMediaURL
        )
        let highPlaylist = try builder.build(
            representation: high,
            index: highIndex.index,
            mediaURI: highMediaURL
        )
        let audioPlaylist = try builder.build(
            representation: audio,
            index: audioIndex.index,
            mediaURI: audioMediaURL
        )
        _ = try server.register(
            Self.playlistResource(lowPlaylist),
            at: "real-abr/video-\(low.id).m3u8"
        )
        _ = try server.register(
            Self.playlistResource(highPlaylist),
            at: "real-abr/video-\(high.id).m3u8"
        )
        _ = try server.register(
            Self.playlistResource(audioPlaylist),
            at: "real-abr/audio-\(audio.id).m3u8"
        )

        guard
            let lowAttributes = await transport.videoAttributes(for: low.id),
            let highAttributes = await transport.videoAttributes(for: high.id)
        else {
            throw M501ProbeError.missingVideoAttributes
        }
        Self.recordABRStage("metadata-measured")
        let lowBandwidth = try Self.aggregateBandwidth(
            video: low,
            audio: audio
        )
        let highBandwidth = try Self.aggregateBandwidth(
            video: high,
            audio: audio
        )
        guard lowBandwidth < highBandwidth else {
            XCTFail("真实 ABR 探针要求高档声明带宽大于低档")
            return
        }
        let masterPlaylist = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="\(audioPlaylistURL.absoluteString)"
            #EXT-X-STREAM-INF:BANDWIDTH=\(highBandwidth),AVERAGE-BANDWIDTH=\(highBandwidth),RESOLUTION=\(highAttributes.width)x\(highAttributes.height),FRAME-RATE=\(Self.frameRateAttribute(highAttributes.frameRate)),CODECS="\(high.codecs),\(audio.codecs)",AUDIO="audio"
            \(highPlaylistURL.absoluteString)
            #EXT-X-STREAM-INF:BANDWIDTH=\(lowBandwidth),AVERAGE-BANDWIDTH=\(lowBandwidth),RESOLUTION=\(lowAttributes.width)x\(lowAttributes.height),FRAME-RATE=\(Self.frameRateAttribute(lowAttributes.frameRate)),CODECS="\(low.codecs),\(audio.codecs)",AUDIO="audio"
            \(lowPlaylistURL.absoluteString)

            """
        _ = try server.register(
            Self.playlistResource(masterPlaylist),
            at: "real-abr/master.m3u8"
        )

        let asset = AVURLAsset(url: masterURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2
        item.startsOnFirstEligibleVariant = true
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
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

        try await Self.waitUntilReadyToPlay(item)
        let variants = try await asset.load(.variants)
        Self.recordABRStage("item-ready")
        XCTAssertEqual(variants.count, 2)
        for expected in [lowAttributes, highAttributes] {
            XCTAssertTrue(
                variants.contains { variant in
                    guard
                        let attributes = variant.videoAttributes,
                        let nominalFrameRate = attributes.nominalFrameRate
                    else {
                        return false
                    }
                    return abs(
                        attributes.presentationSize.width
                            - Double(expected.width)
                    ) < 1
                        && abs(
                            attributes.presentationSize.height
                                - Double(expected.height)
                        ) < 1
                        && abs(
                            nominalFrameRate
                                - expected.frameRate
                        ) < 0.01
                }
            )
        }
        player.play()
        try await Self.waitUntilReadyForDisplay(playerLayer)
        let initialHigh = try await Self.waitUntilBitrate(
            Double(highBandwidth),
            on: item,
            timeout: .seconds(10)
        )
        Self.recordABRStage("initial-high")

        let constrainedBitsPerSecond =
            lowBandwidth + ((highBandwidth - lowBandwidth) / 3)
        await transport.setBitsPerSecond(constrainedBitsPerSecond)
        let downgraded = await Self.observesBitrate(
            Double(lowBandwidth),
            on: item,
            timeout: .seconds(20)
        )
        Self.recordABRStage(
            downgraded ? "downgrade-observed" : "downgrade-not-observed"
        )

        await transport.setBitsPerSecond(highBandwidth * 4)
        let recovered: Bool
        if downgraded {
            recovered = await Self.observesBitrate(
                Double(highBandwidth),
                on: item,
                timeout: .seconds(45)
            )
        } else {
            recovered = false
        }
        XCTAssertTrue(initialHigh)
        XCTAssertTrue(player.currentItem === item)

        XCTContext.runActivity(
            named: "m501-real-abr-playback variants=\(variants.count) "
                + "initial=high "
                + "downgrade=\(downgraded ? "observed" : "not-observed") "
                + "recovery=\(recovered ? "observed" : "not-observed") "
                + "recovery-window=45s "
                + "metadata=recognized "
                + "same-item=true cleanup=complete"
        ) { _ in }
    }

    @MainActor
    func testABRRepresentationAlignmentWhenExplicitlyConfigured()
        async throws
    {
        guard let input = try LocalProbeInput.load() else {
            throw XCTSkip(
                "仅在显式提供安全本机 probe 输入文件时运行真实媒体 ABR 对齐探针"
            )
        }
        guard let bvid = input["bvid"],
            Self.isValidBVID(bvid)
        else {
            throw LocalProbeInputError.invalidValue
        }

        let api = BiliAPIClient(
            requestAuthorizer: BiliCredentialRequestAuthorizer(),
            transportFactory: Self.ephemeralTransport
        )
        let repository = BiliGuestRepository(client: api)
        let pages = try await repository.pages(for: bvid)
        let page = try XCTUnwrap(pages.first)
        let playback = try await repository.playback(
            for: bvid,
            cid: page.cid,
            quality: 80
        )
        let representations = playback.manifest.videoRepresentations
            .sorted {
                if $0.id == $1.id {
                    return ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0)
                }
                return $0.id < $1.id
            }
        let distinctQualityIDs = Array(Set(representations.map(\.id))).sorted()
        guard let lowestID = distinctQualityIDs.first,
            let highestID = distinctQualityIDs.last,
            lowestID != highestID,
            let low = representations.first(where: { $0.id == lowestID }),
            let high = representations.last(where: { $0.id == highestID })
        else {
            XCTContext.runActivity(
                named: "m501-real-abr qualities=\(distinctQualityIDs.count) "
                    + "comparison=unavailable cleanup=complete"
            ) { _ in }
            return
        }

        let loader = RepresentationIndexLoader()
        async let loadedLow = loader.load(
            for: low,
            headers: playback.mediaHeaders
        )
        async let loadedHigh = loader.load(
            for: high,
            headers: playback.mediaHeaders
        )
        let (lowIndex, highIndex) = try await (loadedLow, loadedHigh)
        let lowTimeline = Self.timeline(for: lowIndex.index)
        let highTimeline = Self.timeline(for: highIndex.index)
        let tolerance = max(
            1 / Double(lowIndex.index.timescale),
            1 / Double(highIndex.index.timescale)
        )
        let startAligned =
            abs(lowTimeline.start - highTimeline.start) <= tolerance
        let durationDelta = abs(lowTimeline.duration - highTimeline.duration)
        let durationAligned = durationDelta <= tolerance
        let maximumBoundaryDelta =
            zip(
                lowTimeline.boundaries,
                highTimeline.boundaries
            )
            .map { abs($0 - $1) }
            .max() ?? 0
        let allSegmentsIndependent =
            lowIndex.index.references.allSatisfy(\.startsWithSAP)
            && highIndex.index.references.allSatisfy(\.startsWithSAP)

        XCTAssertFalse(lowIndex.index.references.isEmpty)
        XCTAssertFalse(highIndex.index.references.isEmpty)
        XCTContext.runActivity(
            named: "m501-real-abr qualities=\(distinctQualityIDs.count) "
                + "low=\(lowestID) high=\(highestID) "
                + "references=\(lowIndex.index.references.count)"
                + "/\(highIndex.index.references.count) "
                + "start=\(startAligned ? "aligned" : "misaligned") "
                + "duration=\(durationAligned ? "aligned" : "misaligned") "
                + "boundary-delta="
                + "\(Self.bucket(seconds: maximumBoundaryDelta)) "
                + "sap=\(allSegmentsIndependent ? "all" : "partial") "
                + "delta=\(Self.bucket(seconds: durationDelta)) "
                + "cleanup=complete"
        ) { _ in }
    }

    @MainActor
    func testSubtitleBodyAgainstMediaAssemblyWhenExplicitlyConfigured()
        async throws
    {
        guard let input = try LocalProbeInput.load() else {
            throw XCTSkip(
                "仅在显式提供安全本机 probe 输入文件时运行签名媒体／字幕时序探针"
            )
        }
        guard let bvid = input["bvid"],
            Self.isValidBVID(bvid)
        else {
            throw LocalProbeInputError.invalidValue
        }

        let api = BiliAPIClient(
            requestAuthorizer: BiliCredentialRequestAuthorizer(),
            transportFactory: Self.ephemeralTransport
        )
        let guestRepository = BiliGuestRepository(client: api)
        let subtitleRepository = BiliSubtitleRepository(client: api)
        let pages = try await guestRepository.pages(for: bvid)
        let page = try XCTUnwrap(pages.first)
        let identity = PlaybackItemIdentity(bvid: bvid, cid: page.cid)
        let clock = ContinuousClock()
        let start = clock.now

        async let preparedMedia = Self.prepareMedia(
            repository: guestRepository,
            identity: identity,
            start: start,
            clock: clock
        )
        async let preparedSubtitle = Self.prepareSubtitle(
            repository: subtitleRepository,
            identity: identity,
            start: start,
            clock: clock
        )
        let (media, subtitle) = try await (
            preparedMedia,
            preparedSubtitle
        )
        media.asset.stop()
        await subtitleRepository.reset(for: identity)

        let relation =
            subtitle.elapsed <= media.elapsed
            ? "subtitle-before-media"
            : "subtitle-after-media"
        let lag =
            subtitle.elapsed <= media.elapsed
            ? "none"
            : Self.bucket(subtitle.elapsed - media.elapsed)
        let kind =
            subtitle.kind == .automatic
            ? "automatic"
            : "standard"
        XCTContext.runActivity(
            named: "m501-native-subtitle-timing "
                + "relation=\(relation) "
                + "media=\(Self.bucket(media.elapsed)) "
                + "subtitle=\(Self.bucket(subtitle.elapsed)) "
                + "lag=\(lag) "
                + "tracks=\(subtitle.trackCount) "
                + "cues=\(subtitle.cueCount) "
                + "kind=\(kind) cleanup=complete"
        ) { _ in }
    }

    private static func prepareMedia(
        repository: BiliGuestRepository,
        identity: PlaybackItemIdentity,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async throws -> MediaResult {
        let playback = try await repository.playback(
            for: identity.bvid,
            cid: identity.cid,
            quality: 80
        )
        let video = try XCTUnwrap(
            playback.manifest.videoRepresentations.max {
                ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0)
            }
        )
        let audio = try XCTUnwrap(
            playback.manifest.audioRepresentations.max {
                ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0)
            }
        )
        let asset = try await DASHToHLSBridge().prepare(
            video: video,
            audio: audio,
            headers: playback.mediaHeaders
        )
        return MediaResult(
            asset: asset,
            elapsed: start.duration(to: clock.now)
        )
    }

    private static func prepareSubtitle(
        repository: BiliSubtitleRepository,
        identity: PlaybackItemIdentity,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async throws -> SubtitleResult {
        let tracks = try await repository.tracks(for: identity)
        let selectedTrack = try XCTUnwrap(
            tracks.first(where: { $0.kind == .automatic })
                ?? tracks.first
        )
        let cues = try await repository.cues(
            for: selectedTrack.id,
            identity: identity
        )
        XCTAssertFalse(cues.isEmpty)
        return SubtitleResult(
            elapsed: start.duration(to: clock.now),
            trackCount: tracks.count,
            cueCount: cues.count,
            kind: selectedTrack.kind
        )
    }

    private static func bucket(_ duration: Duration) -> String {
        let components = duration.components
        let milliseconds =
            components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        return switch milliseconds {
        case ..<250:
            "under-250ms"
        case ..<500:
            "250-499ms"
        case ..<1_000:
            "500-999ms"
        case ..<2_000:
            "1-2s"
        default:
            "over-2s"
        }
    }

    private static func bucket(seconds: Double) -> String {
        switch seconds {
        case ..<0.001:
            "under-1ms"
        case ..<0.01:
            "1-9ms"
        case ..<0.1:
            "10-99ms"
        case ..<1:
            "100-999ms"
        default:
            "over-1s"
        }
    }

    private static func timeline(
        for index: SegmentIndex
    ) -> (start: Double, duration: Double, boundaries: [Double]) {
        let timescale = Double(index.timescale)
        let start = Double(index.earliestPresentationTime) / timescale
        var elapsed = start
        let boundaries = index.references.map { reference in
            elapsed += Double(reference.duration) / timescale
            return elapsed
        }
        return (start, elapsed - start, boundaries)
    }

    private static func registerRemote(
        _ representation: MediaRepresentation,
        loaded: LoadedSegmentIndex,
        headers: [String: String],
        path: String,
        on server: LoopbackPlaybackServer
    ) throws -> URL {
        guard let contentLength = loaded.completeMediaLength else {
            throw M501ProbeError.missingMediaLength
        }
        let candidates =
            [loaded.sourceURL]
            + representation.urlCandidates.filter {
                $0 != loaded.sourceURL
            }
        return try server.register(
            .remote(
                try LoopbackRemoteResource(
                    candidateURLs: candidates,
                    contentLength: contentLength,
                    contentType: representation.mimeType,
                    headers: headers
                )
            ),
            at: path
        )
    }

    private static func aggregateBandwidth(
        video: MediaRepresentation,
        audio: MediaRepresentation
    ) throws -> Int {
        guard let videoBandwidth = video.bandwidth,
            let audioBandwidth = audio.bandwidth,
            videoBandwidth > 0,
            audioBandwidth > 0
        else {
            throw M501ProbeError.missingBandwidth
        }
        let (aggregate, overflow) = videoBandwidth.addingReportingOverflow(
            audioBandwidth
        )
        guard !overflow else {
            throw M501ProbeError.missingBandwidth
        }
        return aggregate
    }

    private static func frameRateAttribute(_ frameRate: Double) -> String {
        String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            frameRate
        )
    }

    private static func playlistResource(
        _ playlist: String
    ) -> LoopbackPlaybackResource {
        .inMemory(
            data: Data(playlist.utf8),
            contentType: "application/vnd.apple.mpegurl"
        )
    }

    @MainActor
    private static func recordABRStage(_ stage: String) {
        XCTContext.runActivity(
            named: "m501-real-abr-stage stage=\(stage) cleanup=complete"
        ) { _ in }
    }

    @MainActor
    private static func waitUntilReadyToPlay(
        _ item: AVPlayerItem
    ) async throws {
        for _ in 0..<300 {
            switch item.status {
            case .readyToPlay:
                return
            case .failed:
                throw item.error ?? M501ProbeError.playerFailed
            case .unknown:
                try await Task.sleep(for: .milliseconds(50))
            @unknown default:
                throw M501ProbeError.playerFailed
            }
        }
        throw M501ProbeError.timedOut
    }

    @MainActor
    private static func waitUntilReadyForDisplay(
        _ layer: AVPlayerLayer
    ) async throws {
        for _ in 0..<300 {
            if layer.isReadyForDisplay {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw M501ProbeError.timedOut
    }

    @MainActor
    private static func waitUntilBitrate(
        _ bitrate: Double,
        on item: AVPlayerItem,
        timeout: Duration
    ) async throws -> Bool {
        if await observesBitrate(
            bitrate,
            on: item,
            timeout: timeout
        ) {
            return true
        }
        throw M501ProbeError.timedOut
    }

    @MainActor
    private static func observesBitrate(
        _ bitrate: Double,
        on item: AVPlayerItem,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let currentBitrate = item.accessLog()?.events
                .last(where: { $0.indicatedBitrate > 0 })?
                .indicatedBitrate
            if let currentBitrate,
                abs(currentBitrate - bitrate) < 1
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func ephemeralTransport() -> any HTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSessionTransport(
            configuration: configuration,
            redirectPolicy: .reject
        )
    }

    private static func isValidBVID(_ value: String) -> Bool {
        value.count == 12
            && value.hasPrefix("BV")
            && value.allSatisfy(\.isASCII)
            && value.dropFirst(2).allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber)
            }
    }
}

private struct MediaResult {
    let asset: PreparedPlaybackAsset
    let elapsed: Duration
}

private struct SubtitleResult {
    let elapsed: Duration
    let trackCount: Int
    let cueCount: Int
    let kind: SubtitleTrackKind
}

private struct M501VideoAttributes {
    let width: Int
    let height: Int
    let frameRate: Double
}

private enum M501ProbeError: Error {
    case missingMediaLength
    case missingBandwidth
    case missingVideoAttributes
    case playerFailed
    case timedOut
}

private actor M501UniformBandwidthTransport: HTTPTransport {
    private let underlying: any HTTPTransport
    private var bitsPerSecond: Int?
    private var activeTransferCount = 0
    private var videoAttributesByID: [Int: M501VideoAttributes] = [:]

    init(underlying: any HTTPTransport) {
        self.underlying = underlying
    }

    func setBitsPerSecond(_ bitsPerSecond: Int?) {
        self.bitsPerSecond = bitsPerSecond
    }

    func videoAttributes(for representationID: Int) -> M501VideoAttributes? {
        videoAttributesByID[representationID]
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await underlying.send(request)
        captureVideoAttributes(from: response.body)
        guard let bitsPerSecond, bitsPerSecond > 0,
            !response.body.isEmpty
        else {
            return response
        }

        activeTransferCount += 1
        defer { activeTransferCount -= 1 }
        var remainingBits = response.body.count * 8
        while remainingBits > 0 {
            guard let currentBitsPerSecond = self.bitsPerSecond,
                currentBitsPerSecond > 0
            else {
                break
            }
            let share = max(
                1,
                currentBitsPerSecond / max(activeTransferCount, 1)
            )
            try await Task.sleep(for: .milliseconds(100))
            remainingBits -= max(1, share / 10)
        }
        return response
    }

    private func captureVideoAttributes(from data: Data) {
        guard
            let envelope = try? JSONDecoder().decode(
                M501PlayURLProbeEnvelope.self,
                from: data
            ),
            let representations = envelope.data?.dash?.video
        else {
            return
        }
        for representation in representations {
            guard
                let width = representation.width,
                let height = representation.height,
                width > 0,
                height > 0,
                let frameRate = Self.frameRate(
                    from: representation.frameRate
                ),
                frameRate > 0
            else {
                continue
            }
            videoAttributesByID[representation.id] = M501VideoAttributes(
                width: width,
                height: height,
                frameRate: frameRate
            )
        }
    }

    private static func frameRate(from value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        if components.count == 1 {
            return Double(components[0])
        }
        guard components.count == 2,
            let numerator = Double(components[0]),
            let denominator = Double(components[1]),
            denominator != 0
        else {
            return nil
        }
        return numerator / denominator
    }
}

private struct M501PlayURLProbeEnvelope: Decodable {
    let data: M501PlayURLProbeData?
}

private struct M501PlayURLProbeData: Decodable {
    let dash: M501PlayURLProbeDASH?
}

private struct M501PlayURLProbeDASH: Decodable {
    let video: [M501PlayURLProbeRepresentation]
}

private struct M501PlayURLProbeRepresentation: Decodable {
    let id: Int
    let width: Int?
    let height: Int?
    let frameRate: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case width
        case height
        case frameRate = "frame_rate"
    }
}
