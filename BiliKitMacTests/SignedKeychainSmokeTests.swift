import Foundation
import Security
import XCTest
@testable import BiliAuth

final class SignedKeychainSmokeTests: XCTestCase {
    private static let service =
        "com.shiinayane.BiliKitMac.tests.signed-keychain-smoke.v1"
    private static let account = "web-credential"

    func testDataProtectionKeychainAddUpdateReadDelete() async throws {
        let teamIdentifier = await Self.signingTeamIdentifierOffMain()
        try XCTSkipUnless(
            teamIdentifier != nil,
            "未签名或临时签名测试宿主不提供真实 Data Protection Keychain 证据"
        )

        try await Self.performSmokeOffMain()
    }

    private static func signingTeamIdentifierOffMain() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: signingTeamIdentifier())
            }
        }
    }

    private static func performSmokeOffMain() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try performSmoke()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func performSmoke() throws {
        guard service != KeychainWebCredentialStore.productionService else {
            throw SmokeFailure.productionNamespace
        }

        let store = KeychainWebCredentialStore(
            service: service,
            account: account
        )
        try store.delete()
        defer { try? store.delete() }

        guard try store.load() == nil else {
            throw SmokeFailure.initialItemPresent
        }

        let first = try makeCredential(marker: "FIRST", expiresAt: 4_102_444_800)
        try store.save(first)
        guard try store.load() == first else {
            throw SmokeFailure.firstReadMismatch
        }
        try assertStoredAttributes()

        let second = try makeCredential(marker: "SECOND", expiresAt: 4_133_980_800)
        try store.save(second)
        guard try store.load() == second else {
            throw SmokeFailure.secondReadMismatch
        }
        try assertStoredAttributes()

        try store.delete()
        guard try store.load() == nil else {
            throw SmokeFailure.finalItemRemains
        }
    }

    private static func makeCredential(
        marker: String,
        expiresAt: TimeInterval
    ) throws -> WebCredential {
        try WebCredential(
            cookies: WebCredentialCookieName.allCases.map { name in
                WebCredentialCookie(
                    name: name,
                    value: "SMOKE_\(marker)_\(name.rawValue)",
                    domain: ".bilibili.com",
                    path: "/",
                    isSecure: true,
                    isHTTPOnly: name == .session,
                    expiresAt: Date(timeIntervalSince1970: expiresAt)
                )
            }
        )
    }

    private static func assertStoredAttributes() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw SmokeFailure.attributeReadFailed(status)
        }
        guard let attributes = result as? [String: Any],
              attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
              !isSynchronizable(attributes[kSecAttrSynchronizable as String])
        else {
            throw SmokeFailure.invalidStoredAttributes
        }
    }

    private static func isSynchronizable(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }

    private static func signingTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess,
              let code
        else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let values = information as? [String: Any]
        else {
            return nil
        }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private enum SmokeFailure: Error, Sendable {
        case productionNamespace
        case initialItemPresent
        case firstReadMismatch
        case secondReadMismatch
        case attributeReadFailed(OSStatus)
        case invalidStoredAttributes
        case finalItemRemains
    }
}
