import Foundation
import Security
import Testing

@testable import BiliAuth

/// 凭据以带版本的信封编解码，诊断输出不含 Cookie 值，Cookie 不全或不安全时拒绝。
///
/// Keychain 条目放在数据保护钥匙串、仅本机解锁时可用且不同步，覆盖写入走原子更新；
/// 读取错误映射为不可用或不允许交互。
struct AccountCredentialTests {
    @Test
    func versionedEnvelopeRoundTripsWithoutPublicDiagnostics() throws {
        let credential = try makeFixtureCredential()

        let encoded = try AccountCredentialCodec.encode(credential)
        let decoded = try AccountCredentialCodec.decode(encoded)

        #expect(decoded == credential)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""version":2"#))
        let diagnostics =
            String(describing: credential)
            + String(reflecting: credential)
            + credential.cookies.map(String.init(reflecting:)).joined()
            + String(reflecting: credential.appAccessToken)
        #expect(!diagnostics.contains("FIXTURE_"))
        #expect(!diagnostics.contains(fixtureAppAccessTokenValue))
        var dumped = ""
        dump(credential, to: &dumped)
        #expect(!dumped.contains("FIXTURE_"))
        #expect(!dumped.contains(fixtureAppAccessTokenValue))
    }

    /// 只有 Cookie 的版本 1 凭据不再被接受：store 把它当损坏凭据删除，用户重新登录一次。
    @Test
    func rejectsCookieOnlyVersionOneEnvelope() {
        let data = Data(#"{"cookies":[],"version":1}"#.utf8)

        #expect(throws: AccountCredentialCodingError.unsupportedVersion(1)) {
            try AccountCredentialCodec.decode(data)
        }
    }

    /// Cookie 与 token 一起过期：任一到期，整份凭据都按过期处理（授权器随后删除它）。
    @Test
    func expiredAccessTokenExpiresWholeCredential() throws {
        let cookies = try makeFixtureCredential().cookies
        let credential = try AccountCredential(
            cookies: cookies,
            appAccessToken: AppAccessToken(
                value: fixtureAppAccessTokenValue,
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        #expect(credential.isExpired(at: Date(timeIntervalSince1970: 1_700_000_001)))
        #expect(!credential.isExpired(at: Date(timeIntervalSince1970: 1_699_999_999)))
    }

    @Test
    func rejectsIncompleteOrUnsafeCookieSets() throws {
        let valid = try makeFixtureCredential().cookies

        let token = try makeFixtureCredential().appAccessToken
        #expect(throws: AccountCredentialCodingError.invalidCredential) {
            try AccountCredential(cookies: Array(valid.dropLast()), appAccessToken: token)
        }
        #expect(throws: AccountCredentialCodingError.invalidCredential) {
            try AccountCredential(
                cookies: valid,
                appAccessToken: AppAccessToken(value: "FIXTURE", expiresAt: token.expiresAt)
            )
        }

        var insecure = valid
        let original = try #require(insecure.first)
        insecure[0] = WebCredentialCookie(
            name: original.name,
            value: original.value,
            domain: original.domain,
            path: original.path,
            isSecure: false,
            isHTTPOnly: original.isHTTPOnly,
            expiresAt: original.expiresAt
        )
        #expect(throws: AccountCredentialCodingError.invalidCredential) {
            try AccountCredential(cookies: insecure, appAccessToken: token)
        }
    }

    @Test
    func dataProtectionKeychainUsesFixedProtectionAndAtomicUpdate() throws {
        let operations = RecordingKeychainOperations()
        let store = KeychainAccountCredentialStore(operations: operations)
        let first = try makeFixtureCredential()
        let second = try makeFixtureCredential(
            expiresAt: Date(timeIntervalSince1970: 4_133_980_800)
        )

        #expect(try store.load() == nil)
        try store.save(first)
        #expect(try store.load() == first)
        try store.save(second)
        #expect(try store.load() == second)

        let attributes = try #require(operations.lastAddAttributes)
        #expect(attributes[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(
            attributes[kSecAttrService as String] as? String == "com.shiinayane.BiliKitMac.web-auth"
        )
        #expect(attributes[kSecAttrAccount as String] as? String == "web-credential")
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool != true)
        #expect(operations.updateCount == 1)

        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()
        #expect(operations.deleteCount == 2)
    }

    @Test
    func keychainErrorsAreMappedWithoutExposingStoredData() throws {
        let unavailable = RecordingKeychainOperations(nextReadStatus: errSecMissingEntitlement)
        let unavailableStore = KeychainAccountCredentialStore(operations: unavailable)
        #expect(throws: AccountCredentialStoreError.unavailable) {
            try unavailableStore.load()
        }

        let locked = RecordingKeychainOperations(nextReadStatus: errSecInteractionNotAllowed)
        let lockedStore = KeychainAccountCredentialStore(operations: locked)
        #expect(throws: AccountCredentialStoreError.interactionNotAllowed) {
            try lockedStore.load()
        }
    }
}

/// 记录 Keychain 调用的内存替身；`nextReadStatus` 只让下一次读取返回该状态。
///
/// `@unchecked Sendable` 由 `lock` 保证：所有状态（含计数）只在锁内读写。不用 `Mutex`：`add` 要把
/// 调用方传入的非 Sendable `[String: Any]` 存进状态，`Mutex` 的 region 检查不允许。
private final class RecordingKeychainOperations: KeychainOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var nextReadStatus: OSStatus?
    private var addedAttributes: [String: Any]?
    private var updates = 0
    private var deletes = 0

    var lastAddAttributes: [String: Any]? { lock.withLock { addedAttributes } }
    var updateCount: Int { lock.withLock { updates } }
    var deleteCount: Int { lock.withLock { deletes } }

    init(nextReadStatus: OSStatus? = nil) {
        self.nextReadStatus = nextReadStatus
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.withLock {
            if let nextReadStatus {
                self.nextReadStatus = nil
                return (nextReadStatus, nil)
            }
            guard let data else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            guard data == nil else { return errSecDuplicateItem }
            addedAttributes = attributes
            data = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func update(
        query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        lock.withLock {
            guard data != nil else { return errSecItemNotFound }
            data = attributes[kSecValueData as String] as? Data
            updates += 1
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            deletes += 1
            guard data != nil else { return errSecItemNotFound }
            data = nil
            return errSecSuccess
        }
    }
}
