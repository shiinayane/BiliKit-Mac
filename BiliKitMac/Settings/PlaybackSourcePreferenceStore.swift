import BiliPlayback
import Foundation

/// 设置里可选的新播放优先线路；`rawValue` 就是持久化的版本化 route identifier
/// （见 SECURITY-MODEL §6）。
///
/// 服务端默认、服务端原始 Akamai 与 bilivideo 之外的 case 与 `BilivideoRoute` 同名，是实验镜像。
/// 改名或删除 case 会让已存的值读成未知值，回退服务端默认。
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
        case .serverAkamai: PlaybackRouteTarget.serverAkamai.appDisplayName
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

/// 一次读写的播放偏好整体：线路选择、“HDR 视频”与“无损音频”开关；`defaults` 是没有存过或读到损坏值
/// 时的回退。
struct PlaybackSourcePreferenceRecord: Sendable, Equatable {
    static let defaults = Self(
        selection: .serverDefault,
        hdrVideoEnabled: true,
        losslessAudioEnabled: false
    )
    var selection: PlaybackSourceSelection
    /// 默认开：只有窗口所在屏幕能显示 HDR 等条件都满足时才会真的加入 HDR 档（见 `PlaybackHDREnvironment`）。
    var hdrVideoEnabled: Bool
    /// 默认关：无损音频约 3.4 Mbps、AVPlayer 选中后会大量预取，只给明确想要的人。
    var losslessAudioEnabled: Bool
}

/// 播放偏好的持久化 port：`load` 不抛错，读不到或值损坏时返回
/// `PlaybackSourcePreferenceRecord.defaults`，`save` 整体覆盖。
///
/// `AppSettingsModel` 构造时读取一次，改选线路或切换开关时各写入一次。
protocol PlaybackSourcePreferenceStoring: AnyObject, Sendable {
    func load() -> PlaybackSourcePreferenceRecord
    func save(_ record: PlaybackSourcePreferenceRecord)
}

/// 播放偏好的 UserDefaults 实现：schema 版本、线路选择、HDR 与无损音频开关四个键（见 SECURITY-MODEL §6）。
///
/// 都只接受类型严格匹配的值：schema 不符或类型错写、线路选择不是字符串或是未知值时，线路回退默认；
/// 两个开关各自独立读取，缺失或不是布尔值时取 `PlaybackSourcePreferenceRecord.defaults`（HDR 开、无损关）。
/// 每次读取都删除已移除功能留下的响度开关键（`retiredKeys`），不读取它们的值。
///
/// `@unchecked Sendable`：只持有不可变的 `let defaults`，`UserDefaults` 本身可以跨线程读写；
/// 几个键不是原子写入，生产调用方只有 MainActor 上的 `AppSettingsModel`。
final class UserDefaultsPlaybackSourcePreferenceStore:
    PlaybackSourcePreferenceStoring, @unchecked Sendable
{
    private enum Key {
        static let schema = "playbackSourcePreference.schema"
        static let selection = "playbackSourcePreference.selection"
        static let hdrVideoEnabled = "playback.hdrVideo.enabled"
        static let losslessAudioEnabled = "playback.losslessAudio.enabled"
        /// 已移除的响度均一化留下的开关：先后两版（可放大的实验开关、只压低的开关），读取时清掉残留。
        static let retiredKeys = [
            "playback.loudnessNormalization.enabled",
            "playback.loudnessAttenuation.enabled"
        ]
    }
    private static let schemaVersion = 1
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> PlaybackSourcePreferenceRecord {
        for key in Key.retiredKeys {
            defaults.removeObject(forKey: key)
        }
        let fallback = PlaybackSourcePreferenceRecord.defaults
        // 不用 `integer(forKey:)`／`string(forKey:)`：它们会把字符串 "1"、`true`、`1.9` 读成 schema 1，
        // 把数字转成字符串，类型错写的值就不再回退默认（见 SECURITY-MODEL §6）。
        var selection = fallback.selection
        if defaults.strictInteger(forKey: Key.schema) == Self.schemaVersion,
            let raw = defaults.object(forKey: Key.selection) as? String,
            let stored = PlaybackSourceSelection(rawValue: raw)
        {
            selection = stored
        }
        return PlaybackSourcePreferenceRecord(
            selection: selection,
            hdrVideoEnabled: defaults.strictBool(forKey: Key.hdrVideoEnabled)
                ?? fallback.hdrVideoEnabled,
            losslessAudioEnabled: defaults.strictBool(forKey: Key.losslessAudioEnabled)
                ?? fallback.losslessAudioEnabled
        )
    }

    func save(_ record: PlaybackSourcePreferenceRecord) {
        defaults.set(Self.schemaVersion, forKey: Key.schema)
        defaults.set(record.selection.rawValue, forKey: Key.selection)
        defaults.set(record.hdrVideoEnabled, forKey: Key.hdrVideoEnabled)
        defaults.set(record.losslessAudioEnabled, forKey: Key.losslessAudioEnabled)
    }
}
