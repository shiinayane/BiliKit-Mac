import BiliModels
import Foundation
import Testing

@testable import BiliPlayback

struct HLSPlaylistBuilderTests {
    @Test
    func buildsMediaPlaylistFromParsedSIDXReferences() throws {
        let representation = try makeRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            bandwidth: 2_000_000
        )
        let index = SegmentIndex(
            referenceID: 1,
            timescale: 1_000,
            earliestPresentationTime: 0,
            firstOffset: 0,
            references: [
                SegmentReference(
                    byteRange: try MediaByteRange(start: 156, endInclusive: 411),
                    duration: 2_000,
                    startsWithSAP: true,
                    sapType: 1,
                    sapDeltaTime: 0
                ),
                SegmentReference(
                    byteRange: try MediaByteRange(start: 412, endInclusive: 923),
                    duration: 3_000,
                    startsWithSAP: true,
                    sapType: 1,
                    sapDeltaTime: 0
                ),
            ]
        )
        let mediaURI = try #require(
            URL(string: "bilikit-media://representation/80")
        )

        let playlist = try HLSMediaPlaylistBuilder().build(
            representation: representation,
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
        let representation = try makeRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            bandwidth: nil,
            videoAttributes: try VideoRepresentationAttributes(
                width: 1_920,
                height: 1_080,
                frameRate: 30
            )
        )
        let index = try makeIndex(
            byteCounts: [1_000, 2_000],
            durations: [1, 1]
        )
        let mediaURI = try #require(
            URL(string: "bilikit-media://representation/80")
        )

        let playlist = try HLSIFramePlaylistBuilder().build(
            representation: representation,
            index: index,
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
        let representation = try makeRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            bandwidth: nil,
            videoAttributes: try VideoRepresentationAttributes(
                width: 1_920,
                height: 1_080,
                frameRate: 30
            )
        )
        let index = SegmentIndex(
            referenceID: 1,
            timescale: 1,
            earliestPresentationTime: 0,
            firstOffset: 0,
            references: [
                SegmentReference(
                    byteRange: try MediaByteRange(
                        start: 100,
                        endInclusive: 199
                    ),
                    duration: 1,
                    startsWithSAP: true,
                    sapType: 2,
                    sapDeltaTime: 0
                )
            ]
        )

        #expect(throws: HLSPlaylistBuilderError.nonIndependentIFrameSegments) {
            try HLSIFramePlaylistBuilder().build(
                representation: representation,
                index: index,
                mediaURI: #require(URL(string: "https://example.invalid/video.mp4"))
            )
        }
    }

    @Test
    func buildsMasterPlaylistForSeparateVideoAndAudioTracks() throws {
        let video = try makeRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            bandwidth: nil,
            videoAttributes: try VideoRepresentationAttributes(
                width: 1_920,
                height: 1_080,
                frameRate: 60_000.0 / 1_001.0
            )
        )
        let audio = try makeRepresentation(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: nil
        )
        let videoIndex = try makeIndex(
            byteCounts: [1_000, 2_000],
            durations: [1, 1]
        )
        let audioIndex = try makeIndex(
            byteCounts: [500, 500],
            durations: [1, 1]
        )

        let playlist = try HLSMasterPlaylistBuilder().build(
            videoVariants: [
                HLSVideoVariant(
                    representation: video,
                    index: videoIndex,
                    playlistURI: try #require(
                        URL(string: "bilikit-playlist://video/80.m3u8")
                    )
                )
            ],
            audioRenditions: [
                try makeAudioRendition(
                    representation: audio,
                    channelCount: 2,
                    bitDepth: 16,
                    sampleRate: 48_000,
                    index: audioIndex,
                    playlistURI: #require(
                        URL(string: "bilikit-playlist://audio/30280.m3u8")
                    )
                )
            ],
            iFrameVariants: [
                HLSIFrameVariant(
                    representation: video,
                    index: videoIndex,
                    playlistURI: try #require(
                        URL(string: "bilikit-playlist://video/80-iframe.m3u8")
                    )
                )
            ],
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
        let video = try makeRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            bandwidth: nil,
            videoAttributes: try VideoRepresentationAttributes(
                width: 1_920,
                height: 1_080,
                frameRate: 30
            )
        )
        let audio = try makeRepresentation(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: nil
        )
        let videoIndex = try makeIndex(
            byteCounts: [1_000, 1_125, 1_000],
            durations: [4, 9, 4],
            timescale: 10
        )
        let audioIndex = try makeIndex(
            byteCounts: [100],
            durations: [1]
        )

        let playlist = try HLSMasterPlaylistBuilder().build(
            videoVariants: [
                HLSVideoVariant(
                    representation: video,
                    index: videoIndex,
                    playlistURI: #require(
                        URL(string: "bilikit-playlist://video/80.m3u8")
                    )
                )
            ],
            audioRenditions: [
                try makeAudioRendition(
                    representation: audio,
                    index: audioIndex,
                    playlistURI: #require(
                        URL(string: "bilikit-playlist://audio/30280.m3u8")
                    )
                )
            ],
            iFrameVariants: [
                HLSIFrameVariant(
                    representation: video,
                    index: videoIndex,
                    playlistURI: #require(
                        URL(string: "bilikit-playlist://video/80-iframe.m3u8")
                    )
                )
            ]
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
        let video = try makeRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            bandwidth: nil,
            videoAttributes: try VideoRepresentationAttributes(
                width: 1_920,
                height: 1_080,
                frameRate: 30
            )
        )
        let mismatchedVideo = try makeRepresentation(
            id: 80,
            kind: .video,
            codecs: "hvc1.1.6.L120.B0",
            bandwidth: nil,
            videoAttributes: try VideoRepresentationAttributes(
                width: 1_920,
                height: 1_080,
                frameRate: 30
            )
        )
        let audio = try makeRepresentation(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: nil
        )
        let index = try makeIndex(byteCounts: [1_000], durations: [1])

        #expect(throws: HLSPlaylistBuilderError.unknownIFrameVariant(80)) {
            try HLSMasterPlaylistBuilder().build(
                videoVariants: [
                    HLSVideoVariant(
                        representation: video,
                        index: index,
                        playlistURI: #require(
                            URL(string: "bilikit-playlist://video/80.m3u8")
                        )
                    )
                ],
                audioRenditions: [
                    try makeAudioRendition(
                        representation: audio,
                        index: index,
                        playlistURI: #require(
                            URL(string: "bilikit-playlist://audio/30280.m3u8")
                        )
                    )
                ],
                iFrameVariants: [
                    HLSIFrameVariant(
                        representation: mismatchedVideo,
                        index: index,
                        playlistURI: #require(
                            URL(
                                string:
                                    "bilikit-playlist://video/80-iframe.m3u8"
                            )
                        )
                    )
                ]
            )
        }
    }

    @Test
    func rejectsEmptyAndDuplicateAudioRenditions() throws {
        let video = try makeRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            bandwidth: nil,
            videoAttributes: try VideoRepresentationAttributes(
                width: 1_920,
                height: 1_080,
                frameRate: 30
            )
        )
        let audio = try makeRepresentation(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: nil
        )
        let index = try makeIndex(byteCounts: [1_000], durations: [1])
        let variant = HLSVideoVariant(
            representation: video,
            index: index,
            playlistURI: try #require(
                URL(string: "bilikit-playlist://video/80.m3u8")
            )
        )
        let rendition = try makeAudioRendition(
            representation: audio,
            index: index,
            playlistURI: #require(
                URL(string: "bilikit-playlist://audio/30280.m3u8")
            )
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
        let video = try makeRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            bandwidth: nil,
            videoAttributes: try VideoRepresentationAttributes(
                width: 1_920,
                height: 1_080,
                frameRate: 30
            )
        )
        let original = try makeRepresentation(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: nil
        )
        let ai = try makeRepresentation(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: nil
        )
        let videoIndex = try makeIndex(byteCounts: [2_000], durations: [1])
        let originalIndex = try makeIndex(
            byteCounts: [500],
            durations: [1]
        )
        let aiIndex = try makeIndex(byteCounts: [750], durations: [1])

        let playlist = try HLSMasterPlaylistBuilder().build(
            videoVariants: [
                HLSVideoVariant(
                    representation: video,
                    index: videoIndex,
                    playlistURI: try #require(
                        URL(string: "bilikit-playlist://video/80.m3u8")
                    )
                )
            ],
            audioRenditions: [
                try makeAudioRendition(
                    representation: original,
                    index: originalIndex,
                    playlistURI: #require(
                        URL(string: "bilikit-playlist://audio/0/30280.m3u8")
                    )
                ),
                try makeAudioRendition(
                    representation: ai,
                    trackID: "machine-generated:en",
                    displayName: "English（AI）",
                    languageTag: "en",
                    role: .machineGenerated,
                    isDefault: false,
                    index: aiIndex,
                    playlistURI: #require(
                        URL(string: "bilikit-playlist://audio/1/30280.m3u8")
                    )
                ),
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
        let video = try makeRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            bandwidth: nil,
            videoAttributes: try VideoRepresentationAttributes(
                width: 1_920,
                height: 1_080,
                frameRate: 30
            )
        )
        let audio = try makeRepresentation(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: nil
        )
        let videoIndex = try makeIndex(byteCounts: [1_000], durations: [1])
        let audioIndex = SegmentIndex(
            referenceID: 1,
            timescale: 1,
            earliestPresentationTime: 0,
            firstOffset: 0,
            references: [
                SegmentReference(
                    byteRange: try MediaByteRange(
                        start: 0,
                        endInclusive: 499
                    ),
                    duration: 1,
                    startsWithSAP: false,
                    sapType: 0,
                    sapDeltaTime: 0
                )
            ]
        )

        let playlist = try HLSMasterPlaylistBuilder().build(
            videoVariants: [
                HLSVideoVariant(
                    representation: video,
                    index: videoIndex,
                    playlistURI: #require(
                        URL(string: "bilikit-playlist://video/80.m3u8")
                    )
                )
            ],
            audioRenditions: [
                try makeAudioRendition(
                    representation: audio,
                    index: audioIndex,
                    playlistURI: #require(
                        URL(string: "bilikit-playlist://audio/30280.m3u8")
                    )
                )
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
        let video = try makeRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            bandwidth: nil,
            videoAttributes: try VideoRepresentationAttributes(
                width: 1_920,
                height: 1_080,
                frameRate: 30
            )
        )
        let audio = try makeRepresentation(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: nil
        )
        let index = try makeIndex(byteCounts: [1_000], durations: [1])
        let metadata = [
            ("中文", "zh", []),
            ("中文（AI）", "zh", ["public.machine-generated"]),
            ("English（AI）", "en", ["public.machine-generated"]),
        ]
        let subtitleRenditions = try metadata.enumerated().map { offset, item in
            HLSSubtitleRendition(
                name: item.0,
                languageTag: item.1,
                characteristics: item.2,
                playlistURI: try #require(
                    URL(string: "bilikit-playlist://subtitle/\(offset).m3u8")
                )
            )
        }

        let playlist = try HLSMasterPlaylistBuilder().build(
            videoVariants: [
                HLSVideoVariant(
                    representation: video,
                    index: index,
                    playlistURI: try #require(
                        URL(string: "bilikit-playlist://video/80.m3u8")
                    )
                )
            ],
            audioRenditions: [
                try makeAudioRendition(
                    representation: audio,
                    index: index,
                    playlistURI: #require(
                        URL(string: "bilikit-playlist://audio/30280.m3u8")
                    )
                )
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

    @Test(arguments: ["\"", "\\", "\n", "\u{0000}"])
    func rejectsUnsafeNativeSubtitleLabels(_ unsafe: String) throws {
        let video = try makeRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            bandwidth: nil,
            videoAttributes: try VideoRepresentationAttributes(
                width: 1_920,
                height: 1_080,
                frameRate: 30
            )
        )
        let audio = try makeRepresentation(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: nil
        )
        let index = try makeIndex(byteCounts: [1_000], durations: [1])

        #expect(throws: HLSPlaylistBuilderError.unsafeAttributeValue) {
            try HLSMasterPlaylistBuilder().build(
                videoVariants: [
                    HLSVideoVariant(
                        representation: video,
                        index: index,
                        playlistURI: #require(
                            URL(string: "bilikit-playlist://video/80.m3u8")
                        )
                    )
                ],
                audioRenditions: [
                    try makeAudioRendition(
                        representation: audio,
                        index: index,
                        playlistURI: #require(
                            URL(string: "bilikit-playlist://audio/30280.m3u8")
                        )
                    )
                ],
                subtitleRenditions: [
                    HLSSubtitleRendition(
                        name: "中文\(unsafe)",
                        languageTag: "zh",
                        playlistURI: #require(
                            URL(string: "bilikit-playlist://subtitle/0.m3u8")
                        )
                    )
                ]
            )
        }
    }

    @Test
    func buildsSingleSegmentSubtitlePlaylist() throws {
        let playlist = try HLSSubtitlePlaylistBuilder().build(
            segmentURI: #require(
                URL(string: "bilikit-playlist://subtitle/generated.vtt")
            ),
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
        let audio = try makeRepresentation(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 192_000
        )
        let index = try makeIndex(
            byteCounts: [1_000],
            durations: [1]
        )

        #expect(
            throws: HLSPlaylistBuilderError.missingVideoAttributes(
                representationID: 80
            )
        ) {
            try HLSMasterPlaylistBuilder().build(
                videoVariants: [
                    HLSVideoVariant(
                        representation: video,
                        index: index,
                        playlistURI: #require(
                            URL(string: "bilikit-playlist://video/80.m3u8")
                        )
                    )
                ],
                audioRenditions: [
                    try makeAudioRendition(
                        representation: audio,
                        index: index,
                        playlistURI: #require(
                            URL(string: "bilikit-playlist://audio/30280.m3u8")
                        )
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
            SegmentIndex(
                referenceID: 1,
                timescale: timescale,
                earliestPresentationTime: earliestPresentationTime,
                firstOffset: 0,
                references: [
                    SegmentReference(
                        byteRange: try MediaByteRange(
                            start: 0,
                            endInclusive: 99
                        ),
                        duration: duration,
                        startsWithSAP: true,
                        sapType: 1,
                        sapDeltaTime: 0
                    )
                ]
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
            primaryURL: try #require(URL(string: "https://cdn.example/\(id)")),
            segmentBase: SegmentBase(
                initialization: try MediaByteRange(start: 0, endInclusive: 99),
                index: try MediaByteRange(start: 100, endInclusive: 155)
            )
        )
    }

    private func makeMasterPlaylist(frameRate: Double?) throws -> String {
        let video = try makeRepresentation(
            id: 116,
            kind: .video,
            codecs: "avc1.640032",
            bandwidth: nil,
            videoAttributes: try VideoRepresentationAttributes(
                width: 1_920,
                height: 1_080,
                frameRate: frameRate
            )
        )
        let audio = try makeRepresentation(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: nil
        )
        let index = try makeIndex(byteCounts: [1_000], durations: [1])
        return try HLSMasterPlaylistBuilder().build(
            videoVariants: [
                HLSVideoVariant(
                    representation: video,
                    index: index,
                    playlistURI: #require(
                        URL(string: "bilikit-playlist://video/116.m3u8")
                    )
                )
            ],
            audioRenditions: [
                try makeAudioRendition(
                    representation: audio,
                    index: index,
                    playlistURI: #require(
                        URL(string: "bilikit-playlist://audio/30280.m3u8")
                    )
                )
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
        playlistURI: URL
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
            playlistURI: playlistURI
        )
    }

    private func makeIndex(
        byteCounts: [Int64],
        durations: [UInt32],
        timescale: UInt32 = 1
    ) throws -> SegmentIndex {
        #expect(byteCounts.count == durations.count)
        var offset: Int64 = 0
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
                startsWithSAP: true,
                sapType: 1,
                sapDeltaTime: 0
            )
        }
        return SegmentIndex(
            referenceID: 1,
            timescale: timescale,
            earliestPresentationTime: 0,
            firstOffset: 0,
            references: references
        )
    }
}
