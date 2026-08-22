import BiliPlayback
import Foundation

enum PlaybackSourceSelection: String, Sendable, Equatable, CaseIterable, Identifiable {
    case serverDefault, serverAkamai, serverBilivideo
    case tencentOverseas, alibabaOverseas
    case alibabaMainland, alibabaMainlandB, alibabaMainlandO1
    case tencentMainland, tencentMainlandB, tencentMainlandO1
    case huaweiMainland, huaweiMainlandB, huaweiMainlandO1
    case huawei08C, huawei08H, huawei08CT, huaweiAll, tencentAll
    case baiduMainland, bda2Mainland

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .serverDefault: "B 站服务端默认"
        case .serverAkamai: "Akamai（服务端原始）"
        case .serverBilivideo: "bilivideo（服务端原始）"
        default: route?.displayName ?? rawValue
        }
    }

    var isExperimental: Bool { route != nil }

    var preference: PlaybackSourcePreference {
        switch self {
        case .serverDefault: .serverDefault
        case .serverAkamai: .category(.akamai)
        case .serverBilivideo: .category(.bilivideo)
        default:
            route.map(PlaybackSourcePreference.experimentalBilivideoRoute)
                ?? .serverDefault
        }
    }

    private var route: BilivideoRoute? {
        BilivideoRoute(rawValue: rawValue)
    }
}

struct PlaybackSourcePreferenceRecord: Sendable, Equatable {
    static let defaults = Self(selection: .serverDefault)
    let selection: PlaybackSourceSelection
}

protocol PlaybackSourcePreferenceStoring: AnyObject, Sendable {
    func load() -> PlaybackSourcePreferenceRecord
    func save(_ record: PlaybackSourcePreferenceRecord)
}

final class UserDefaultsPlaybackSourcePreferenceStore:
    PlaybackSourcePreferenceStoring, @unchecked Sendable
{
    private enum Key {
        static let schema = "playbackSourcePreference.schema"
        static let selection = "playbackSourcePreference.selection"
    }
    private static let schemaVersion = 1
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> PlaybackSourcePreferenceRecord {
        guard defaults.integer(forKey: Key.schema) == Self.schemaVersion,
            let raw = defaults.string(forKey: Key.selection),
            let selection = PlaybackSourceSelection(rawValue: raw)
        else { return .defaults }
        return PlaybackSourcePreferenceRecord(selection: selection)
    }

    func save(_ record: PlaybackSourcePreferenceRecord) {
        defaults.set(Self.schemaVersion, forKey: Key.schema)
        defaults.set(record.selection.rawValue, forKey: Key.selection)
    }
}
