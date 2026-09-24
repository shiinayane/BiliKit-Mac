import BiliModels
import Foundation
import Testing

@testable import BiliPlayback

struct HLSPlaylistBuilderTests {
    @Test
    func buildsMediaPlaylistFromParsedSIDXReferences() throws {
        let index = try makeIndex(
            byteCounts: [256, 512],
            durations: [2_000, 3_000],
            timescale: 1_000,
            startOffset: 156
        )
        let mediaURI = try #require(
            URL(string: "bilikit-media://representation/80")
        )

        let playlist = try HLSMediaPlaylistBuilder().build(
            representation: try makeVideo(bandwidth: 2_000_000),
            index: index,
            mediaURI: mediaURI
        )

        #expect(playlist.contains("#EXT-X-TARGETDURATION:3"))
        #expect(playlist.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        #expect(
            playlist.contains(
                "#EXT-X-MAP:URI=\"bilikit-media://representation/80\",BYTERANGE=\"100@0\""
            )
        )
        #expect(playlist.contains("#EXTINF:2.000000,"))
        #expect(playlist.contains("#EXT-X-BYTERANGE:256@156"))
        #expect(playlist.contains("#EXT-X-BYTERANGE:512@412"))
        #expect(playlist.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    @Test
    func buildsFullFragmentIFramePlaylistWithoutRewritingMedia() throws {
        let mediaURI = try #require(
            URL(string: "bilikit-media://representation/80")
        )

        let playlist = try HLSIFramePlaylistBuilder().build(
            representation: try makeVideo(),
            index: try makeIndex(byteCounts: [1_000, 2_000], durations: [1, 1]),
            mediaURI: mediaURI
        )

        #expect(playlist.contains("#EXT-X-I-FRAMES-ONLY\n"))
        #expect(
            playlist.contains(
                #"#EXT-X-MAP:URI="bilikit-media://representation/80",BYTERANGE="100@0""#
            )
        )
        #expect(playlist.contains("#EXT-X-BYTERANGE:1000@0"))
        #expect(playlist.contains("#EXT-X-BYTERANGE:2000@1000"))
        #expect(playlist.components(separatedBy: mediaURI.absoluteString).count == 4)
    }

    @Test
    func rejectsIFramePlaylistWithoutTypeOneBoundarySAP() throws {
        let index = try makeIndex(
            byteCounts: [100],
            durations: [1],
            startOffset: 100,
            sapType: 2
        )

        #expect(throws: HLSPlaylistBuilderError.nonIndependentIFrameSegments) {
            try HLSIFramePlaylistBuilder().build(
                representation: try makeVideo(),
                index: index,
                mediaURI: #require(URL(string: "https://example.invalid/video.mp4"))
            )
        }
    }

    @Test
    func buildsMasterPlaylistForSeparateVideoAndAudioTracks() throws {
        let video = try makeVideo(frameRate: 60_000.0 / 1_001.0)
        let videoIndex = try makeIndex(
            byteCounts: [1_000, 2_000],
            durations: [1, 1]
        )
        let audioIndex = try makeIndex(
            byteCounts: [500, 500],
            durations: [1, 1]
        )

        let playlist = try HLSMasterPlaylistBuilder().build(
            videoVariants: [try makeVideoVariant(video, index: videoIndex)],
            audioRenditions: [
                try makeAudioRendition(
                    representation: makeAudio(),
                    channelCount: 2,
                    bitDepth: 16,
                    sampleRate: 48_000,
                    index: audioIndex
                )
            ],
            iFrameVariants: [try makeIFrameVariant(video, index: videoIndex)],
            localizedRenditionNamesURI: URL(
                string:
                    "bilikit-playlist://metadata/localized-rendition-names.json"
            )
        )

        #expect(playlist.contains("#EXT-X-VERSION:7\n"))
        #expect(playlist.contains("#EXT-X-INDEPENDENT-SEGMENTS\n"))
        #expect(
            playlist.contains(
                #"#EXT-X-SESSION-DATA:DATA-ID="_hls.localized-rendition-names",URI="bilikit-playlist://metadata/localized-rendition-names.json""#
            )
        )
        #expect(
            playlist.contains(
                #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-30280",NAME="原声",LANGUAGE="und",CHARACTERISTICS="public.original-content",CHANNELS="2",BIT-DEPTH=16,SAMPLE-RATE=48000,DEFAULT=YES,AUTOSELECT=YES,URI="bilikit-playlist://audio/30280.m3u8""#
            )
        )
        #expect(
            playlist.contains(
                #"#EXT-X-STREAM-INF:BANDWIDTH=20000,AVERAGE-BANDWIDTH=16000,RESOLUTION=1920x1080,FRAME-RATE=59.940,CODECS="avc1.640032,mp4a.40.2",AUDIO="audio-30280",CLOSED-CAPTIONS=NONE"#
            )
        )
        #expect(playlist.contains("bilikit-playlist://video/80.m3u8"))
        #expect(
            playlist.contains(
                #"#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=16000,AVERAGE-BANDWIDTH=12000,RESOLUTION=1920x1080,CODECS="avc1.640032",URI="bilikit-playlist://video/80-iframe.m3u8""#
            )
        )
    }

    @Test
    func serializesDomainFrameRateWithoutBiliSpecificPolicy() throws {
        let highFrameRatePlaylist = try makeMasterPlaylist(frameRate: 120)
        #expect(highFrameRatePlaylist.contains("FRAME-RATE=120.000"))

        let arbitraryFrameRatePlaylist = try makeMasterPlaylist(
            frameRate: 62.5
        )
        #expect(arbitraryFrameRatePlaylist.contains("FRAME-RATE=62.500"))

        let missingFrameRatePlaylist = try makeMasterPlaylist(frameRate: nil)
        #expect(!missingFrameRatePlaylist.contains("FRAME-RATE="))
        #expect(
            missingFrameRatePlaylist.contains(
                "bilikit-playlist://video/116.m3u8"
            )
        )
    }

    @Test
    func usesOnlyConformingPeakWindowsForRegularAndIFrameVariants() throws {
        let video = try makeVideo()
        let videoIndex = try makeIndex(
            byteCounts: [1_000, 1_125, 1_000],
            durations: [4, 9, 4],
            timescale: 10
        )

        let playlist = try HLSMasterPlaylistBuilder().build(
            videoVariants: [try makeVideoVariant(video, index: videoIndex)],
            audioRenditions: [
                try makeAudioRendition(
                    representation: makeAudio(),
                    index: makeIndex(byteCounts: [100], durations: [1])
                )
            ],
            iFrameVariants: [try makeIFrameVariant(video, index: videoIndex)]
        )

        #expect(
            playlist.contains(
                "#EXT-X-STREAM-INF:BANDWIDTH=13877,AVERAGE-BANDWIDTH=15506,"
            )
        )
        #expect(
            playlist.contains(
                "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=13077,AVERAGE-BANDWIDTH=14706,"
            )
        )
    }

    @Test
    func rejectsIFrameVariantThatOnlySharesTheRegularVariantID() throws {
        let mismatchedVideo = try makeVideo(codecs: "hvc1.1.6.L120.B0")
        let index = try makeIndex(byteCounts: [1_000], durations: [1])

        #expect(throws: HLSPlaylistBuilderError.unknownIFrameVariant(80)) {
            try HLSMasterPlaylistBuilder().build(
                videoVariants: [try makeVideoVariant(makeVideo(), index: index)],
                audioRenditions: [
                    try makeAudioRendition(representation: makeAudio(), index: index)
                ],
                iFrameVariants: [try makeIFrameVariant(mismatchedVideo, index: index)]
            )
        }
    }

    @Test
    func rejectsEmptyAndDuplicateAudioRenditions() throws {
        let index = try makeIndex(byteCounts: [1_000], durations: [1])
        let variant = try makeVideoVariant(makeVideo(), index: index)
        let rendition = try makeAudioRendition(
            representation: makeAudio(),
            index: index
        )

        #expect(
            throws: HLSPlaylistBuilderError.unsupportedAudioRenditionCount(0)
        ) {
            try HLSMasterPlaylistBuilder().build(
                videoVariants: [variant],
                audioRenditions: []
            )
        }
        #expect(
            throws: HLSPlaylistBuilderError.invalidDefaultAudioRenditionCount(2)
        ) {
            try HLSMasterPlaylistBuilder().build(
                videoVariants: [variant],
                audioRenditions: [rendition, rendition]
            )
        }
    }

    @Test
    func buildsSystemSelectableMachineGeneratedAudioRendition() throws {
        let playlist = try HLSMasterPlaylistBuilder().build(
            videoVariants: [
                try makeVideoVariant(
                    makeVideo(),
                    index: makeIndex(byteCounts: [2_000], durations: [1])
                )
            ],
            audioRenditions: [
                try makeAudioRendition(
                    representation: makeAudio(),
                    index: makeIndex(byteCounts: [500], durations: [1]),
                    playlistPath: "audio/0/30280.m3u8"
                ),
                try makeAudioRendition(
                    representation: makeAudio(),
                    trackID: "machine-generated:en",
                    displayName: "English（AI）",
                    languageTag: "en",
                    role: .machineGenerated,
                    isDefault: false,
                    index: makeIndex(byteCounts: [750], durations: [1]),
                    playlistPath: "audio/1/30280.m3u8"
                )
            ]
        )

        #expect(
            playlist.contains(
                #"GROUP-ID="audio",NAME="原声",LANGUAGE="und",CHARACTERISTICS="public.original-content",DEFAULT=YES,AUTOSELECT=YES"#
            )
        )
        #expect(
            playlist.contains(
                #"GROUP-ID="audio",NAME="English（AI）",LANGUAGE="en",CHARACTERISTICS="public.machine-generated",DEFAULT=NO,AUTOSELECT=YES"#
            )
        )
        #expect(!playlist.contains("public.translation"))
        #expect(playlist.contains(#"AUDIO="audio""#))
        #expect(playlist.contains("BANDWIDTH=22000"))
    }

    @Test
    func degradesOptionalAudioFormatAndIndependentSegmentsConservatively()
        throws
    {
        let audioIndex = try makeIndex(
            byteCounts: [500],
            durations: [1],
            startsWithSAP: false,
            sapType: 0
        )

        let playlist = try HLSMasterPlaylistBuilder().build(
            videoVariants: [
                try makeVideoVariant(
                    makeVideo(),
                    index: makeIndex(byteCounts: [1_000], durations: [1])
                )
            ],
            audioRenditions: [
                try makeAudioRendition(representation: makeAudio(), index: audioIndex)
            ]
        )

        #expect(playlist.contains("#EXT-X-VERSION:7\n"))
        #expect(!playlist.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        #expect(!playlist.contains("CHANNELS="))
        #expect(!playlist.contains("BIT-DEPTH="))
        #expect(!playlist.contains("SAMPLE-RATE="))
        #expect(
            playlist.contains(
                #"NAME="原声",LANGUAGE="und",CHARACTERISTICS="public.original-content",DEFAULT=YES,AUTOSELECT=YES"#
            )
        )
    }

    @Test
    func buildsNativeSubtitleRenditionsWithExactLabelsAndDefaultOff() throws {
        let index = try makeIndex(byteCounts: [1_000], durations: [1])
        let metadata = [
            ("中文", "zh", []),
            ("中文（AI）", "zh", ["public.machine-generated"]),
            ("English（AI）", "en", ["public.machine-generated"])
        ]
        let subtitleRenditions = try metadata.enumerated().map { offset, item in
            HLSSubtitleRendition(
                name: item.0,
                languageTag: item.1,
                characteristics: item.2,
                playlistURI: try playlistURL("subtitle/\(offset).m3u8")
            )
        }

        let playlist = try HLSMasterPlaylistBuilder().build(
            videoVariants: [try makeVideoVariant(makeVideo(), index: index)],
            audioRenditions: [
                try makeAudioRendition(representation: makeAudio(), index: index)
            ],
            subtitleRenditions: subtitleRenditions
        )

        #expect(
            playlist.contains(
                #"#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="中文",LANGUAGE="zh",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,URI="bilikit-playlist://subtitle/0.m3u8""#
            )
        )
        #expect(
            playlist.contains(
                #"#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="中文（AI）",LANGUAGE="zh",CHARACTERISTICS="public.machine-generated",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,URI="bilikit-playlist://subtitle/1.m3u8""#
            )
        )
        #expect(
            playlist.contains(
                #"#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="English（AI）",LANGUAGE="en",CHARACTERISTICS="public.machine-generated",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,URI="bilikit-playlist://subtitle/2.m3u8""#
            )
        )
        #expect(playlist.contains("SUBTITLES=\"subtitles\""))
        #expect(playlist.contains("CLOSED-CAPTIONS=NONE"))
    }

    @Test(
        arguments: [
            ("http://127.0.0.1:1/a%22b.m3u8", true),
            ("", false),
            ("a\"b", false),
            ("a\\b", false),
            ("a\rb", false),
            ("a\nb", false),
            ("a\tb", false),
            ("a\u{0000}b", false),
            ("a\u{007F}b", false),
            ("a\u{0085}b", false),
            ("a\u{200B}b", false)
        ]
    )
    func playlistTextRejectsEmptyQuoteBackslashAndControlCharacters(
        _ text: String,
        isSafe: Bool
    ) {
        #expect(isPlaylistSafeText(text) == isSafe)
    }

    @Test(arguments: ["\"", "\\", "\n", "\u{0000}"])
    func rejectsUnsafeNativeSubtitleLabels(_ unsafe: String) throws {
        let index = try makeIndex(byteCounts: [1_000], durations: [1])

        #expect(throws: HLSPlaylistBuilderError.unsafeAttributeValue) {
            try HLSMasterPlaylistBuilder().build(
                videoVariants: [try makeVideoVariant(makeVideo(), index: index)],
                audioRenditions: [
                    try makeAudioRendition(representation: makeAudio(), index: index)
                ],
                subtitleRenditions: [
                    HLSSubtitleRendition(
                        name: "中文\(unsafe)",
                        languageTag: "zh",
                        playlistURI: try playlistURL("subtitle/0.m3u8")
                    )
                ]
            )
        }
    }

    @Test
    func buildsSingleSegmentSubtitlePlaylist() throws {
        let playlist = try HLSSubtitlePlaylistBuilder().build(
            segmentURI: playlistURL("subtitle/generated.vtt"),
            duration: 3.25
        )

        #expect(playlist.contains("#EXT-X-TARGETDURATION:4"))
        #expect(playlist.contains("#EXTINF:3.250000,"))
        #expect(playlist.contains("bilikit-playlist://subtitle/generated.vtt"))
        #expect(playlist.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    @Test
    func rejectsMasterPlaylistWithoutVideoAttributes() throws {
        let video = try makeRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            bandwidth: nil
        )
        let index = try makeIndex(byteCounts: [1_000], durations: [1])

        #expect(
            throws: HLSPlaylistBuilderError.missingVideoAttributes(
                representationID: 80
            )
        ) {
            try HLSMasterPlaylistBuilder().build(
                videoVariants: [try makeVideoVariant(video, index: index)],
                audioRenditions: [
                    try makeAudioRendition(
                        representation: makeAudio(bandwidth: 192_000),
                        index: index
                    )
                ]
            )
        }
    }

    @Test
    func nativeSubtitleTimelineRequiresEquivalentABROrigins() throws {
        func index(
            timescale: UInt32,
            earliestPresentationTime: UInt64,
            duration: UInt32
        ) throws -> SegmentIndex {
            try makeIndex(
                byteCounts: [100],
                durations: [duration],
                timescale: timescale,
                earliestPresentationTime: earliestPresentationTime
            )
        }
        let canonical = try index(
            timescale: 1_000,
            earliestPresentationTime: 100,
            duration: 4_000
        )
        let equivalent = try index(
            timescale: 90_000,
            earliestPresentationTime: 9_000,
            duration: 360_000
        )
        let shifted = try index(
            timescale: 90_000,
            earliestPresentationTime: 9_090,
            duration: 360_000
        )
        let shorter = try index(
            timescale: 90_000,
            earliestPresentationTime: 9_000,
            duration: 359_000
        )
        let bridge = DASHToHLSBridge()

        #expect(
            bridge.hasMatchingSubtitleTimeline(
                equivalent,
                canonical: canonical
            )
        )
        #expect(
            bridge.hasMatchingAudioTimeline(
                equivalent,
                canonical: canonical
            )
        )
        #expect(
            !bridge.hasMatchingSubtitleTimeline(
                shifted,
                canonical: canonical
            )
        )
        #expect(
            !bridge.hasMatchingAudioTimeline(
                shifted,
                canonical: canonical
            )
        )
        #expect(
            bridge.hasMatchingSubtitleTimeline(
                shorter,
                canonical: canonical
            )
        )
    }

    private func makeRepresentation(
        id: Int,
        kind: MediaKind,
        codecs: String,
        bandwidth: Int?,
        videoAttributes: VideoRepresentationAttributes? = nil
    ) throws -> MediaRepresentation {
        MediaRepresentation(
            id: id,
            kind: kind,
            codecs: codecs,
            mimeType: kind == .video ? "video/mp4" : "audio/mp4",
            bandwidth: bandwidth,
            videoAttributes: videoAttributes,
            primaryURL: try #require(URL(string: "https://cdn.fixture.bilivideo.com/\(id)")),
            segmentBase: SegmentBase(
                initialization: try MediaByteRange(start: 0, endInclusive: 99),
                index: try MediaByteRange(start: 100, endInclusive: 155)
            )
        )
    }

    /// 1080p AVC 视频 representation；帧率可省略以验证不输出 FRAME-RATE。
    private func makeVideo(
        id: Int = 80,
        codecs: String = "avc1.640032",
        bandwidth: Int? = nil,
        frameRate: Double? = 30
    ) throws -> MediaRepresentation {
        try makeRepresentation(
            id: id,
            kind: .video,
            codecs: codecs,
            bandwidth: bandwidth,
            videoAttributes: VideoRepresentationAttributes(
                width: 1_920,
                height: 1_080,
                frameRate: frameRate
            )
        )
    }

    private func makeAudio(bandwidth: Int? = nil) throws -> MediaRepresentation {
        try makeRepresentation(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: bandwidth
        )
    }

    private func playlistURL(_ path: String) throws -> URL {
        try #require(URL(string: "bilikit-playlist://\(path)"))
    }

    private func makeVideoVariant(
        _ video: MediaRepresentation,
        index: SegmentIndex
    ) throws -> HLSVideoVariant {
        HLSVideoVariant(
            representation: video,
            index: index,
            playlistURI: try playlistURL("video/\(video.id).m3u8")
        )
    }

    private func makeIFrameVariant(
        _ video: MediaRepresentation,
        index: SegmentIndex
    ) throws -> HLSIFrameVariant {
        HLSIFrameVariant(
            representation: video,
            index: index,
            playlistURI: try playlistURL("video/\(video.id)-iframe.m3u8")
        )
    }

    private func makeMasterPlaylist(frameRate: Double?) throws -> String {
        let index = try makeIndex(byteCounts: [1_000], durations: [1])
        return try HLSMasterPlaylistBuilder().build(
            videoVariants: [
                try makeVideoVariant(
                    makeVideo(id: 116, frameRate: frameRate),
                    index: index
                )
            ],
            audioRenditions: [
                try makeAudioRendition(representation: makeAudio(), index: index)
            ]
        )
    }

    private func makeAudioRendition(
        representation: MediaRepresentation,
        trackID: String = "original",
        displayName: String = "原声",
        languageTag: String? = nil,
        role: PlaybackAudioTrack.Role = .original,
        isDefault: Bool = true,
        isAutoselect: Bool = true,
        channelCount: Int? = nil,
        bitDepth: Int? = nil,
        sampleRate: Int? = nil,
        index: SegmentIndex,
        playlistPath: String = "audio/30280.m3u8"
    ) throws -> HLSAudioRendition {
        let track = PlaybackAudioTrack(
            id: trackID,
            displayName: displayName,
            languageTag: languageTag,
            role: role,
            isDefault: isDefault,
            isAutoselect: isAutoselect,
            representations: [representation]
        )
        return HLSAudioRendition(
            selectedTrack: SelectedPlaybackAudioTrack(
                track: track,
                representation: representation
            ),
            channelCount: channelCount,
            bitDepth: bitDepth,
            sampleRate: sampleRate,
            index: index,
            playlistURI: try playlistURL(playlistPath)
        )
    }

    /// 连续 fragment 的 SIDX；默认每段都以 type 1 SAP 开始。
    private func makeIndex(
        byteCounts: [Int64],
        durations: [UInt32],
        timescale: UInt32 = 1,
        earliestPresentationTime: UInt64 = 0,
        startOffset: Int64 = 0,
        startsWithSAP: Bool = true,
        sapType: UInt8 = 1
    ) throws -> SegmentIndex {
        #expect(byteCounts.count == durations.count)
        var offset = startOffset
        let references = try zip(byteCounts, durations).map {
            byteCount,
            duration in
            defer { offset += byteCount }
            return SegmentReference(
                byteRange: try MediaByteRange(
                    start: offset,
                    endInclusive: offset + byteCount - 1
                ),
                duration: duration,
                startsWithSAP: startsWithSAP,
                sapType: sapType,
                sapDeltaTime: 0
            )
        }
        return SegmentIndex(
            referenceID: 1,
            timescale: timescale,
            earliestPresentationTime: earliestPresentationTime,
            firstOffset: 0,
            references: references
        )
    }
}
