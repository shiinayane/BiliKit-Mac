import BiliNetworking
import Foundation

/// `BiliAuth` 自有网络的唯一 transport 配置、passport 签名表单与 nav 登录态校验形状。
///
/// 传输错误如何映射留给各调用方（QR 登录与 Keychain 恢复的失败语义不同）。
enum AuthenticationHTTP {
    /// nav 校验响应不可用的原因；调用方各自映射（QR 登录报无效响应，恢复路径报校验不可用）。
    enum NavigationValidationFailure: Error {
        case responseTooLarge
        case nonJSONResponse
        case invalidResponse
    }

    /// QR 与 nav 响应正文的上限；正常 JSON 远小于此值，超出按异常响应失败关闭。
    static let maximumResponseSize = 256 * 1_024
    /// Cookie 已在服务端失效（被踢下线、改密）时 nav 的业务码，`data.isLogin` 同时为 false。
    static let notLoggedInCode = -101

    private static let navigationValidationURL: URL = {
        guard
            let url = URL(
                string: "https://api.bilibili.com" + BiliAuthenticationService.sessionValidationPath
            )
        else {
            preconditionFailure("Static navigation validation URL must be valid")
        }
        return url
    }()

    /// 无 Cookie storage、无 URL cache、拒绝 redirect 的 ephemeral transport。
    static func makeProductionTransport() -> URLSessionTransport {
        URLSessionTransport(configuration: .credentialFreeEphemeral())
    }

    /// passport 上带 APP 签名的表单 POST（TV 扫码的取码、轮询与凭据续期）；签名失败为 nil。
    ///
    /// 签名后的正文可能含凭据（续期带 access_key 与 refresh_token），只能原样发出。
    static func signedFormRequest(url: URL, parameters: [String: String]) -> HTTPRequest? {
        guard
            let form = BiliAppSigning.signed(
                parameters,
                timestamp: Int64(Date.now.timeIntervalSince1970)
            )
        else {
            return nil
        }
        return HTTPRequest(
            url: url,
            method: .post,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": HTTPUserAgent.short
            ],
            body: Data(form.utf8)
        )
    }

    /// `cookieHeader` 为 nil 时由授权器从 Keychain 附加凭据。
    static func navigationValidationRequest(cookieHeader: String? = nil) -> HTTPRequest {
        var headers = [
            "Accept": "application/json",
            "Referer": "https://www.bilibili.com/",
            "User-Agent": HTTPUserAgent.short
        ]
        headers["Cookie"] = cookieHeader
        return HTTPRequest(url: navigationValidationURL, headers: headers)
    }

    /// 把 nav 响应解释为登录态：`code` 0 按 `data.isLogin`，-101 且 `isLogin` 为 false
    /// 为明确未登录，其他一律抛错；不读取或回显服务端 message（见 SECURITY-MODEL §2）。
    static func navigationResult(
        from response: HTTPResponse
    ) throws(NavigationValidationFailure) -> NavigationAuthenticationResult {
        guard response.body.count <= maximumResponseSize else {
            throw .responseTooLarge
        }
        guard response.looksLikeJSON() else {
            throw .nonJSONResponse
        }
        guard
            let envelope = try? JSONDecoder().decode(
                NavigationAuthenticationEnvelope.self,
                from: response.body
            ),
            let data = envelope.data
        else {
            throw .invalidResponse
        }
        switch envelope.code {
        case 0:
            return data.authenticationResult
        case notLoggedInCode where !data.isLogin:
            // 服务端明确答复未登录，与 code 0 + isLogin false 同义；其他非 0 码仍失败关闭。
            return .signedOut
        default:
            throw .invalidResponse
        }
    }
}
