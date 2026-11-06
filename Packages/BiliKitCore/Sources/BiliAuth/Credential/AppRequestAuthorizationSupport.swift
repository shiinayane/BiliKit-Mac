import BiliNetworking
import Foundation

/// App 端（`https://app.bilibili.com`）的读取与写入授权器共用的目标校验、query 与表单解析，以及签名组装。
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
        guard request.method == .get,
            request.body == nil,
            let components = validatedTarget(request, allowedPaths: allowedPaths),
            let parameters = parameters(encoded: components.percentEncodedQuery ?? "")
        else {
            return nil
        }
        return (components, parameters)
    }

    /// 与 `validatedGET` 相同的目标校验，但方法是 POST、没有 query、正文是 urlencoded 表单（不超过
    /// `maximumFormBodySize`）时，返回调用方给出的表单字段；否则为 nil，见 SECURITY-MODEL §3。
    ///
    /// 字段同名重复、无法解码或含保留参数时同样为 nil：凭据与签名只能由授权器写进正文。
    static func validatedPOSTForm(
        _ request: HTTPRequest,
        allowedPaths: Set<String>
    ) -> [String: String]? {
        guard request.method == .post,
            let components = validatedTarget(request, allowedPaths: allowedPaths),
            components.percentEncodedQuery == nil,
            request.headers.first(where: {
                $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
            })?.value == formContentType,
            let body = request.body,
            body.count <= maximumFormBodySize,
            let encoded = String(data: body, encoding: .utf8),
            !encoded.isEmpty,
            let parameters = parameters(encoded: encoded)
        else {
            return nil
        }
        return parameters
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
        components.percentEncodedQuery = try signed(parameters)
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

    /// `signedRequest` 的表单版：签名后的字段写进正文，URL 与 header 不变；签好名的正文同样本身就是凭据。
    static func signedFormRequest(
        _ request: HTTPRequest,
        parameters: [String: String]
    ) throws -> HTTPRequest {
        HTTPRequest(
            url: request.url,
            method: request.method,
            headers: request.headers,
            body: Data(try signed(parameters).utf8)
        )
    }

    /// 表单正文上限：App 端写入只有几个数字字段，1 KiB 远超正常大小；超出说明请求构造有误，直接拒绝。
    private static let maximumFormBodySize = 1_024
    private static let formContentType = "application/x-www-form-urlencoded"

    private static func signed(_ parameters: [String: String]) throws -> String {
        guard
            let signed = BiliAppSigning.signed(
                parameters,
                timestamp: Int64(Date.now.timeIntervalSince1970)
            )
        else {
            throw BiliRequestAuthorizationError.requestNotAllowed
        }
        return signed
    }

    /// 精确 host、端口与规范编码的 path（在 `allowedPaths` 里），没有 userinfo 与 fragment；方法与参数由调用方另行核对。
    private static func validatedTarget(
        _ request: HTTPRequest,
        allowedPaths: Set<String>
    ) -> URLComponents? {
        guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            components.host?.lowercased() == host,
            components.port == nil || components.port == 443,
            components.user == nil,
            components.password == nil,
            allowedPaths.contains(components.path),
            components.percentEncodedPath == components.path,
            components.fragment == nil
        else {
            return nil
        }
        return components
    }

    private static func parameters(encoded: String) -> [String: String]? {
        guard !encoded.isEmpty else { return [:] }
        guard let fields = WriteRequestAuthorizationSupport.decodedUniqueFields(encoded),
            reservedParameterNames.isDisjoint(with: fields.keys)
        else {
            return nil
        }
        return fields
    }
}
