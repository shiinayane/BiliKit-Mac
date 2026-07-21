import Foundation
import Security
import Testing
@testable import BiliAuth

struct WebCredentialTests {
    @Test
    func versionedEnvelopeRoundTripsWithoutPublicDiagnostics() throws {
        let credential = try makeFixtureCredential()

        let encoded = try WebCredentialCodec.encode(credential)
        let decoded = try WebCredentialCodec.decode(encoded)

        #expect(decoded == credential)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""version":1"#))
        let diagnostics = String(describing: credential)
            + String(reflecting: credential)
            + credential.cookies.map(String.init(reflecting:)).joined()
        #expect(!diagnostics.contains("FIXTURE_"))
        var dumped = ""
        dump(credential, to: &dumped)
        #expect(!dumped.contains("FIXTURE_"))
    }

    @Test
    func rejectsUnsupportedEnvelopeVersion() {
        let data = Data(#"{"cookies":[],"version":2}"#.utf8)

        #expect(throws: WebCredentialCodingError.unsupportedVersion(2)) {
            try WebCredentialCodec.decode(data)
        }
    }

    @Test
    func rejectsIncompleteOrUnsafeCookieSets() throws {
        let valid = try makeFixtureCredential().cookies

        #expect(throws: WebCredentialCodingError.invalidCredential) {
            try WebCredential(cookies: Array(valid.dropLast()))
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
        #expect(throws: WebCredentialCodingError.invalidCredential) {
            try WebCredential(cookies: insecure)
        }
    }

    @Test
    func dataProtectionKeychainUsesFixedProtectionAndAtomicUpdate() throws {
        let service = "com.shiinayane.BiliKitMac.tests.fixture"
        let account = "web-credential"
        let operations = RecordingKeychainOperations()
        let store = KeychainWebCredentialStore(
            service: service,
            account: account,
            operations: operations
        )
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
        #expect(attributes[kSecAttrService as String] as? String == service)
        #expect(attributes[kSecAttrAccount as String] as? String == account)
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
        let unavailableStore = KeychainWebCredentialStore(operations: unavailable)
        #expect(throws: WebCredentialStoreError.unavailable) {
            try unavailableStore.load()
        }

        let locked = RecordingKeychainOperations(nextReadStatus: errSecInteractionNotAllowed)
        let lockedStore = KeychainWebCredentialStore(operations: locked)
        #expect(throws: WebCredentialStoreError.interactionNotAllowed) {
            try lockedStore.load()
        }
    }
}

private final class RecordingKeychainOperations: KeychainOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var nextReadStatus: OSStatus?
    private(set) var lastAddAttributes: [String: Any]?
    private(set) var updateCount = 0
    private(set) var deleteCount = 0

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
            lastAddAttributes = attributes
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
            updateCount += 1
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            deleteCount += 1
            guard data != nil else { return errSecItemNotFound }
            data = nil
            return errSecSuccess
        }
    }
}
