public enum BiliAPIError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRequest
    case transportFailure
    case httpStatus(Int)
    case responseTooLarge(Int)
    case nonJSONResponse
    case decodingFailed
    case apiRejected(code: Int, message: String)
    case missingData
    case invalidMediaData
    case noAVCVideo
    case noAACAudio

    public var description: String {
        switch self {
        case .invalidRequest:
            "invalid-request"
        case .transportFailure:
            "transport-failure"
        case let .httpStatus(status):
            "http-status-\(status)"
        case let .responseTooLarge(size):
            "response-too-large-\(size)"
        case .nonJSONResponse:
            "non-json-response"
        case .decodingFailed:
            "decoding-failed"
        case let .apiRejected(code, _):
            "api-rejected-\(code)"
        case .missingData:
            "missing-data"
        case .invalidMediaData:
            "invalid-media-data"
        case .noAVCVideo:
            "no-avc-video"
        case .noAACAudio:
            "no-aac-audio"
        }
    }
}
