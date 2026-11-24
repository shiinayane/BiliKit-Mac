import BiliAPI
import Foundation

/// 设备标识（`buvid3`、`buvid4`、`b_nut`）的偏好存储，`BiliDeviceIdentity` 的唯一持久化。
///
/// 只拥有这三项与 schema 版本，不保存账户信息；版本不符、缺项或校验失败的值读出时删除并返回 nil，由调用方
/// 重新取得。保留期由 `DeviceIdentity` 判断，登出与凭据失效时由 `BiliDeviceIdentity` 调用 `clear`。规则见
/// SECURITY-MODEL §6。`UserDefaults` 自身线程安全，本类型没有其他可变状态。
final class UserDefaultsDeviceIdentityStore: DeviceIdentityStoring, @unchecked Sendable {
    private enum Key {
        static let schema = "deviceIdentity.schema"
        static let buvid3 = "deviceIdentity.buvid3"
        static let buvid4 = "deviceIdentity.buvid4"
        static let issuedAt = "deviceIdentity.issuedAt"
        static let all = [schema, buvid3, buvid4, issuedAt]
    }
    private static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> DeviceIdentity? {
        guard defaults.integer(forKey: Key.schema) == Self.schemaVersion,
            let buvid3 = defaults.string(forKey: Key.buvid3),
            let issuedAt = defaults.object(forKey: Key.issuedAt) as? Int64,
            let identity = DeviceIdentity(
                buvid3: buvid3,
                buvid4: defaults.string(forKey: Key.buvid4),
                issuedAt: issuedAt
            )
        else {
            clear()
            return nil
        }
        return identity
    }

    func save(_ identity: DeviceIdentity) {
        defaults.set(Self.schemaVersion, forKey: Key.schema)
        defaults.set(identity.buvid3, forKey: Key.buvid3)
        defaults.set(identity.buvid4, forKey: Key.buvid4)
        defaults.set(identity.issuedAt, forKey: Key.issuedAt)
    }

    func clear() {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
    }
}
