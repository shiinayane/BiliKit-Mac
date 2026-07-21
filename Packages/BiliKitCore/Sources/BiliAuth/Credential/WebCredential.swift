import Foundation

enum WebCredentialCookieName: String, CaseIterable, Codable, Sendable {
    case userID = "DedeUserID"
    case userIDChecksum = "DedeUserID__ckMd5"
    case session = "SESSDATA"
    case csrf = "bili_jct"
    case sessionID = "sid"
}

struct WebCredentialCookie: Codable, Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    let name: WebCredentialCookieName
    let value: String
    let domain: String
    let path: String
    let isSecure: Bool
    let isHTTPOnly: Bool
    let expiresAt: Date

    var description: String { "<web-credential-cookie-\(name.rawValue)>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

struct WebCredential: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    static let maximumEncodedSize = 64 * 1_024

    let cookies: [WebCredentialCookie]

    init(cookies: [WebCredentialCookie]) throws {
        let expectedNames = Set(WebCredentialCookieName.allCases)
        let actualNames = Set(cookies.map(\.name))
        guard cookies.count == expectedNames.count,
              actualNames == expectedNames,
              cookies.allSatisfy(Self.isStructurallyValid)
        else {
            throw WebCredentialCodingError.invalidCredential
        }
        self.cookies = cookies.sorted { $0.name.rawValue < $1.name.rawValue }
    }

    var cookieHeader: String {
        cookies
            .map { "\($0.name.rawValue)=\($0.value)" }
            .joined(separator: "; ")
    }

    func isExpired(at date: Date = .now) -> Bool {
        cookies.contains { $0.expiresAt <= date }
    }

    var description: String { "<web-credential>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

    private static func isStructurallyValid(_ cookie: WebCredentialCookie) -> Bool {
        let valueBytes = cookie.value.utf8
        return !valueBytes.isEmpty
            && valueBytes.count <= 8_192
            && valueBytes.allSatisfy { byte in
                byte >= 0x21 && byte <= 0x7E && byte != 0x3B
            }
            && cookie.domain == ".bilibili.com"
            && cookie.path == "/"
            && cookie.isSecure
    }
}

enum WebCredentialCodingError: Error, Sendable, Equatable {
    case invalidCredential
    case invalidEnvelope
    case unsupportedVersion(Int)
}

enum WebCredentialCodec {
    static let currentVersion = 1

    static func encode(_ credential: WebCredential) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(
                Envelope(version: currentVersion, cookies: credential.cookies)
            )
        } catch {
            throw WebCredentialCodingError.invalidEnvelope
        }
        guard data.count <= WebCredential.maximumEncodedSize else {
            throw WebCredentialCodingError.invalidEnvelope
        }
        return data
    }

    static func decode(_ data: Data) throws -> WebCredential {
        guard !data.isEmpty, data.count <= WebCredential.maximumEncodedSize else {
            throw WebCredentialCodingError.invalidEnvelope
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw WebCredentialCodingError.invalidEnvelope
        }
        guard envelope.version == currentVersion else {
            throw WebCredentialCodingError.unsupportedVersion(envelope.version)
        }
        return try WebCredential(cookies: envelope.cookies)
    }

    private struct Envelope: Codable {
        let version: Int
        let cookies: [WebCredentialCookie]
    }
}
