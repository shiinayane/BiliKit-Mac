import Foundation

/// 为已经通过实现方精确 allowlist 的请求临时附加认证材料。
///
/// 协议不代表任意请求都有权获得凭据；实现必须同时验证目标、方法与 endpoint 语义。
public protocol HTTPRequestAuthorizing: Sendable {
    func authorize(_ request: HTTPRequest) async throws -> HTTPRequest
}

/// 授权失败的稳定分类；调用方只能把明确的本地无凭据解释为游客状态。
public enum HTTPRequestAuthorizationFailureKind: Sendable, Equatable {
    case missingCredential
    case invalidCredential
    case unavailable
    case denied
}

/// 授权器抛出的错误必须遵守的分类接口。
///
/// `BiliAPIClient` 只按 `authorizationFailureKind` 决定匿名回退或失败，不读取具体错误类型
/// （见 SECURITY-MODEL §3）。
public protocol HTTPRequestAuthorizationFailure: Error {
    var authorizationFailureKind: HTTPRequestAuthorizationFailureKind { get }
}

/// 为绑定到某个主体的请求附加认证材料：只有本地凭据属于 `subject` 时才授权。
///
/// 与 `HTTPRequestAuthorizing` 分开，调用方必须逐请求给出预期主体，不能在不知道主体时取得凭据。主体只是不透明
/// 字符串，比对规则与主体不符时的失败分类由实现决定，失败同样经 `HTTPRequestAuthorizationFailure` 分类。
public protocol HTTPSubjectBoundRequestAuthorizing: Sendable {
    func authorize(_ request: HTTPRequest, boundTo subject: String) async throws -> HTTPRequest
}

/// 签名请求的授权结果：改写后的新请求，以及它是否附带了凭据。
///
/// `carriesCredential` 决定调用方怎样解释业务码 -101：带凭据发出的请求收到它是凭据失效，匿名签名的请求收到它是
/// 「需要登录」（见 SECURITY-MODEL §3）。
public struct SignedHTTPRequest: Sendable, Equatable {
    public let request: HTTPRequest
    public let carriesCredential: Bool

    public init(request: HTTPRequest, carriesCredential: Bool) {
        self.request = request
        self.carriesCredential = carriesCredential
    }
}

/// 为必须签名的请求授权：有凭据时附加凭据再签名；本地明确没有凭据时只签名、不带凭据。
///
/// 与 `HTTPRequestAuthorizing` 分开：这类请求即使匿名也要经实现方改写，调用方不能在无凭据时把原请求直接发出。
/// 凭据失效、存储不可用与请求不合规照常以 `HTTPRequestAuthorizationFailure` 分类抛出，不降级为匿名签名。
public protocol HTTPSigningRequestAuthorizing: Sendable {
    func authorize(_ request: HTTPRequest) async throws -> SignedHTTPRequest
}
