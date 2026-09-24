import Foundation
import Testing

@testable import BiliModels
@testable import BiliPlayback

struct PlaybackRequestTests {
    @Test
    func selectsPreferredRepresentationWithinEachSemanticTrack() throws {
        let originalLow = try makeRepresentation(id: 30_216, kind: .audio)
        let originalHigh = try makeRepresentation(id: 30_280, kind: .audio)
        let alternate = try makeRepresentation(id: 40_080, kind: .audio)
        let originalTrack = makeAudioTrack(
            id: "original",
            isDefault: true,
            representations: [originalLow, originalHigh]
        )
        let alternateTrack = makeAudioTrack(
            id: "alternate",
            isDefault: false,
            representations: [alternate]
        )
        let request = PlaybackRequest(
            manifest: PlaybackManifest(
                videoRepresentations: [],
                audioTracks: [originalTrack, alternateTrack]
            ),
            preferredAudioRepresentationIDs: [
                originalTrack.id: originalHigh.id,
                alternateTrack.id: alternate.id
            ]
        )

        let selected = try selectAudio(request)

        #expect(selected.map(\.track.id) == ["original", "alternate"])
        #expect(selected.map(\.representation.id) == [30_280, 40_080])
    }

    @Test
    func rejectsInvalidSemanticAudioTrackContracts() throws {
        let audio = try makeRepresentation(id: 30_216, kind: .audio)
        let otherAudio = try makeRepresentation(id: 30_280, kind: .audio)
        let video = try makeRepresentation(id: 80, kind: .video)

        #expect(throws: AVPlayerEngineError.duplicateAudioTrackID("duplicate")) {
            try selectAudio(
                makeRequest(
                    tracks: [
                        makeAudioTrack(
                            id: "duplicate",
                            isDefault: true,
                            representations: [audio]
                        ),
                        makeAudioTrack(
                            id: "duplicate",
                            isDefault: false,
                            representations: [otherAudio]
                        )
                    ]
                )
            )
        }
        #expect(throws: AVPlayerEngineError.invalidDefaultAudioTrackCount(0)) {
            try selectAudio(
                makeRequest(
                    tracks: [
                        makeAudioTrack(
                            id: "original",
                            isDefault: false,
                            representations: [audio]
                        )
                    ]
                )
            )
        }
        #expect(throws: AVPlayerEngineError.invalidDefaultAudioTrackCount(2)) {
            try selectAudio(
                makeRequest(
                    tracks: [
                        makeAudioTrack(
                            id: "original",
                            isDefault: true,
                            representations: [audio]
                        ),
                        makeAudioTrack(
                            id: "alternate",
                            isDefault: true,
                            representations: [otherAudio]
                        )
                    ]
                )
            )
        }
        #expect(
            throws: AVPlayerEngineError.invalidAudioTrackRepresentation(
                trackID: "original",
                representationID: video.id
            )
        ) {
            try selectAudio(
                makeRequest(
                    tracks: [
                        makeAudioTrack(
                            id: "original",
                            isDefault: true,
                            representations: [video]
                        )
                    ]
                )
            )
        }
        #expect(
            throws: AVPlayerEngineError.preferredAudioTrackNotFound("missing")
        ) {
            try selectAudio(
                makeRequest(
                    tracks: [
                        makeAudioTrack(
                            id: "original",
                            isDefault: true,
                            representations: [audio]
                        )
                    ],
                    preferences: ["missing": audio.id]
                )
            )
        }
        #expect(
            throws: AVPlayerEngineError.missingAudioTrackRepresentation(
                "original"
            )
        ) {
            try selectAudio(
                makeRequest(
                    tracks: [
                        makeAudioTrack(
                            id: "original",
                            isDefault: true,
                            representations: []
                        )
                    ]
                )
            )
        }
        #expect(
            throws: AVPlayerEngineError.preferredAudioRepresentationNotFound(
                trackID: "original",
                representationID: otherAudio.id
            )
        ) {
            try selectAudio(
                makeRequest(
                    tracks: [
                        makeAudioTrack(
                            id: "original",
                            isDefault: true,
                            representations: [audio]
                        ),
                        makeAudioTrack(
                            id: "alternate",
                            isDefault: false,
                            representations: [otherAudio]
                        )
                    ],
                    preferences: ["original": otherAudio.id]
                )
            )
        }
    }

    private func selectAudio(
        _ request: PlaybackRequest
    ) throws -> [SelectedPlaybackAudioTrack] {
        try request.selectedAudioTracks(in: try #require(request.dashManifest))
    }

    private func makeRequest(
        tracks: [PlaybackAudioTrack],
        preferences: [String: Int] = [:]
    ) -> PlaybackRequest {
        PlaybackRequest(
            manifest: PlaybackManifest(
                videoRepresentations: [],
                audioTracks: tracks
            ),
            preferredAudioRepresentationIDs: preferences
        )
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
