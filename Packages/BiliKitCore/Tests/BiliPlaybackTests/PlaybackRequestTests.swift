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
            originalAudioRepresentations: [audio]
        )

        let request = PlaybackRequest(
            manifest: manifest,
            preferredVideoRepresentationID: video.id,
            preferredAudioRepresentationIDs: ["original": audio.id]
        )

        #expect(request.manifest == manifest)
        #expect(request.preferredVideoRepresentationID == 80)
        #expect(request.preferredAudioRepresentationIDs == ["original": 30280])
        #expect(request.mediaHeaders.isEmpty)
    }

    @Test
    @MainActor
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
                alternateTrack.id: alternate.id,
            ]
        )

        let selected = try AVPlayerEngine().selectedAudioTracks(for: request)

        #expect(selected.map(\.track.id) == ["original", "alternate"])
        #expect(selected.map(\.representation.id) == [30_280, 40_080])
    }

    @Test
    @MainActor
    func rejectsInvalidSemanticAudioTrackContracts() throws {
        let audio = try makeRepresentation(id: 30_216, kind: .audio)
        let otherAudio = try makeRepresentation(id: 30_280, kind: .audio)
        let video = try makeRepresentation(id: 80, kind: .video)
        let engine = AVPlayerEngine()

        #expect(throws: AVPlayerEngineError.duplicateAudioTrackID("duplicate")) {
            try engine.selectedAudioTracks(
                for: makeRequest(
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
                        ),
                    ]
                )
            )
        }
        #expect(throws: AVPlayerEngineError.invalidDefaultAudioTrackCount(0)) {
            try engine.selectedAudioTracks(
                for: makeRequest(
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
            try engine.selectedAudioTracks(
                for: makeRequest(
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
                        ),
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
            try engine.selectedAudioTracks(
                for: makeRequest(
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
            try engine.selectedAudioTracks(
                for: makeRequest(
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
            try engine.selectedAudioTracks(
                for: makeRequest(
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
            try engine.selectedAudioTracks(
                for: makeRequest(
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
                        ),
                    ],
                    preferences: ["original": otherAudio.id]
                )
            )
        }
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
            primaryURL: try #require(URL(string: "https://example.com/\(id)")),
            segmentBase: segmentBase
        )
    }
}
