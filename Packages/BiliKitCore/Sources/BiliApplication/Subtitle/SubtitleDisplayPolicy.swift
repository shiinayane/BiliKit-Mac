import BiliModels
import Foundation

public struct SubtitleDisplayOption: Sendable, Equatable, Identifiable {
    public let trackID: String
    public let label: String

    public var id: String { trackID }

    public init(trackID: String, label: String) {
        self.trackID = trackID
        self.label = label
    }
}

/// 将字幕来源标签归一化为用户可见标签，不改变轨道 identity 或语义。
public enum SubtitleDisplayPolicy {
    public static func options(
        for tracks: [SubtitleTrack]
    ) -> [SubtitleDisplayOption] {
        let labels = tracks.map {
            $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return zip(tracks, labels).map { pair in
            let (track, label) = pair
            return SubtitleDisplayOption(
                trackID: track.id,
                label: userLabel(for: track, sourceLabel: label)
            )
        }
    }

    private static func userLabel(
        for track: SubtitleTrack,
        sourceLabel: String
    ) -> String {
        switch (track.languageCode, track.kind, sourceLabel) {
        case ("ai-zh", .automatic, "中文"):
            return "中文（AI）"
        default:
            return sourceLabel
        }
    }
}
