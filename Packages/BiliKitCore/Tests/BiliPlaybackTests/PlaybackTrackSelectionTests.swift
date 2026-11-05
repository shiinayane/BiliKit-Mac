import Foundation
import Testing

@testable import BiliModels
@testable import BiliPlayback

/// 每条语义音轨交给播放的是码率最高的 representation，与 playurl 返回顺序无关；缺失码率时回落顺序确定。
///
/// 原声另带附加音频组的版本，无损只在“无损音频”打开时加入。
struct PlaybackTrackSelectionTests {
    @Test
    func selectsHighestBandwidthRepresentationWithinEachSemanticTrack() throws {
        let originalMiddle = try makeRepresentation(id: 30_232, kind: .audio, bandwidth: 132_000)
        let originalHigh = try makeRepresentation(id: 30_280, kind: .audio, bandwidth: 192_000)
        let originalLow = try makeRepresentation(id: 30_216, kind: .audio, bandwidth: 64_000)
        let alternateLow = try makeRepresentation(id: 30_216, kind: .audio, bandwidth: 64_000)
        let alternateHigh = try makeRepresentation(id: 30_280, kind: .audio, bandwidth: 160_000)
        let manifest = PlaybackManifest(
            videoRepresentations: [],
            audioTracks: [
                makeAudioTrack(
                    id: "original",
                    isDefault: true,
                    representations: [originalMiddle, originalHigh, originalLow]
                ),
                makeAudioTrack(
                    id: "alternate",
                    isDefault: false,
                    representations: [alternateLow, alternateHigh]
                )
            ]
        )

        let selected = try manifest.selectedAudioTracks(allowsLosslessAudio: false)

        #expect(selected.map(\.track.id) == ["original", "alternate"])
        #expect(selected.map(\.representation) == [originalHigh, alternateHigh])
    }

    @Test(arguments: [false, true])
    func originalOffersRemainingTiersThenDolbyAndLosslessOnlyWhenAllowed(
        allowsLosslessAudio: Bool
    ) throws {
        let middle = try makeRepresentation(id: 30_232, kind: .audio, bandwidth: 132_000)
        let high = try makeRepresentation(id: 30_280, kind: .audio, bandwidth: 192_000)
        let low = try makeRepresentation(id: 30_216, kind: .audio, bandwidth: 64_000)
        let dolby = try makeRepresentation(id: 30_250, kind: .audio, bandwidth: 1_000_000)
        let lossless = try makeRepresentation(id: 30_251, kind: .audio, bandwidth: 3_400_000)
        let manifest = PlaybackManifest(
            videoRepresentations: [],
            audioTracks: [
                .original(representations: [middle, high, low], dolby: dolby, lossless: lossless),
                PlaybackAudioTrack(
                    id: "machine-generated:en",
                    displayName: "English",
                    languageTag: "en",
                    role: .machineGenerated,
                    isDefault: false,
                    isAutoselect: false,
                    representations: [low, high]
                )
            ]
        )

        let selected = try manifest.selectedAudioTracks(allowsLosslessAudio: allowsLosslessAudio)

        #expect(selected.map(\.representation) == [high, high])
        #expect(
            selected[0].additionalRepresentations
                == [middle, low, dolby] + (allowsLosslessAudio ? [lossless] : [])
        )
        #expect(selected[1].additionalRepresentations.isEmpty)
    }

    @Test(
        arguments: [
            // 码率相同时保留先出现的一条。
            ([(30_232, 192_000), (30_280, 192_000)], 30_232),
            // 有码率的候选优先于缺失码率的，无论先后。
            ([(30_280, nil), (30_216, 64_000)], 30_216),
            ([(30_216, 64_000), (30_280, nil)], 30_216),
            // 全部缺失码率时取首条。
            ([(30_232, nil), (30_280, nil)], 30_232)
        ] as [([(Int, Int?)], Int)]
    )
    func fallsBackDeterministicallyWhenBandwidthTiesOrIsMissing(
        candidates: [(Int, Int?)],
        expectedID: Int
    ) throws {
        let representations = try candidates.map { id, bandwidth in
            try makeRepresentation(id: id, kind: .audio, bandwidth: bandwidth)
        }
        let manifest = PlaybackManifest(
            videoRepresentations: [],
            audioTracks: [
                makeAudioTrack(
                    id: "original",
                    isDefault: true,
                    representations: representations
                )
            ]
        )

        let selected = try manifest.selectedAudioTracks(allowsLosslessAudio: false)

        #expect(selected.map(\.representation.id) == [expectedID])
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
                .selectedAudioTracks(allowsLosslessAudio: false)
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
        kind: MediaKind,
        bandwidth: Int? = nil
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
            bandwidth: bandwidth,
            primaryURL: try #require(URL(string: "https://media.fixture.bilivideo.com/\(id)")),
            segmentBase: segmentBase
        )
    }
}
