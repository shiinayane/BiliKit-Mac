import BiliNetworking
import Foundation

/// 各授权器共用的失败；经 `authorizationFailureKind` 归入 BiliNetworking 的稳定分类。
///
/// 请求不在 allowlist 或调用方自带凭据 header 属于 `denied`（客户端编程错误）；
/// 本地无凭据才是 `missingCredential`；凭据损坏或过期在清除后归为 `invalidCredential`；账户写入时本地凭据属于
/// 另一个账户（`accountMismatch`）同样归为 `invalidCredential`，但不清除凭据；
/// Keychain 不可用与校验不可用都是 `unavailable`（见 SECURITY-MODEL §3）。
public enum BiliRequestAuthorizationError:
    HTTPRequestAuthorizationFailure, Sendable, Equatable
{
    case requestNotAllowed
    case credentialHeaderAlreadyPresent
    case missingCredential
    case expiredCredential
    case invalidCredential
    /// 本地凭据的 `DedeUserID` 不是写请求绑定的账户。
    case accountMismatch
    case credentialStoreUnavailable
    case validationUnavailable

    public var authorizationFailureKind: HTTPRequestAuthorizationFailureKind {
        switch self {
        case .missingCredential:
            .missingCredential
        case .expiredCredential, .invalidCredential, .accountMismatch:
            .invalidCredential
        case .credentialStoreUnavailable, .validationUnavailable:
            .unavailable
        case .requestNotAllowed, .credentialHeaderAlreadyPresent:
            .denied
        }
    }
}

/// 从 Keychain 按需读取 Cookie，并只授权 Bilibili API 的只读账户请求。
///
/// 调用方声明账户读取能力后，scheme、host、port、method、exact path、userinfo、fragment 与
/// 现有凭据 header 仍会再次验证。损坏或过期凭据会清除，媒体/CDN/loopback 请求无法通过此边界
/// （见 SECURITY-MODEL §3）。不缓存 header：每次授权都重新读取 Keychain 并生成新请求。
public struct BiliCredentialRequestAuthorizer: HTTPRequestAuthorizing, Sendable {
    private let store: any AccountCredentialStoring
    private let httpClient: HTTPClient
    private let transportInvalidator: (@Sendable () -> Void)?
    private let allowedPaths: Set<String>
    private let isConfirmedSignedOut: @Sendable () -> Bool

    /// `isConfirmedSignedOut` 为 true 时 Keychain 不可用按无凭据处理（由调用方决定能否匿名）；
    /// 认证服务自身的复核授权器不传，保持失败关闭。
    public init(
        allowedPaths: Set<String>,
        isConfirmedSignedOut: @escaping @Sendable () -> Bool = { false }
    ) {
        let transport = AuthenticationHTTP.makeProductionTransport()
        store = KeychainAccountCredentialStore()
        httpClient = HTTPClient(transport: transport)
        transportInvalidator = { transport.invalidateAndCancel() }
        self.allowedPaths = allowedPaths
        self.isConfirmedSignedOut = isConfirmedSignedOut
    }

    /// Keychain 与会话校验网络两个系统边界；public init 由此接入 Keychain store 与认证专用 session。
    init(
        store: any AccountCredentialStoring,
        allowedPaths: Set<String>,
        transport: any HTTPTransport,
        isConfirmedSignedOut: @escaping @Sendable () -> Bool = { false }
    ) {
        self.store = store
        httpClient = HTTPClient(transport: transport)
        if let invalidating = transport as? any HTTPTransportInvalidating {
            transportInvalidator = { invalidating.invalidateAndCancel() }
        } else {
            transportInvalidator = nil
        }
        self.allowedPaths = allowedPaths
        self.isConfirmedSignedOut = isConfirmedSignedOut
    }

    /// 返回附带短生命周期 Cookie header 的新请求；原请求不会被原地共享或缓存。
    public func authorize(_ request: HTTPRequest) async throws -> HTTPRequest {
        try authorizedWithCredential(request).request
    }

