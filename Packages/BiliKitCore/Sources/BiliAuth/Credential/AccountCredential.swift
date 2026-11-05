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

/// TV 扫码登录或续期得到的 App 端 access_token、与它配对的 refresh_token，以及两者共同的到期时刻；`description` 与
/// Mirror 不展示值（见 SECURITY-MODEL §1）。
///
/// refresh_token 只用于续期（`AccountCredentialRenewal`），不进入任何业务请求。两个值都只接受现场观察到的形状，形状
/// 变化按凭据无效失败关闭：扫码签发的 access_token 是 32 个十六进制字符，续期签发的是 220 个左右的 URL 安全字符；
/// refresh_token 两条路径都是 32 个十六进制字符。
struct AppAccessToken: Codable, Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    let value: String
    let refreshToken: String
    let expiresAt: Date

    var description: String { "<app-access-token>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

    /// access_token 接受的长度：覆盖扫码的 32 与续期的约 220，上限只为拒绝异常正文，不是协议值。
    private static let accessTokenLengths = 32...512

    /// 两种签发形状的并集：字母、数字、`-` 与 `_`（续期 token 实测出现大小写字母与 `-`）。
    ///
    /// 不放行其他标点，token 因此不需要转义也不会改变 query 或表单的结构，见 SECURITY-MODEL §1。
    static func isValidAccessToken(_ value: String) -> Bool {
        accessTokenLengths.contains(value.utf8.count)
            && value.utf8.allSatisfy { byte in
                (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
                    || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x5F
            }
    }

    static func isValidRefreshToken(_ value: String) -> Bool {
        ASCIIHexShape.matches(value, length: 32)
    }
}

/// 扫码 `auth_code` 与 refresh_token 共用的形状判定：固定长度的 ASCII 十六进制（大小写均可）。
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
            AppAccessToken.isValidAccessToken(appAccessToken.value),
            AppAccessToken.isValidRefreshToken(appAccessToken.refreshToken)
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

    /// token 与各 Cookie 里最早的到期时刻：任一项到期整份凭据就过期，续期按它判断离到期还有多久。
    var expiresAt: Date {
        cookies.map(\.expiresAt).reduce(appAccessToken.expiresAt) { $1 < $0 ? $1 : $0 }
    }

    func isExpired(at date: Date = .now) -> Bool {
        // `Date` 不用 `<=`／`>=`：Xcode 27.2 SDK 把它们编译成 macOS 27.2 才有的弱链接符号，
        // 见 ARCHITECTURE「平台与命名」。
        !(date < expiresAt)
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
/// 版本 3 含 Cookie、App 端 access_token 与配对的 refresh_token。只有 Cookie 的版本 1 与不含 refresh_token 的版本 2
/// 按不支持的版本拒绝，由 store 当作损坏凭据删除，用户重新登录一次；旧版 App 读到版本 3 同样会删除它（见
/// SECURITY-MODEL §1）。
enum AccountCredentialCodec {
    static let currentVersion = 3

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
