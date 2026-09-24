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
struct DASHBridgeRouteTests {
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
            URL(string: "https://iframe-full-fragment.fixture.bilivideo.com/video.mp4")
        )
        let audioURL = try #require(
            URL(string: "https://iframe-full-fragment.fixture.bilivideo.com/audio.mp4")
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
        let bridge = makeFixtureBridge(
            FixtureRangeTransport(
                media: [videoURL: videoData, audioURL: audioData]
            )
        )

        let prepared = try await bridge.prepare(
            videos: [videoFixture.representation],
            audioTracks: [makeSelectedAudioTrack(representation: audio)],
            headers: [:],
            subtitleSource: nil
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
    func bridgeRejectsInvalidAudioRolesBeforeStartingServer() async throws {
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
            serverFactory: { registry.create() }
        )
        let original = makeSelectedAudioTrack(representation: audio)
        let cases: [([SelectedPlaybackAudioTrack], DASHToHLSBridgeError)] = [
            (
                [SelectedPlaybackAudioTrack(track: original.track, representation: video)],
                .invalidAudioTrackSelection(trackID: "original", representationID: video.id)
            ),
            (
                [makeSelectedAudioTrack(isAutoselect: false, representation: audio)],
                .unsupportedAudioTrackRole("original")
            ),
            (
                [
                    original,
                    makeSelectedAudioTrack(
                        trackID: "extra",
                        isDefault: false,
                        representation: audio
                    )
                ],
                .unsupportedAudioTrackRole("extra")
            ),
            (
                [
                    original,
                    makeSelectedAudioTrack(
                        trackID: "machine-generated:en",
                        role: .machineGenerated,
                        isDefault: false,
                        representation: audio
                    )
                ],
                .unsupportedAudioTrackRole("machine-generated:en")
            ),
            (
                [
                    original,
                    makeSelectedAudioTrack(
                        trackID: "machine-generated:en",
                        languageTag: "en",
                        role: .machineGenerated,
                        representation: audio
                    )
                ],
                .unsupportedAudioTrackRole("machine-generated:en")
            )
        ]

        for (audioTracks, expectedError) in cases {
            await #expect(throws: expectedError) {
                try await bridge.prepare(
                    videos: [video],
                    audioTracks: audioTracks,
                    headers: [:],
                    subtitleSource: nil
                )
            }
        }
        #expect(registry.servers.isEmpty)
    }

    /// 媒体来源在 DTO 映射后仍可能被线路偏好改写；bridge 在首个 SIDX 请求前再按 allowlist 复核。
    @Test(arguments: [false, true])
    func bridgeRejectsDisallowedSegmentSourceBeforeAnyUpstreamRequest(
        disallowsAudio: Bool
    ) async throws {
        let allowed = try #require(
            URL(string: "https://media.fixture.bilivideo.com/segment.mp4")
        )
        let disallowed = try #require(
            URL(string: "https://cdn.attacker.invalid/segment.mp4")
        )
        let video = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400b",
            bandwidth: 50_000,
            data: try fixtureData(named: "video-avc"),
            primaryURL: allowed,
            backupURLs: disallowsAudio ? [] : [disallowed]
        ).representation
        let audio = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 96_000,
            data: try fixtureData(named: "audio-aac"),
            primaryURL: disallowsAudio ? disallowed : allowed
        ).representation
        let transport = FixtureRangeTransport(media: [:])
        let registry = LoopbackServerRegistry()
        let bridge = DASHToHLSBridge(
            rangeClient: HTTPRangeClient(transport: transport),
            serverFactory: { registry.create() }
        )

        await #expect(
            throws: DASHToHLSBridgeError.disallowedMediaSource(
                representationID: disallowsAudio ? audio.id : video.id
            )
        ) {
            try await bridge.prepare(
                videos: [video],
                audioTracks: [makeSelectedAudioTrack(representation: audio)],
                headers: [:],
                subtitleSource: nil
            )
        }
        #expect(await transport.requests.isEmpty)
        #expect(registry.servers.isEmpty)
    }

    @Test
    func bridgePublishesOriginalAndMachineGeneratedAudioRoutes() async throws {
        let videoData = try fixtureData(named: "video-avc")
        let audioData = try fixtureData(named: "audio-aac")
        let videoURL = try #require(
            URL(string: "https://multi-audio.fixture.bilivideo.com/video")
        )
        let originalURL = try #require(
            URL(string: "https://multi-audio.fixture.bilivideo.com/original")
        )
        let aiURL = try #require(
            URL(string: "https://multi-audio.fixture.bilivideo.com/ai-en")
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
            ]
        )
        let bridge = makeFixtureBridge(transport)

        let prepared = try await bridge.prepare(
            videos: [video],
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
            ],
            headers: [:],
            subtitleSource: nil
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
            unknownLengthURLs: [aiURL]
        )
        let fallbackBridge = makeFixtureBridge(fallbackTransport)
        let fallbackPrepared = try await fallbackBridge.prepare(
            videos: [video],
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
            ],
            headers: [:],
            subtitleSource: nil
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
            URL(string: "https://multi-audio-timeline.fixture.bilivideo.com/video")
        )
        let originalURL = try #require(
            URL(string: "https://multi-audio-timeline.fixture.bilivideo.com/original")
        )
        let aiURL = try #require(
            URL(string: "https://multi-audio-timeline.fixture.bilivideo.com/ai-en")
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
        let bridge = makeFixtureBridge(
            FixtureRangeTransport(
                media: [
                    videoURL: videoData,
                    originalURL: originalData,
                    aiURL: shiftedAIData
                ]
            )
        )

        let prepared = try await bridge.prepare(
            videos: [video],
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
            ],
            headers: [:],
            subtitleSource: nil
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
            URL(string: "https://format-source.fixture.bilivideo.com/video")
        )
        let primaryAudioURL = try #require(
            URL(string: "https://format-source.fixture.bilivideo.com/audio-primary")
        )
        let backupAudioURL = try #require(
            URL(string: "https://format-source.fixture.bilivideo.com/audio-backup")
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
            ]
        )
        let bridge = makeFixtureBridge(transport)

        let prepared = try await bridge.prepare(
            videos: [video],
            audioTracks: [makeSelectedAudioTrack(representation: audio)],
            headers: [:],
            subtitleSource: nil
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
        let primaryVideo = try #require(URL(string: "https://primary.fixture.bilivideo.com/video"))
        let backupVideo = try #require(URL(string: "https://backup.fixture.bilivideo.com/video"))
        let primaryAudio = try #require(URL(string: "https://primary.fixture.bilivideo.com/audio"))
        let backupAudio = try #require(URL(string: "https://backup.fixture.bilivideo.com/audio"))
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
        let bridge = makeFixtureBridge(transport)

        let prepared = try await bridge.prepare(
            videos: [video],
            audioTracks: [makeSelectedAudioTrack(representation: audio)],
            headers: [:],
            subtitleSource: nil
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
            throw PlaybackFixtureError.invalidFixture
        }
        let referenceCountOffset = entriesOffset - 2
        let referenceCount =
            Int(result[referenceCountOffset]) << 8
            | Int(result[referenceCountOffset + 1])
        guard referenceCount > 0,
            entriesOffset + referenceCount * 12 <= sidx.offset + sidx.size
        else {
            throw PlaybackFixtureError.invalidFixture
        }
        for referenceIndex in 0..<referenceCount {
            let sapOffset = entriesOffset + referenceIndex * 12 + 8
            guard result[sapOffset] & 0x80 != 0 else {
                throw PlaybackFixtureError.invalidFixture
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
                throw PlaybackFixtureError.invalidFixture
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
            throw PlaybackFixtureError.invalidFixture
        }
        return result
    }
}
