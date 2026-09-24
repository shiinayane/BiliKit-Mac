import BiliNetworking
import Foundation

public enum BiliRequestAuthorizationError:
    HTTPRequestAuthorizationFailure, Sendable, Equatable
{
    case requestNotAllowed
    case credentialHeaderAlreadyPresent
    case missingCredential
    case expiredCredential
    case invalidCredential
    case credentialStoreUnavailable
    case validationUnavailable

    public var authorizationFailureKind: HTTPRequestAuthorizationFailureKind {
        switch self {
        case .missingCredential:
            .missingCredential
        case .expiredCredential, .invalidCredential:
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
/// 现有凭据 header 仍会再次验证。损坏或过期凭据会清除，媒体/CDN/loopback 请求无法通过此边界。
public struct BiliCredentialRequestAuthorizer: HTTPRequestAuthorizing, Sendable {
    private let store: any WebCredentialStoring
    private let httpClient: HTTPClient
    private let transportInvalidator: (@Sendable () -> Void)?
    private let allowedPaths: Set<String>

    public init(allowedPaths: Set<String>) {
        let transport = AuthenticationHTTP.makeProductionTransport()
        store = KeychainWebCredentialStore()
        httpClient = HTTPClient(transport: transport)
        transportInvalidator = { transport.invalidateAndCancel() }
        self.allowedPaths = allowedPaths
    }

    init(
        store: any WebCredentialStoring,
        allowedPaths: Set<String>,
        transport: any HTTPTransport = AuthenticationHTTP.makeProductionTransport()
    ) {
        self.store = store
        httpClient = HTTPClient(transport: transport)
        if let invalidating = transport as? any HTTPTransportInvalidating {
            transportInvalidator = { invalidating.invalidateAndCancel() }
        } else {
            transportInvalidator = nil
        }
        self.allowedPaths = allowedPaths
    }

    /// 返回附带短生命周期 Cookie header 的新请求；原请求不会被原地共享或缓存。
    public func authorize(_ request: HTTPRequest) async throws -> HTTPRequest {
        guard isAllowed(request) else {
            throw BiliRequestAuthorizationError.requestNotAllowed
        }
        guard !Self.containsCredentialHeader(request.headers) else {
            throw BiliRequestAuthorizationError.credentialHeaderAlreadyPresent
        }

        let credential: WebCredential
        do {
            guard let stored = try store.load() else {
                throw BiliRequestAuthorizationError.missingCredential
            }
            credential = stored
        } catch let error as BiliRequestAuthorizationError {
            throw error
        } catch WebCredentialStoreError.corruptCredential {
            try purgeStoredCredential()
            throw BiliRequestAuthorizationError.invalidCredential
        } catch {
            throw BiliRequestAuthorizationError.credentialStoreUnavailable
        }

        guard !credential.isExpired() else {
            try purgeStoredCredential()
            throw BiliRequestAuthorizationError.expiredCredential
        }

        var headers = request.headers
        headers["Cookie"] = credential.cookieHeader
        return HTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: request.body
        )
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
    func restoreAccountSession() async throws -> StoredAccountSessionRestoreResult {
        let authorized: HTTPRequest
        do {
            authorized = try await authorize(
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
            response = try await httpClient.send(authorized)
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
        guard case .signedIn(let identity) = result else {
            try purgeStoredCredential()
            return .signedOut(hadCredential: true)
        }
        return .signedIn(identity)
    }

    private func isAllowed(_ request: HTTPRequest) -> Bool {
        guard
            let components = URLComponents(
                url: request.url,
                resolvingAgainstBaseURL: false
            )
        else {
            return false
        }
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

    private static func containsCredentialHeader(_ headers: [String: String]) -> Bool {
        headers.keys.contains {
            $0.caseInsensitiveCompare("Cookie") == .orderedSame
                || $0.caseInsensitiveCompare("Authorization") == .orderedSame
                || $0.caseInsensitiveCompare("X-CSRF-Token") == .orderedSame
        }
    }

    private func purgeStoredCredential() throws {
        do {
            try store.delete()
        } catch {
            throw BiliRequestAuthorizationError.credentialStoreUnavailable
        }
    }
}
