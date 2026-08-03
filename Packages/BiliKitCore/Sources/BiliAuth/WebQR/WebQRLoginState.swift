/// QR adapter 的内部安全状态投影；描述不包含 key、URL、Cookie 或服务端正文。
public enum WebQRLoginState: Sendable, Equatable, CustomStringConvertible {
    case signedOut
    case requestingQRCode
    case awaitingScan(WebQRCode)
    case awaitingConfirmation(WebQRCode)
    case awaitingCredentialValidation(WebQRStatusObservation)
    case expired
    case failed(WebQRLoginFailure)

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

public enum WebQRLoginFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case noActiveChallenge
    case network
    case httpStatus(Int)
    case responseTooLarge
    case nonJSONResponse
    case invalidResponse
    case incompleteCredential
    case credentialStoreUnavailable
    case serviceRejected(Int)
    case unsupportedStatus(WebQRStatusObservation)

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
        case .unsupportedStatus(let observation):
            "unsupported-status-\(observation.code)"
        }
    }
}

/// 只保留协议形状的脱敏观察，用于审计未知状态，不保存任何字段值。
public struct WebQRStatusObservation: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let code: Int
    public let dataFieldNames: [String]
    public let urlScheme: String?
    public let urlHost: String?
    public let urlQueryNames: [String]
    public let refreshTokenPresent: Bool
    public let responseHeaderNames: [String]
    public let cookieNames: [String]
    public let cookieAttributeNames: [String]
    public let cookies: [WebQRCookieObservation]

    public var description: String {
        "<web-qr-status-\(code)-observation>"
    }

    public var debugDescription: String {
        description
    }
}

public struct WebQRCookieObservation: Sendable, Equatable {
    public let name: String
    public let domain: String
    public let path: String
    public let isSecure: Bool
    public let isHTTPOnly: Bool
    public let isSessionOnly: Bool
    public let hasExpiry: Bool
}
