import BiliAPI
import Foundation
import Testing

@testable import BiliKit

/// 设备标识跨启动保存同一组值，清除时删掉全部键，版本不符或值不合格的存储在读取时删除（SECURITY-MODEL §6）。
struct DeviceIdentityStoreTests {
    @Test
    func savedIdentitySurvivesANewStoreInstanceAndClearRemovesIt() throws {
        try withIsolatedDefaults { defaults in
            let identity = try #require(
                DeviceIdentity(
                    buvid3: "FIXTURE-3infoc",
                    buvid4: "FIXTURE-4",
                    issuedAt: 1_700_000_000
                )
            )
            UserDefaultsDeviceIdentityStore(defaults: defaults).save(identity)

            #expect(UserDefaultsDeviceIdentityStore(defaults: defaults).load() == identity)

            UserDefaultsDeviceIdentityStore(defaults: defaults).clear()
            #expect(UserDefaultsDeviceIdentityStore(defaults: defaults).load() == nil)
            #expect(
                defaults.dictionaryRepresentation().keys.contains {
                    $0.hasPrefix("deviceIdentity.")
                }
                    == false
            )
        }
    }

    @Test(
        arguments: [
            // 版本不符。
            [
                "deviceIdentity.schema": 2,
                "deviceIdentity.buvid3": "FIXTURE-3infoc",
                "deviceIdentity.issuedAt": 1
            ],
            // 值不是 Cookie 安全的 token。
            [
                "deviceIdentity.schema": 1,
                "deviceIdentity.buvid3": "A;evil=1",
                "deviceIdentity.issuedAt": 1
            ],
            // 缺 buvid3。
            ["deviceIdentity.schema": 1, "deviceIdentity.issuedAt": 1],
            // 缺版本键，只剩残留的值。
            ["deviceIdentity.buvid3": "FIXTURE-3infoc", "deviceIdentity.issuedAt": 1]
        ] as [[String: any Sendable]]
    )
    func unreadableStoredIdentityIsDeletedOnLoad(stored: [String: any Sendable]) {
        withIsolatedDefaults { defaults in
            for (key, value) in stored {
                defaults.set(value, forKey: key)
            }

            #expect(UserDefaultsDeviceIdentityStore(defaults: defaults).load() == nil)
            #expect(
                defaults.dictionaryRepresentation().keys.contains {
                    $0.hasPrefix("deviceIdentity.")
                }
                    == false
            )
        }
    }
}
