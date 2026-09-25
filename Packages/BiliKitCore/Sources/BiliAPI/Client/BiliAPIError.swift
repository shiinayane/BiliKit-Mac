import BiliNetworking

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
    /// `code` 为 0 但 `data` 只有 `v_voucher`：WBI 签名缺失／错误或风控时的挑战响应。
    case riskControlVoucher
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
        case .riskControlVoucher:
            "risk-control-voucher"
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

extension BiliAPIError {
    /// Repository adapter 共用的失败分类。
    ///
    /// 哪些远端结果算风控、传输或响应异常只在这里决定；各域只把分类对应到自己的 Application 错误。
    enum Failure: Sendable, Equatable {
        case invalidRequest
        case authorizationRequired
        case authenticationInvalid
        case authorizationUnavailable
        case transport
        /// 403/412 以外、非 2xx 的 HTTP 状态。
        case unexpectedHTTPStatus
        /// HTTP 403/412、业务 -352/-403/-412、`v_voucher` 挑战，以及 HTML 风控页等非预期格式的正文。
        case restricted
        case rejected(code: Int)
        case unsupportedMedia
        case noPlayableMedia
        case invalidResponse
    }

    init(_ error: HTTPClientError) {
        switch error {
        case .unacceptableStatusCode(let status):
            self = .httpStatus(status)
        case .nonHTTPResponse:
            self = .transportFailure
        }
    }

    var failure: Failure {
        switch self {
        case .invalidRequest:
            .invalidRequest
        case .authorizationRequired:
            .authorizationRequired
        case .authenticationInvalid:
            .authenticationInvalid
        case .authorizationUnavailable:
            .authorizationUnavailable
        case .transportFailure:
            .transport
        case .httpStatus(403), .httpStatus(412),
            .apiRejected(code: -352, _), .apiRejected(code: -403, _),
            .apiRejected(code: -412, _), .riskControlVoucher,
            .nonJSONResponse, .nonProtobufResponse:
            .restricted
        case .httpStatus:
            .unexpectedHTTPStatus
        case .apiRejected(let code, _):
            .rejected(code: code)
        case .noAVCVideo, .noAACAudio:
            .unsupportedMedia
        case .noPlayableMedia:
            .noPlayableMedia
        case .responseTooLarge, .decodingFailed, .missingData,
            .invalidWBIKey, .signingFailed, .invalidMediaData,
            .unsupportedProgressiveMedia, .invalidSubtitleData,
            .untrustedSubtitleOrigin, .invalidDanmakuData:
            .invalidResponse
        }
    }

    /// 远端风控或限流；供没有 Application 错误域的 App 流程（线路测速）区分提示。
    public var isRiskControlRestriction: Bool { failure == .restricted }

    /// 把 adapter 捕获的错误映射为领域错误：取消原样传播，`BiliAPIError` 按 `failure` 交给
    /// 领域映射，其余错误一律为该领域的 `fallback`。
    static func domainError<DomainError: Error>(
        for error: any Error,
        fallback: DomainError,
        _ map: (Failure) -> DomainError
    ) -> any Error {
        switch error {
        case is CancellationError:
            error
        case let error as BiliAPIError:
            map(error.failure)
        default:
            fallback
        }
    }
}
