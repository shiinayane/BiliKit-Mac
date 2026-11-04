import Foundation

/// Web 凭据唯一允许的 Cookie 名称白名单；QR 成功响应里的其他 Cookie 一律丢弃（见 SECURITY-MODEL
/// §1）。
enum WebCredentialCookieName: String, CaseIterable, Codable, Sendable {
    case userID = "DedeUserID"
    case userIDChecksum = "DedeUserID__ckMd5"
    case session = "SESSDATA"
    case csrf = "bili_jct"
    case sessionID = "sid"
}

/// 白名单内的单个 Cookie 及其属性；`description` 与 Mirror 不展示值（见 SECURITY-MODEL §1）。
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

/// 经白名单、结构与大小验证的完整 Web Cookie 集合；描述与反射均不暴露值。
struct WebCredential: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    /// Keychain envelope 编码后的大小上限，编码与解码共用；超出按 envelope 无效处理。
    ///
    /// 单个值另有 8 KiB 上限。调小可能拒收合法凭据，调大只放宽异常输入。
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

    func value(for name: WebCredentialCookieName) -> String? {
        cookies.first(where: { $0.name == name })?.value
    }

    func isExpired(at date: Date = .now) -> Bool {
        // `Date` 不用 `<=`／`>=`：Xcode 27.2 SDK 把它们编译成 macOS 27.2 才有的弱链接符号，
        // 见 ARCHITECTURE「平台与命名」。
        cookies.contains { !(date < $0.expiresAt) }
    }

    var description: String { "<web-credential>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

    private static func isStructurallyValid(_ cookie: WebCredentialCookie) -> Bool {
        // 解码后重新校验值字符（可见 ASCII、不含 `;`）与大小，以及 domain、path、Secure，
        // 见 SECURITY-MODEL §1。
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

/// 凭据结构或 Keychain envelope 的编解码失败；`KeychainWebCredentialStore` 把它们统一当作凭据损坏。
enum WebCredentialCodingError: Error, Sendable, Equatable {
    case invalidCredential
    case invalidEnvelope
    case unsupportedVersion(Int)
}

/// 为 Keychain payload 提供版本化编码，并在解码后重新验证全部 Cookie 约束。
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
