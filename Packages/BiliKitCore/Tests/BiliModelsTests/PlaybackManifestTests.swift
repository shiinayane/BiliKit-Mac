import Foundation
import Testing
@testable import BiliModels

struct PlaybackManifestTests {
    @Test
    func byteRangeProducesHTTPHeaderValue() throws {
        let range = try MediaByteRange(start: 10, endInclusive: 19)

        #expect(range.httpRangeHeaderValue == "bytes=10-19")
    }

    @Test
    func byteRangeRejectsInvalidBounds() {
        #expect(throws: MediaByteRangeError.self) {
            try MediaByteRange(start: 20, endInclusive: 10)
        }
    }

    @Test
    func representationKeepsPrimaryURLFirst() throws {
        let segmentBase = SegmentBase(
            initialization: try MediaByteRange(start: 0, endInclusive: 99),
            index: try MediaByteRange(start: 100, endInclusive: 199)
        )
        let primaryURL = try #require(URL(string: "https://primary.example/video"))
        let backupURL = try #require(URL(string: "https://backup.example/video"))
        let representation = MediaRepresentation(
            id: 80,
            kind: .video,
            codecs: "avc1.640032",
            mimeType: "video/mp4",
            primaryURL: primaryURL,
            backupURLs: [backupURL],
            segmentBase: segmentBase
        )

        #expect(representation.urlCandidates == [primaryURL, backupURL])
    }
}
