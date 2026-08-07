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
            audio: audio,
            audioIndex: audioIndex,
            audioPlaylistURI: try #require(
                URL(string: "bilikit-playlist://audio/30280.m3u8")
            )
        )

        #expect(playlist.contains("GROUP-ID=\"audio-30280\""))
        #expect(playlist.contains("BANDWIDTH=20000"))
        #expect(playlist.contains("AVERAGE-BANDWIDTH=16000"))
        #expect(playlist.contains("RESOLUTION=1920x1080"))
        #expect(playlist.contains("FRAME-RATE=59.940"))
        #expect(playlist.contains("CODECS=\"avc1.640032,mp4a.40.2\""))
        #expect(playlist.contains("bilikit-playlist://video/80.m3u8"))
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
        let labels = ["中文", "中文（AI）", "English"]
        let subtitleRenditions = try labels.enumerated().map { offset, label in
            HLSSubtitleRendition(
                name: label,
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
            audio: audio,
            audioIndex: index,
            audioPlaylistURI: try #require(
                URL(string: "bilikit-playlist://audio/30280.m3u8")
            ),
            subtitleRenditions: subtitleRenditions
        )

        for label in labels {
            #expect(playlist.contains("NAME=\"\(label)\""))
        }
        #expect(playlist.contains("DEFAULT=NO,AUTOSELECT=NO,FORCED=NO"))
        #expect(playlist.contains("SUBTITLES=\"subtitles\""))
        #expect(!playlist.contains("LANGUAGE="))
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
                audio: audio,
                audioIndex: index,
                audioPlaylistURI: #require(
                    URL(string: "bilikit-playlist://audio/30280.m3u8")
                ),
                subtitleRenditions: [
                    HLSSubtitleRendition(
                        name: "中文\(unsafe)",
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
                audio: audio,
                audioIndex: index,
                audioPlaylistURI: #require(
                    URL(string: "bilikit-playlist://audio/30280.m3u8")
                )
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
            !bridge.hasMatchingSubtitleTimeline(
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

    private func makeIndex(
        byteCounts: [Int64],
        durations: [UInt32]
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
            timescale: 1,
            earliestPresentationTime: 0,
            firstOffset: 0,
            references: references
        )
    }
}
