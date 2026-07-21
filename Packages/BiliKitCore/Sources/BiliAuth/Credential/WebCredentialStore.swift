import Foundation
import Security

protocol WebCredentialStoring: Sendable {
    func load() throws -> WebCredential?
    func save(_ credential: WebCredential) throws
    func delete() throws
}

enum WebCredentialStoreError: Error, Sendable, Equatable {
    case corruptCredential
    case interactionNotAllowed
    case unavailable
    case operationFailed(OSStatus)
}

struct KeychainWebCredentialStore: WebCredentialStoring, Sendable {
    static let productionService = "com.shiinayane.BiliKitMac.web-auth"
    static let productionAccount = "web-credential"

    private let service: String
    private let account: String
    private let operations: any KeychainOperating

    init(
        service: String = Self.productionService,
        account: String = Self.productionAccount,
        operations: any KeychainOperating = SystemKeychainOperations()
    ) {
        self.service = service
        self.account = account
        self.operations = operations
    }

    func load() throws -> WebCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, data) = operations.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        try Self.requireSuccess(status)
        guard let data else {
            throw WebCredentialStoreError.corruptCredential
        }
        do {
            return try WebCredentialCodec.decode(data)
        } catch {
            throw WebCredentialStoreError.corruptCredential
        }
    }

    func save(_ credential: WebCredential) throws {
        let encoded: Data
        do {
            encoded = try WebCredentialCodec.encode(credential)
        } catch {
            throw WebCredentialStoreError.corruptCredential
        }

        var attributes = baseQuery
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrLabel as String] = "BiliKit Web 登录凭据"
        attributes[kSecValueData as String] = encoded

        let addStatus = operations.add(attributes)
        guard addStatus == errSecDuplicateItem else {
            try Self.requireSuccess(addStatus)
            return
        }

        let update: [String: Any] = [
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "BiliKit Web 登录凭据",
            kSecValueData as String: encoded,
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
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func requireSuccess(_ status: OSStatus) throws {
        guard status != errSecInteractionNotAllowed else {
            throw WebCredentialStoreError.interactionNotAllowed
        }
        guard status != errSecMissingEntitlement,
              status != errSecNotAvailable
        else {
            throw WebCredentialStoreError.unavailable
        }
        guard status == errSecSuccess else {
            throw WebCredentialStoreError.operationFailed(status)
        }
    }
}

protocol KeychainOperating: Sendable {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(
        query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

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
