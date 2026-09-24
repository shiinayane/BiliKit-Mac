import Foundation
import Testing

@testable import BiliModels
@testable import BiliPlayback

struct PlaybackTrackSelectionTests {
    @Test
    func selectsFirstRepresentationWithinEachSemanticTrack() throws {
        let originalLow = try makeRepresentation(id: 30_216, kind: .audio)
        let originalHigh = try makeRepresentation(id: 30_280, kind: .audio)
        let alternate = try makeRepresentation(id: 40_080, kind: .audio)
        let manifest = PlaybackManifest(
            videoRepresentations: [],
            audioTracks: [
                makeAudioTrack(
                    id: "original",
                    isDefault: true,
                    representations: [originalLow, originalHigh]
                ),
                makeAudioTrack(
                    id: "alternate",
                    isDefault: false,
                    representations: [alternate]
                )
            ]
        )

        let selected = try manifest.selectedAudioTracks()

        #expect(selected.map(\.track.id) == ["original", "alternate"])
        #expect(selected.map(\.representation.id) == [30_216, 40_080])
    }

    enum InvalidAudioContract: CaseIterable, Sendable {
        case duplicateTrackID
        case noDefaultTrack
        case twoDefaultTracks
        case nonAudioRepresentation
        case trackWithoutRepresentation
    }

    @Test(arguments: InvalidAudioContract.allCases)
    func rejectsInvalidSemanticAudioTrackContracts(
        _ contract: InvalidAudioContract
    ) throws {
        let audio = try makeRepresentation(id: 30_216, kind: .audio)
        let otherAudio = try makeRepresentation(id: 30_280, kind: .audio)
        let video = try makeRepresentation(id: 80, kind: .video)
        let tracks: [PlaybackAudioTrack]
        let expectedError: AVPlayerEngineError
        switch contract {
        case .duplicateTrackID:
            tracks = [
                makeAudioTrack(id: "duplicate", isDefault: true, representations: [audio]),
                makeAudioTrack(id: "duplicate", isDefault: false, representations: [otherAudio])
            ]
            expectedError = .duplicateAudioTrackID("duplicate")
        case .noDefaultTrack:
            tracks = [
                makeAudioTrack(id: "original", isDefault: false, representations: [audio])
            ]
            expectedError = .invalidDefaultAudioTrackCount(0)
        case .twoDefaultTracks:
            tracks = [
                makeAudioTrack(id: "original", isDefault: true, representations: [audio]),
                makeAudioTrack(id: "alternate", isDefault: true, representations: [otherAudio])
            ]
            expectedError = .invalidDefaultAudioTrackCount(2)
        case .nonAudioRepresentation:
            tracks = [
                makeAudioTrack(id: "original", isDefault: true, representations: [video])
            ]
            expectedError = .invalidAudioTrackRepresentation(
                trackID: "original",
                representationID: video.id
            )
        case .trackWithoutRepresentation:
            tracks = [
                makeAudioTrack(id: "original", isDefault: true, representations: [])
            ]
            expectedError = .missingAudioTrackRepresentation("original")
        }

        #expect(throws: expectedError) {
            try PlaybackManifest(videoRepresentations: [], audioTracks: tracks)
                .selectedAudioTracks()
        }
    }

    private func makeAudioTrack(
        id: String,
        isDefault: Bool,
        representations: [MediaRepresentation]
    ) -> PlaybackAudioTrack {
        PlaybackAudioTrack(
            id: id,
            displayName: id,
            role: .original,
            isDefault: isDefault,
            isAutoselect: true,
            representations: representations
        )
    }

    private func makeRepresentation(
        id: Int,
        kind: MediaKind
    ) throws -> MediaRepresentation {
        let segmentBase = SegmentBase(
            initialization: try MediaByteRange(start: 0, endInclusive: 99),
            index: try MediaByteRange(start: 100, endInclusive: 199)
        )
        return MediaRepresentation(
            id: id,
            kind: kind,
            codecs: kind == .audio ? "mp4a.40.2" : "avc1.640032",
            mimeType: kind == .audio ? "audio/mp4" : "video/mp4",
            primaryURL: try #require(URL(string: "https://media.fixture.bilivideo.com/\(id)")),
            segmentBase: segmentBase
        )
    }
}
