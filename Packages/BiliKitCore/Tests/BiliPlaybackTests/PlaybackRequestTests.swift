import Foundation
import Testing
@testable import BiliModels
@testable import BiliPlayback

struct PlaybackRequestTests {
    @Test
    func keepsPreferredRepresentationsSeparateFromManifest() throws {
        let segmentBase = SegmentBase(
            initialization: try MediaByteRange(start: 0, endInclusive: 99),
            index: try MediaByteRange(start: 100, endInclusive: 199)
        )
        let video = MediaRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            mimeType: "video/mp4",
            primaryURL: try #require(URL(string: "https://example.com/video")),
            segmentBase: segmentBase
        )
        let audio = MediaRepresentation(
            id: 30280,
            kind: .audio,
            codecs: "mp4a.40.2",
            mimeType: "audio/mp4",
            primaryURL: try #require(URL(string: "https://example.com/audio")),
            segmentBase: segmentBase
        )
        let manifest = PlaybackManifest(
            videoRepresentations: [video],
            audioRepresentations: [audio]
        )

        let request = PlaybackRequest(
            manifest: manifest,
            preferredVideoRepresentationID: video.id,
            preferredAudioRepresentationID: audio.id
        )

        #expect(request.manifest == manifest)
        #expect(request.preferredVideoRepresentationID == 80)
        #expect(request.preferredAudioRepresentationID == 30280)
        #expect(request.mediaHeaders.isEmpty)
    }
}
