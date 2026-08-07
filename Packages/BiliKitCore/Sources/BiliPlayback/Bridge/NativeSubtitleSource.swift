import BiliApplication
import BiliModels
import Foundation

enum NativeSubtitleSourceError: Error, Sendable, Equatable {
    case duplicateTrackID
    case emptyDisplayLabel
}

struct NativeSubtitleCatalogEntry: Sendable, Equatable {
    let trackID: String
    let label: String
}

/// 只属于一次 playback identity 的字幕来源；route 被停止后不再持有。
struct NativeSubtitleSource: Sendable {
    let useCase: SubtitleUseCase
    let identity: PlaybackItemIdentity

    func catalog() async throws -> [NativeSubtitleCatalogEntry] {
        let tracks = try await useCase.tracks(for: identity)
        let options = SubtitleDisplayPolicy.options(for: tracks)
        var trackIDs = Set<String>()
        return try options.map { option in
            guard trackIDs.insert(option.trackID).inserted else {
                throw NativeSubtitleSourceError.duplicateTrackID
            }
            guard !option.label.isEmpty else {
                throw NativeSubtitleSourceError.emptyDisplayLabel
            }
            return NativeSubtitleCatalogEntry(
                trackID: option.trackID,
                label: option.label
            )
        }
    }

    func cues(for trackID: String) async throws -> [SubtitleCue] {
        try await useCase.cues(for: trackID, identity: identity)
    }
}
