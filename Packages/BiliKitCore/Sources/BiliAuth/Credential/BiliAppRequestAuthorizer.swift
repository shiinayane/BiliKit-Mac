import BiliNetworking
import Foundation

/// App 端（`https://app.bilibili.com`）只读请求的唯一授权器：给 allowlist 里的 GET 附加 access_token 并做 APP 签名。
///
/// 每次授权都读 Keychain（与账户读取同一规则，见 `loadCredentialForRead`）：有凭据时把 `access_key` 放进 query 再签名；
/// 本地明确没有凭据时只签名、不带凭据，即未登录用户的匿名 App 请求。凭据损坏或过期会删除并报告失效，Keychain
/// 不可用只在窗口已确认未登录时按无凭据处理，都不降级为匿名签名。签名后的 URL 本身就是凭据，只能原样发出，见
/// SECURITY-MODEL §3。无状态，不缓存凭据或签名。
public struct BiliAppRequestAuthorizer: HTTPSigningRequestAuthorizing, Sendable {
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
        guard
            let target = AppRequestAuthorizationSupport.validatedGET(
                request,
                allowedPaths: allowedPaths
            )
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
        var parameters = target.parameters
        if let credential {
            parameters["access_key"] = credential.appAccessToken.value
        }
        return SignedHTTPRequest(
            request: try AppRequestAuthorizationSupport.signedRequest(
                request,
                components: target.components,
                parameters: parameters
            ),
            carriesCredential: credential != nil
        )
    }
}
