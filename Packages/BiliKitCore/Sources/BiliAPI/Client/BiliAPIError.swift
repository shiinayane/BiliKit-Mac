public enum BiliAPIError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRequest
    case authorizationRequired
    case transportFailure
    case httpStatus(Int)
    case responseTooLarge(Int)
    case nonJSONResponse
    case nonProtobufResponse
    case decodingFailed
    case apiRejected(code: Int, message: String)
    case missingData
    case invalidWBIKey
    case signingFailed
    case invalidMediaData
    case invalidSubtitleData
    case untrustedSubtitleOrigin
    case invalidDanmakuData
    case noAVCVideo
    case noAACAudio

    public var description: String {
        switch self {
        case .invalidRequest:
            "invalid-request"
        case .authorizationRequired:
            "authorization-required"
        case .transportFailure:
            "transport-failure"
        case let .httpStatus(status):
            "http-status-\(status)"
        case let .responseTooLarge(size):
            "response-too-large-\(size)"
        case .nonJSONResponse:
            "non-json-response"
        case .nonProtobufResponse:
            "non-protobuf-response"
        case .decodingFailed:
            "decoding-failed"
        case let .apiRejected(code, _):
            "api-rejected-\(code)"
        case .missingData:
            "missing-data"
        case .invalidWBIKey:
            "invalid-wbi-key"
        case .signingFailed:
            "signing-failed"
        case .invalidMediaData:
            "invalid-media-data"
        case .invalidSubtitleData:
            "invalid-subtitle-data"
        case .untrustedSubtitleOrigin:
            "untrusted-subtitle-origin"
        case .invalidDanmakuData:
            "invalid-danmaku-data"
        case .noAVCVideo:
            "no-avc-video"
        case .noAACAudio:
            "no-aac-audio"
        }
    }
}
