import BiliNetworking
import Foundation

/// App 端（`https://app.bilibili.com`）的读取与写入授权器共用的目标校验、query 解析与签名组装。
///
/// 只放两边逐字相同的规则；哪些 path 可授权、query 字段的 schema、是否允许匿名签名与账户绑定仍在各自的授权器里，
/// 不因共用这些帮手而合并成一个泛化的 App 授权器（见 SECURITY-MODEL §3）。无状态。
enum AppRequestAuthorizationSupport {
    /// 唯一放行的主机；不用后缀匹配，见 SECURITY-MODEL §3。
    private static let host = "app.bilibili.com"
    /// 由授权器写入的参数；调用方自带任何一个都按请求不合规拒绝，不能借它们夹带或覆盖凭据与签名。
    private static let reservedParameterNames: Set<String> = [
        "access_key", "appkey", "ts", "sign", "mobile_access_key"
    ]

    /// 精确 host、端口与 GET，path 在 `allowedPaths` 里且编码规范，没有 userinfo、fragment 与正文时，返回 URL 组成与
    /// 调用方给出的 query 参数；否则为 nil，见 SECURITY-MODEL §3。
    ///
    /// 参数同名重复、无法解码或含保留参数时同样为 nil。
    static func validatedGET(
        _ request: HTTPRequest,
        allowedPaths: Set<String>
    ) -> (components: URLComponents, parameters: [String: String])? {
        guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            components.host?.lowercased() == host,
            components.port == nil || components.port == 443,
            components.user == nil,
            components.password == nil,
            allowedPaths.contains(components.path),
            components.percentEncodedPath == components.path,
            components.fragment == nil,
            request.method == .get,
            request.body == nil,
            let parameters = parameters(of: components)
        else {
            return nil
        }
        return (components, parameters)
    }

    /// 把参数（授权器已按需放入 `access_key`）签名后写回 query，返回新请求；签名失败按请求不合规拒绝。
    ///
    /// 签名后的 URL 本身就是凭据，只能原样发出，见 SECURITY-MODEL §3。
    static func signedRequest(
        _ request: HTTPRequest,
        components: URLComponents,
        parameters: [String: String]
    ) throws -> HTTPRequest {
        var components = components
        guard
            let signedQuery = BiliAppSigning.signed(
                parameters,
                timestamp: Int64(Date.now.timeIntervalSince1970)
            )
        else {
            throw BiliRequestAuthorizationError.requestNotAllowed
        }
        components.percentEncodedQuery = signedQuery
        guard let url = components.url else {
            throw BiliRequestAuthorizationError.requestNotAllowed
        }
        return HTTPRequest(
            url: url,
            method: request.method,
            headers: request.headers,
            body: request.body
        )
    }

    private static func parameters(of components: URLComponents) -> [String: String]? {
        guard let query = components.percentEncodedQuery, !query.isEmpty else { return [:] }
        guard let fields = WriteRequestAuthorizationSupport.decodedUniqueFields(query),
            reservedParameterNames.isDisjoint(with: fields.keys)
        else {
            return nil
        }
        return fields
    }
}
