import Foundation

/// 签发凭据的成功正文 `data` 里共有的两部分：`token_info`（mid、access_token、refresh_token、`expires_in`）与
/// `cookie_info`。
///
/// TV 扫码轮询成功（`TVQRLoginSession`）与续期成功（`AccountCredentialRenewal`）的正文都是这个形状，两条路径只经
/// `credential(receivedAt:)` 把它变成凭据，校验规则只在这一处，见 SECURITY-MODEL §1。轮询正文顶层另有与 `token_info`
/// 相同的副本，`sso`、`hint` 等其他字段都不解码，不进入内存模型。
struct IssuedCredentialPayload: Decodable, Sendable {
    /// Cookie 唯一接受的作用域：`cookie_info.domains` 必须包含它。
    private static let cookieDomain = ".bilibili.com"

    let tokenInfo: TokenInfo
    let cookieInfo: CookieInfo

    private enum CodingKeys: String, CodingKey {
        case tokenInfo = "token_info"
        case cookieInfo = "cookie_info"
    }

    struct TokenInfo: Decodable, Sendable {
        let mid: Int64
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int64

        private enum CodingKeys: String, CodingKey {
            case mid
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    struct CookieInfo: Decodable, Sendable {
        let cookies: [Cookie]
        let domains: [String]
    }

    /// `secure` 字段不读：Secure 由 `credential(receivedAt:)` 统一记为真，理由见那里。
    struct Cookie: Decodable, Sendable {
        let name: String
        let value: String
        let httpOnly: Int
        let expires: Int64

        private enum CodingKeys: String, CodingKey {
            case name
            case value
            case httpOnly = "http_only"
            case expires
        }
    }

    /// 只取白名单 Cookie 与 `token_info` 的 token，返回这份凭据与它的账户 `mid`。
    ///
    /// Cookie 缺任何一个、重名、`mid` 与 `DedeUserID` 不一致、token 形状或有效期不合规时为 nil，见 SECURITY-MODEL §1。
    ///
    /// token 的到期时刻按收到响应的时刻 `now` 加 `expires_in` 计算。
    ///
    /// 正文只给每个 Cookie 的名称、值、到期时间与两个标志，作用域是另一个列表。domain、path 与 Secure 因此由这里
    /// 填写，不是服务端声明：domain 固定为 `.bilibili.com`（且必须出现在 `domains` 里），path 固定为 `/`，Secure 记为
    /// 真，因为这些 Cookie 只经授权器发往 HTTPS 的精确主机。`AccountCredential` 之后的校验对这几项只是复核这里写入的值。
    func credential(receivedAt now: Date) -> (mid: Int64, credential: AccountCredential)? {
        guard cookieInfo.domains.contains(Self.cookieDomain), tokenInfo.mid > 0,
            tokenInfo.expiresIn > 0
        else {
            return nil
        }
        let allowedNames = Set(WebCredentialCookieName.allCases.map(\.rawValue))
        let cookies = cookieInfo.cookies.filter { allowedNames.contains($0.name) }
        guard cookies.count == allowedNames.count,
            Set(cookies.map(\.name)) == allowedNames,
            cookies.first(where: { $0.name == WebCredentialCookieName.userID.rawValue })?.value
                == String(tokenInfo.mid)
        else {
            return nil
        }
        let credentialCookies: [WebCredentialCookie] = cookies.compactMap { cookie in
            guard let name = WebCredentialCookieName(rawValue: cookie.name), cookie.expires > 0
            else {
                return nil
            }
            return WebCredentialCookie(
                name: name,
                value: cookie.value,
                domain: Self.cookieDomain,
                path: "/",
                isSecure: true,
                isHTTPOnly: cookie.httpOnly != 0,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(cookie.expires))
            )
        }
        let appAccessToken = AppAccessToken(
            value: tokenInfo.accessToken,
            refreshToken: tokenInfo.refreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(tokenInfo.expiresIn))
        )
        guard
            let credential = try? AccountCredential(
                cookies: credentialCookies,
                appAccessToken: appAccessToken
            )
        else {
            return nil
        }
        return (tokenInfo.mid, credential)
    }
}
