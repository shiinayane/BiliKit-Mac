import BiliModels

/// 已经确认的账户会话事实；认证操作进行中不会把原有事实降级为未登录。
public enum AccountSessionState: Sendable, Equatable {
    case unresolved
    case signedOut
    case signedIn(AccountIdentity?)
}

/// Feature 可观察的非秘密认证状态；不携带二维码 payload、Cookie 或 Keychain 细节。
public enum AuthenticationState: Sendable, Equatable {
    case signedOut
    case restoring
    case requestingQRCode
    case awaitingScan
    case awaitingConfirmation
    case finalizing
    case signedIn(AccountIdentity?)
    case signingOut
    case expired
    case failed(AuthenticationFailure)
}

public enum AuthenticationFailure: Error, Sendable, Equatable {
    case network
    case serviceUnavailable
    case invalidResponse
    case credentialUnavailable
}

/// 认证 adapter 暴露给 Presentation 的用户意图边界。
///
/// 每次调用返回 adapter 的当前安全投影；调用方仍负责 UI Task 的取消与迟到结果隔离。
public protocol AuthenticationServicing: Sendable {
    func restore() async -> AuthenticationState
    func requestQRCode() async -> AuthenticationState
    func pollOnce() async -> AuthenticationState
    func finalizeLogin() async -> AuthenticationState
    func cancelLogin() async -> AuthenticationState
    func logout() async -> AuthenticationState
}

/// 登出时由认证 owner 通知仍可能持有已授权在途请求的会话。
public protocol AuthenticatedSessionInvalidating: Sendable {
    func invalidateAuthenticatedSession() async
}
