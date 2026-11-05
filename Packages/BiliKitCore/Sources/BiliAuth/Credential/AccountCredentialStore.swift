import Foundation
import Security

/// 登录凭据持久化 port：读取、原子保存与删除同一个 Keychain item。
///
/// 由扫码会话（验证成功后保存）、续期（比对后覆盖）、认证服务（登出与复核确认失效时删除）与各授权器（按需读取，损坏或
/// 过期时删除）使用；没有凭据时 `load` 返回 nil，读到无法解码的内容抛 `AccountCredentialStoreError.corruptCredential`。
protocol AccountCredentialStoring: Sendable {
    func load() throws -> AccountCredential?
    func save(_ credential: AccountCredential) throws
    func delete() throws
}

/// Keychain 操作的失败分类。
///
/// 授权器只把 `corruptCredential` 当作可清除的坏凭据；其余按存储不可用处理（账户读取授权器在窗口
/// 已确认未登录时按无凭据处理，见 SECURITY-MODEL §2）。
enum AccountCredentialStoreError: Error, Sendable, Equatable {
    case corruptCredential
    case interactionNotAllowed
    case unavailable
    case operationFailed(OSStatus)
}

/// 登录凭据的唯一持久化 adapter，使用不可同步、仅本机解锁时可读的 Data Protection Keychain。
///
/// `operations` 是 Security.framework 的系统边界，默认为 `SystemKeychainOperations`。
struct KeychainAccountCredentialStore: AccountCredentialStoring, Sendable {
    /// 固定的 item 名称，不含 UID（见 SECURITY-MODEL §1）；改动等于换一个 item，旧登录态不迁移。
    static let service = "com.shiinayane.BiliKitMac.web-auth"
    static let account = "web-credential"

    private let operations: any KeychainOperating

    init(operations: any KeychainOperating = SystemKeychainOperations()) {
        self.operations = operations
    }

    func load() throws -> AccountCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, data) = operations.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        try Self.requireSuccess(status)
        guard let data else {
            throw AccountCredentialStoreError.corruptCredential
        }
        do {
            return try AccountCredentialCodec.decode(data)
        } catch {
            throw AccountCredentialStoreError.corruptCredential
        }
    }

    /// 新增或原子替换固定 service/account 下的单个版本化 credential item。
    func save(_ credential: AccountCredential) throws {
        let encoded: Data
        do {
            encoded = try AccountCredentialCodec.encode(credential)
        } catch {
            throw AccountCredentialStoreError.corruptCredential
        }

        var attributes = baseQuery
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrLabel as String] = "BiliKit 登录凭据"
        attributes[kSecValueData as String] = encoded

        let addStatus = operations.add(attributes)
        guard addStatus == errSecDuplicateItem else {
            try Self.requireSuccess(addStatus)
            return
        }

        let update: [String: Any] = [
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "BiliKit 登录凭据",
            kSecValueData as String: encoded
        ]
        try Self.requireSuccess(
            operations.update(query: baseQuery, attributes: update)
        )
    }

    func delete() throws {
        let status = operations.delete(baseQuery)
        if status == errSecItemNotFound { return }
        try Self.requireSuccess(status)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private static func requireSuccess(_ status: OSStatus) throws {
        guard status != errSecInteractionNotAllowed else {
            throw AccountCredentialStoreError.interactionNotAllowed
        }
        guard status != errSecMissingEntitlement,
            status != errSecNotAvailable
        else {
            throw AccountCredentialStoreError.unavailable
        }
        guard status == errSecSuccess else {
            throw AccountCredentialStoreError.operationFailed(status)
        }
    }
}

/// Security.framework `SecItem*` 调用的薄封装；store 只经它访问 Keychain。
protocol KeychainOperating: Sendable {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(
        query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/// `KeychainOperating` 的系统实现，逐个转发到 `SecItemCopyMatching`／`Add`／`Update`／`Delete`。
struct SystemKeychainOperations: KeychainOperating, Sendable {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(
        query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}
