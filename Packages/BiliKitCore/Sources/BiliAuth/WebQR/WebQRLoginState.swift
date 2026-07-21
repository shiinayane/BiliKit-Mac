public enum WebQRLoginState: Sendable, Equatable, CustomStringConvertible {
    case signedOut
    case requestingQRCode
    case awaitingScan(WebQRCode)
    case failed(WebQRLoginFailure)

    public var description: String {
        switch self {
        case .signedOut:
            "signed-out"
        case .requestingQRCode:
            "requesting-qr-code"
        case .awaitingScan:
            "awaiting-scan"
        case let .failed(failure):
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
    case serviceRejected(Int)
    case unsupportedStatus(Int)

    public var description: String {
        switch self {
        case .noActiveChallenge:
            "no-active-challenge"
        case .network:
            "network"
        case let .httpStatus(status):
            "http-status-\(status)"
        case .responseTooLarge:
            "response-too-large"
        case .nonJSONResponse:
            "non-json-response"
        case .invalidResponse:
            "invalid-response"
        case let .serviceRejected(code):
            "service-rejected-\(code)"
        case let .unsupportedStatus(code):
            "unsupported-status-\(code)"
        }
    }
}
