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
            bandwidth: 2_000_000
        )
        let audio = try makeRepresentation(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 192_000
        )

        let playlist = try HLSMasterPlaylistBuilder().build(
            video: video,
            videoPlaylistURI: try #require(
                URL(string: "bilikit-playlist://video/80.m3u8")
            ),
            audio: audio,
            audioPlaylistURI: try #require(
                URL(string: "bilikit-playlist://audio/30280.m3u8")
            )
        )

        #expect(playlist.contains("GROUP-ID=\"audio-30280\""))
        #expect(playlist.contains("BANDWIDTH=2192000"))
        #expect(playlist.contains("CODECS=\"avc1.640032,mp4a.40.2\""))
        #expect(playlist.contains("bilikit-playlist://video/80.m3u8"))
    }

    @Test
    func rejectsMasterPlaylistWhenBandwidthIsUnavailable() throws {
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

        #expect(
            throws: HLSPlaylistBuilderError.missingBandwidth(
                representationID: 80
            )
        ) {
            try HLSMasterPlaylistBuilder().build(
                video: video,
                videoPlaylistURI: #require(
                    URL(string: "bilikit-playlist://video/80.m3u8")
                ),
                audio: audio,
                audioPlaylistURI: #require(
                    URL(string: "bilikit-playlist://audio/30280.m3u8")
                )
            )
        }
    }

    private func makeRepresentation(
        id: Int,
        kind: MediaKind,
        codecs: String,
        bandwidth: Int?
    ) throws -> MediaRepresentation {
        MediaRepresentation(
            id: id,
            kind: kind,
            codecs: codecs,
            mimeType: kind == .video ? "video/mp4" : "audio/mp4",
            bandwidth: bandwidth,
            primaryURL: try #require(URL(string: "https://cdn.example/\(id)")),
            segmentBase: SegmentBase(
                initialization: try MediaByteRange(start: 0, endInclusive: 99),
                index: try MediaByteRange(start: 100, endInclusive: 155)
            )
        )
    }
}
