import BiliPlayback
import CoreFoundation
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
        case .serverDefault: AppStrings.localized("B 站服务端默认")
        case .serverAkamai: AppStrings.localized("Akamai（服务端原始）")
        case .serverBilivideo: AppStrings.localized("bilivideo（服务端原始）")
        default: route?.appDisplayName ?? rawValue
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

extension PlaybackRouteTarget {
    var appDisplayName: String {
        switch self {
        case .serverAkamai: AppStrings.localized("Akamai（服务端原始）")
        case .bilivideo(let route): route.appDisplayName
        }
    }
}

extension BilivideoRoute {
    fileprivate var appDisplayName: String {
        switch self {
        case .tencentOverseas:
            "\(AppStrings.localized("腾讯海外")) COSOV"
        case .alibabaOverseas:
            "\(AppStrings.localized("阿里海外")) ALIOV"
        case .alibabaMainland:
            "\(AppStrings.localized("阿里")) ALI"
        case .alibabaMainlandB:
            "\(AppStrings.localized("阿里")) ALIB"
        case .alibabaMainlandO1:
            "\(AppStrings.localized("阿里")) ALIO1"
        case .tencentMainland:
            "\(AppStrings.localized("腾讯")) COS"
        case .tencentMainlandB:
            "\(AppStrings.localized("腾讯")) COSB"
        case .tencentMainlandO1:
            "\(AppStrings.localized("腾讯")) COSO1"
        case .huaweiMainland:
            "\(AppStrings.localized("华为")) HW"
        case .huaweiMainlandB:
            "\(AppStrings.localized("华为")) HWB"
        case .huaweiMainlandO1:
            "\(AppStrings.localized("华为")) HWO1"
        case .huawei08C:
            "\(AppStrings.localized("华为")) 08C"
        case .huawei08H:
            "\(AppStrings.localized("华为")) 08H"
        case .huawei08CT:
            "\(AppStrings.localized("华为")) 08CT"
        case .huaweiAll:
            AppStrings.localized("华为 TF 全域")
        case .tencentAll:
            AppStrings.localized("腾讯 TX 全域")
        case .baiduMainland:
            "\(AppStrings.localized("百度")) BOS"
        case .bda2Mainland:
            AppStrings.localized("UPCDN BDA2（大陆）")
        }
    }
}

struct PlaybackSourcePreferenceRecord: Sendable, Equatable {
    static let defaults = Self(selection: .serverDefault, loudnessNormalizationEnabled: false)
    let selection: PlaybackSourceSelection
    let loudnessNormalizationEnabled: Bool

    init(
        selection: PlaybackSourceSelection,
        loudnessNormalizationEnabled: Bool = false
    ) {
        self.selection = selection
        self.loudnessNormalizationEnabled = loudnessNormalizationEnabled
    }
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
        static let loudnessNormalizationEnabled = "playback.loudnessNormalization.enabled"
    }
    private static let schemaVersion = 1
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> PlaybackSourcePreferenceRecord {
        guard defaults.integer(forKey: Key.schema) == Self.schemaVersion,
            let raw = defaults.string(forKey: Key.selection),
            let selection = PlaybackSourceSelection(rawValue: raw)
        else { return .defaults }
        let storedEnabled = defaults.object(
            forKey: Key.loudnessNormalizationEnabled
        )
        let enabled =
            if let number = storedEnabled as? NSNumber,
                CFGetTypeID(number) == CFBooleanGetTypeID()
            {
                number.boolValue
            } else {
                false
            }
        return PlaybackSourcePreferenceRecord(
            selection: selection,
            loudnessNormalizationEnabled: enabled
        )
    }

    func save(_ record: PlaybackSourcePreferenceRecord) {
        defaults.set(Self.schemaVersion, forKey: Key.schema)
        defaults.set(record.selection.rawValue, forKey: Key.selection)
        defaults.set(
            record.loudnessNormalizationEnabled,
            forKey: Key.loudnessNormalizationEnabled
        )
    }
}
