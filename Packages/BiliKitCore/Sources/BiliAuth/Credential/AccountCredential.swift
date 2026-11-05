import Foundation

/// 登录凭据里网页 Cookie 唯一允许的名称白名单；扫码成功正文里的其他 Cookie 一律丢弃（见 SECURITY-MODEL
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

/// TV 扫码登录得到的 App 端 access_token 与它的到期时刻；`description` 与 Mirror 不展示值（见 SECURITY-MODEL §1）。
///
/// 值只接受现场观察到的形状（32 个十六进制字符），形状变化按凭据无效失败关闭。
struct AppAccessToken: Codable, Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    let value: String
    let expiresAt: Date

    var description: String { "<app-access-token>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

    static func isValidValue(_ value: String) -> Bool {
        ASCIIHexShape.matches(value, length: 32)
    }
}

/// 扫码 `auth_code` 与 access_token 共用的形状判定：固定长度的 ASCII 十六进制（大小写均可）。
enum ASCIIHexShape {
    static func matches(_ value: String, length: Int) -> Bool {
        value.utf8.count == length
            && value.utf8.allSatisfy { byte in
                (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte)
                    || (0x61...0x66).contains(byte)
            }
    }
}

/// 一次登录的完整凭据：经白名单、结构与大小验证的网页 Cookie 集合，加同一次登录的 App 端 access_token。
///
/// 两者一起保存、一起过期、一起删除，不存在只有其一的状态。描述与反射均不暴露值。
struct AccountCredential: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    /// Keychain envelope 编码后的大小上限，编码与解码共用；超出按 envelope 无效处理。
    ///
    /// 单个值另有 8 KiB 上限。调小可能拒收合法凭据，调大只放宽异常输入。
    static let maximumEncodedSize = 64 * 1_024

    let cookies: [WebCredentialCookie]
    let appAccessToken: AppAccessToken

    init(cookies: [WebCredentialCookie], appAccessToken: AppAccessToken) throws {
        let expectedNames = Set(WebCredentialCookieName.allCases)
        let actualNames = Set(cookies.map(\.name))
        guard cookies.count == expectedNames.count,
            actualNames == expectedNames,
            cookies.allSatisfy(Self.isStructurallyValid),
            AppAccessToken.isValidValue(appAccessToken.value)
        else {
            throw AccountCredentialCodingError.invalidCredential
        }
        self.cookies = cookies.sorted { $0.name.rawValue < $1.name.rawValue }
        self.appAccessToken = appAccessToken
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
        !(date < appAccessToken.expiresAt) || cookies.contains { !(date < $0.expiresAt) }
    }

    var description: String { "<account-credential>" }
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

/// 凭据结构或 Keychain envelope 的编解码失败；`KeychainAccountCredentialStore` 把它们统一当作凭据损坏。
enum AccountCredentialCodingError: Error, Sendable, Equatable {
    case invalidCredential
    case invalidEnvelope
    case unsupportedVersion(Int)
}

/// 为 Keychain payload 提供版本化编码，并在解码后重新验证全部 Cookie 与 token 约束。
///
/// 版本 2 起含 App 端 access_token。只有 Cookie 的版本 1 按不支持的版本拒绝，由 store 当作损坏凭据删除，用户
/// 重新登录一次；旧版 App 读到版本 2 同样会删除它（见 SECURITY-MODEL §6）。
enum AccountCredentialCodec {
    static let currentVersion = 2

    static func encode(_ credential: AccountCredential) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(
                Envelope(
                    version: currentVersion,
                    cookies: credential.cookies,
                    appAccessToken: credential.appAccessToken
                )
            )
        } catch {
            throw AccountCredentialCodingError.invalidEnvelope
        }
        guard data.count <= AccountCredential.maximumEncodedSize else {
            throw AccountCredentialCodingError.invalidEnvelope
        }
        return data
    }

    static func decode(_ data: Data) throws -> AccountCredential {
        guard !data.isEmpty, data.count <= AccountCredential.maximumEncodedSize else {
            throw AccountCredentialCodingError.invalidEnvelope
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        // 先只读版本：旧版本的字段集合不同，直接按当前结构解码会把它误报成损坏的 envelope。
        let version: Int
        do {
            version = try decoder.decode(VersionProbe.self, from: data).version
        } catch {
            throw AccountCredentialCodingError.invalidEnvelope
        }
        guard version == currentVersion else {
            throw AccountCredentialCodingError.unsupportedVersion(version)
        }
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw AccountCredentialCodingError.invalidEnvelope
        }
        return try AccountCredential(
            cookies: envelope.cookies,
            appAccessToken: envelope.appAccessToken
        )
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    private struct Envelope: Codable {
        let version: Int
        let cookies: [WebCredentialCookie]
        let appAccessToken: AppAccessToken
    }
}