    /// `authorize` 的实现，另返回这次读到的凭据，供复核在删除前比对。
    private func authorizedWithCredential(
        _ request: HTTPRequest
    ) throws -> (request: HTTPRequest, credential: AccountCredential) {
        guard isAllowed(request) else {
            throw BiliRequestAuthorizationError.requestNotAllowed
        }
        guard !request.headers.containsCredentialHeader else {
            throw BiliRequestAuthorizationError.credentialHeaderAlreadyPresent
        }

        let credential = try store.loadCredential(isConfirmedSignedOut: isConfirmedSignedOut)

        var headers = request.headers
        headers["Cookie"] = credential.cookieHeader
        let authorized = HTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: request.body
        )
        return (authorized, credential)
    }

    public func deleteStoredCredential() throws {
        do {
            try store.delete()
        } catch {
            throw BiliRequestAuthorizationError.credentialStoreUnavailable
        }
    }

    public func invalidateSession() {
        transportInvalidator?()
    }

    /// 验证已存凭据当前是否仍登录；明确失效会清除，验证不可用则保留并抛错。
    ///
    /// 只删除被判定未登录的那一份凭据：校验期间另一窗口的续期可能已把它换成新凭据（旧 Cookie 随即失效），这时改用
    /// 新凭据再校验一次，不把刚续期的凭据删掉、把所有窗口登出；再次被换掉时按校验不可用保留。
    func restoreAccountSession() async throws -> StoredAccountSessionRestoreResult {
        for _ in 0..<Self.restoreValidationAttempts {
            let authorized: (request: HTTPRequest, credential: AccountCredential)
            do {
                authorized = try authorizedWithCredential(
                    AuthenticationHTTP.navigationValidationRequest()
                )
            } catch BiliRequestAuthorizationError.missingCredential {
                return .signedOut(hadCredential: false)
            } catch BiliRequestAuthorizationError.expiredCredential,
                BiliRequestAuthorizationError.invalidCredential
            {
                return .signedOut(hadCredential: true)
            }

            let response: HTTPResponse
            do {
                response = try await httpClient.send(authorized.request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw BiliRequestAuthorizationError.validationUnavailable
            }
            guard
                let result = try? AuthenticationHTTP.navigationResult(from: response)
            else {
                throw BiliRequestAuthorizationError.validationUnavailable
            }
            if case .signedIn(let identity) = result {
                return .signedIn(identity)
            }
            guard (try? store.load()) == authorized.credential else { continue }
            try store.deleteInvalidCredential()
            return .signedOut(hadCredential: true)
        }
        throw BiliRequestAuthorizationError.validationUnavailable
    }

    /// 复核最多校验几份凭据：第一份校验期间被续期换掉时，再校验一次新的那份。
    private static let restoreValidationAttempts = 2

    private func isAllowed(_ request: HTTPRequest) -> Bool {
        guard
            let components = URLComponents(
                url: request.url,
                resolvingAgainstBaseURL: false
            )
        else {
            return false
        }
        // 精确 host、端口与 GET，path 必须在 allowlist 里且编码规范；不用后缀匹配，见
        // SECURITY-MODEL §3。
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "api.bilibili.com"
            && (components.port == nil || components.port == 443)
            && components.user == nil
            && components.password == nil
            && allowedPaths.contains(components.path)
            && components.percentEncodedPath == components.path
            && components.fragment == nil
            && request.method == .get
    }
}

extension AccountCredentialStoring {
    /// 全部授权器读取凭据的唯一规则：每次授权都读 Keychain，本地无凭据为 `missingCredential`；损坏或过期的凭据先删除
    /// 再报告为凭据失效，删除失败为 `credentialStoreUnavailable`。
    ///
    /// Keychain 不可用时，只有窗口已确认未登录（`isConfirmedSignedOut`）才按无凭据处理，否则失败关闭，见
    /// SECURITY-MODEL §2。写授权器传恒为 false 的确认：游客没有写入意图，Keychain 不可用一律失败关闭（§3）。
    func loadCredential(isConfirmedSignedOut: () -> Bool) throws -> AccountCredential {
        let credential: AccountCredential
        do {
            guard let stored = try load() else {
                throw BiliRequestAuthorizationError.missingCredential
            }
            credential = stored
        } catch let error as BiliRequestAuthorizationError {
            throw error
        } catch AccountCredentialStoreError.corruptCredential {
            try deleteInvalidCredential()
            throw BiliRequestAuthorizationError.invalidCredential
        } catch {
            guard isConfirmedSignedOut() else {
                throw BiliRequestAuthorizationError.credentialStoreUnavailable
            }
            throw BiliRequestAuthorizationError.missingCredential
        }
        guard !credential.isExpired() else {
            try deleteInvalidCredential()
            throw BiliRequestAuthorizationError.expiredCredential
        }
        return credential
    }

    /// 授权器删除损坏、过期或明确失效凭据的唯一做法：删除失败报告为 `credentialStoreUnavailable`，不让调用方误以为
    /// 凭据已清除。
    func deleteInvalidCredential() throws {
        do {
            try delete()
        } catch {
            throw BiliRequestAuthorizationError.credentialStoreUnavailable
        }
    }
}

extension Dictionary where Key == String, Value == String {
    /// 调用方已自带凭据类 header 时，授权器拒绝而不覆盖；各授权器共用这一判定。
    var containsCredentialHeader: Bool {
        keys.contains {
            $0.caseInsensitiveCompare("Cookie") == .orderedSame
                || $0.caseInsensitiveCompare("Authorization") == .orderedSame
                || $0.caseInsensitiveCompare("X-CSRF-Token") == .orderedSame
        }
    }
}
