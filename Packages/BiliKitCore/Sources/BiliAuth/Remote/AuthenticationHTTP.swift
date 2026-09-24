import BiliNetworking
import Foundation

/// `BiliAuth` 自有网络的唯一 transport 配置与 nav 登录态校验形状。
///
/// 传输错误如何映射留给各调用方（QR 登录与 Keychain 恢复的失败语义不同）。
enum AuthenticationHTTP {
    enum NavigationValidationFailure: Error {
        case responseTooLarge
        case nonJSONResponse
        case invalidResponse
    }

    static let maximumResponseSize = 256 * 1_024

    private static let navigationValidationURL: URL = {
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/nav") else {
            preconditionFailure("Static navigation validation URL must be valid")
        }
        return url
    }()

    /// 无 Cookie storage、无 URL cache、拒绝 redirect 的 ephemeral transport。
    static func makeProductionTransport() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.credentialFreeEphemeral()
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSessionTransport(
            configuration: configuration,
            redirectPolicy: .reject
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
            envelope.code == 0,
            let data = envelope.data
        else {
            throw .invalidResponse
        }
        return data.authenticationResult
    }
}
