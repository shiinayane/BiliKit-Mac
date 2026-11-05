/// QR adapter 的内部安全状态投影；描述不包含 key、URL、Cookie 或服务端正文。
public enum TVQRLoginState: Sendable, Equatable, CustomStringConvertible {
    case signedOut
    case requestingQRCode
    case awaitingScan(TVQRCode)
    case awaitingConfirmation(TVQRCode)
    case awaitingCredentialValidation
    case expired
    case failed(TVQRLoginFailure)

    public var description: String {
        switch self {
        case .signedOut:
            "signed-out"
        case .requestingQRCode:
            "requesting-qr-code"
        case .awaitingScan:
            "awaiting-scan"
        case .awaitingConfirmation:
            "awaiting-confirmation"
        case .awaitingCredentialValidation:
            "awaiting-credential-validation"
        case .expired:
            "expired"
        case .failed(let failure):
            "failed-\(failure.description)"
        }
    }
}

/// QR 登录各阶段的失败分类；只含状态码与业务码，不含服务端正文，由认证服务映射为
/// `AuthenticationFailure`。
public enum TVQRLoginFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case noActiveChallenge
    case network
    case httpStatus(Int)
    case responseTooLarge
    case nonJSONResponse
    case invalidResponse
    case incompleteCredential
    case credentialStoreUnavailable
    case serviceRejected(Int)
    case unsupportedStatus(Int)

    public var description: String {
        switch self {
        case .noActiveChallenge:
            "no-active-challenge"
        case .network:
            "network"
        case .httpStatus(let status):
            "http-status-\(status)"
        case .responseTooLarge:
            "response-too-large"
        case .nonJSONResponse:
            "non-json-response"
        case .invalidResponse:
            "invalid-response"
        case .incompleteCredential:
            "incomplete-credential"
        case .credentialStoreUnavailable:
            "credential-store-unavailable"
        case .serviceRejected(let code):
            "service-rejected-\(code)"
        case .unsupportedStatus(let code):
            "unsupported-status-\(code)"
        }
    }
}
