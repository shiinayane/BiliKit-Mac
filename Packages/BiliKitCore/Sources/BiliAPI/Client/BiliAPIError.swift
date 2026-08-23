public enum BiliAPIError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRequest
    case authorizationRequired
    case authenticationInvalid
    case authorizationUnavailable
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
    case unsupportedProgressiveMedia(ProgressiveMediaFailure)
    case noPlayableMedia
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
        case .authenticationInvalid:
            "authentication-invalid"
        case .authorizationUnavailable:
            "authorization-unavailable"
        case .transportFailure:
            "transport-failure"
        case .httpStatus(let status):
            "http-status-\(status)"
        case .responseTooLarge(let size):
            "response-too-large-\(size)"
        case .nonJSONResponse:
            "non-json-response"
        case .nonProtobufResponse:
            "non-protobuf-response"
        case .decodingFailed:
            "decoding-failed"
        case .apiRejected(let code, _):
            "api-rejected-\(code)"
        case .missingData:
            "missing-data"
        case .invalidWBIKey:
            "invalid-wbi-key"
        case .signingFailed:
            "signing-failed"
        case .invalidMediaData:
            "invalid-media-data"
        case .unsupportedProgressiveMedia(let failure):
            "unsupported-progressive-media-\(failure.rawValue)"
        case .noPlayableMedia:
            "no-playable-media"
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

public enum ProgressiveMediaFailure: String, Sendable, Equatable {
    case empty
    case multipleSegments
    case invalidDuration
    case invalidSize
    case noSafeURL
    case unsupportedContainer
}
