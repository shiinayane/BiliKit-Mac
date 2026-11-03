import Foundation
import Testing

@testable import BiliModels

/// 播放清单的模型拒绝非法字节区间与视频属性，原声工厂把多个码率合成一条默认语义音轨。
struct PlaybackManifestTests {
    @Test
    func byteRangeRejectsInvalidBounds() {
        #expect(throws: MediaByteRangeError.self) {
            try MediaByteRange(start: 20, endInclusive: 10)
        }
    }

    @Test
    func groupsOriginalAudioRepresentationsIntoOneSemanticTrack() throws {
        let segmentBase = SegmentBase(
            initialization: try MediaByteRange(start: 0, endInclusive: 99),
            index: try MediaByteRange(start: 100, endInclusive: 199)
        )
        let low = MediaRepresentation(
            id: 30_216,
            kind: .audio,
            codecs: "mp4a.40.2",
            mimeType: "audio/mp4",
            bandwidth: 64_000,
            primaryURL: try #require(URL(string: "https://example.invalid/low")),
            segmentBase: segmentBase
        )
        let high = MediaRepresentation(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            mimeType: "audio/mp4",
            bandwidth: 192_000,
            primaryURL: try #require(URL(string: "https://example.invalid/high")),
            segmentBase: segmentBase
        )

        let manifest = PlaybackManifest(
            videoRepresentations: [],
            audioTracks: [.original(representations: [low, high], loudnessMetadata: nil)]
        )

        let track = try #require(manifest.audioTracks.first)
        #expect(manifest.audioTracks.count == 1)
        #expect(track.id == "original")
        #expect(track.displayName == "原声")
        #expect(track.languageTag == nil)
        #expect(track.role == .original)
        #expect(track.isDefault)
        #expect(track.isAutoselect)
        #expect(track.representations == [low, high])
    }

    @Test
    func videoAttributesRejectInvalidPresentationValues() {
        #expect(throws: VideoRepresentationAttributesError.self) {
            try VideoRepresentationAttributes(
                width: 1_920,
                height: 1_080,
                frameRate: .nan
            )
        }
        #expect(throws: VideoRepresentationAttributesError.self) {
            try VideoRepresentationAttributes(
                width: 0,
                height: 1_080,
                frameRate: 60
            )
        }
    }
}
