import BiliNetworking
import Foundation

/// App 端（`https://app.bilibili.com`）只读请求的唯一授权器：给 allowlist 里的 GET 附加 access_token 并做 APP 签名。
///
/// 每次授权都读 Keychain（与账户读取同一规则，见 `loadCredentialForRead`）：有凭据时把 `access_key` 放进 query 再签名；
/// 本地明确没有凭据时只签名、不带凭据，即未登录用户的匿名 App 请求。凭据损坏或过期会删除并报告失效，Keychain
/// 不可用只在窗口已确认未登录时按无凭据处理，都不降级为匿名签名。签名后的 URL 本身就是凭据，只能原样发出，见
/// SECURITY-MODEL §3。无状态，不缓存凭据或签名。
public struct BiliAppRequestAuthorizer: HTTPSigningRequestAuthorizing, Sendable {
    /// 唯一放行的主机；不用后缀匹配，见 SECURITY-MODEL §3。
    private static let host = "app.bilibili.com"
    /// 由授权器写入的参数；调用方自带任何一个都按请求不合规拒绝，不能借它们夹带或覆盖凭据与签名。
    private static let reservedParameterNames: Set<String> = [
        "access_key", "appkey", "ts", "sign", "mobile_access_key"
    ]

    private let store: any AccountCredentialStoring
    private let allowedPaths: Set<String>
    private let isConfirmedSignedOut: @Sendable () -> Bool

    /// `isConfirmedSignedOut` 与账户读取授权器同义：为 true 时 Keychain 不可用按无凭据处理（匿名签名）。
    public init(
        allowedPaths: Set<String>,
        isConfirmedSignedOut: @escaping @Sendable () -> Bool
    ) {
        self.init(
            store: KeychainAccountCredentialStore(),
            allowedPaths: allowedPaths,
            isConfirmedSignedOut: isConfirmedSignedOut
        )
    }

    /// Keychain 系统边界；public init 由此接入 Keychain store。
    init(
        store: any AccountCredentialStoring,
        allowedPaths: Set<String>,
        isConfirmedSignedOut: @escaping @Sendable () -> Bool
    ) {
        self.store = store
        self.allowedPaths = allowedPaths
        self.isConfirmedSignedOut = isConfirmedSignedOut
    }

    public func authorize(_ request: HTTPRequest) async throws -> SignedHTTPRequest {
        guard var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
            isAllowed(request, components: components),
            var parameters = Self.parameters(of: components)
        else {
            throw BiliRequestAuthorizationError.requestNotAllowed
        }
        guard !request.headers.containsCredentialHeader else {
            throw BiliRequestAuthorizationError.credentialHeaderAlreadyPresent
        }

        let credential: AccountCredential?
        do {
            credential = try store.loadCredentialForRead(isConfirmedSignedOut: isConfirmedSignedOut)
        } catch BiliRequestAuthorizationError.missingCredential {
            credential = nil
        }
        if let credential {
            parameters["access_key"] = credential.appAccessToken.value
        }

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
        return SignedHTTPRequest(
            request: HTTPRequest(
                url: url,
                method: request.method,
                headers: request.headers,
                body: request.body
            ),
            carriesCredential: credential != nil
        )
    }

    /// 精确 host、端口与 GET，path 必须在 allowlist 里且编码规范，没有 userinfo、fragment 与正文，见 SECURITY-MODEL §3。
    private func isAllowed(_ request: HTTPRequest, components: URLComponents) -> Bool {
        components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == Self.host
            && (components.port == nil || components.port == 443)
            && components.user == nil
            && components.password == nil
            && allowedPaths.contains(components.path)
            && components.percentEncodedPath == components.path
            && components.fragment == nil
            && request.method == .get
            && request.body == nil
    }

    /// 调用方给出的 query 参数；同名重复、无法解码或含保留参数时为 nil。
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
