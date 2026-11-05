import BiliNetworking

/// `BiliAPI` 的远端与请求失败；adapter 只经 `failure` 分类后映射为各域 Application 错误。
///
/// 分类规则见下方 `Failure` 与 docs/ARCHITECTURE.md「模块与依赖方向」的补充规则。`description`
/// 只含阶段与分类，不含 URL、正文或服务端 message（见 SECURITY-MODEL §8）。
public enum BiliAPIError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 参数或请求形状不合规，或授权器拒绝（path 不在 allowlist）：客户端编程错误，不发出该请求。
    case invalidRequest
    /// 需要登录：例如只按账户读取的请求遇到本地明确无凭据（含未注入授权器），或匿名请求收到 -101。
    case authorizationRequired
    /// 凭据失效：带凭据发出的请求收到 -101，或授权器判定本地凭据损坏、过期；
    /// 内容等域据此触发账户复核。
    case authenticationInvalid
    /// 本地凭据读不到（Keychain 不可用）或授权器抛出未分类错误；不触发复核。
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
    case noSupportedVideo
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
        case .noSupportedVideo:
            "no-supported-video"
        case .noAACAudio:
            "no-aac-audio"
        }
    }
}

/// progressive（durl）播放地址不可用的原因，随 `unsupportedProgressiveMedia` 抛出；`rawValue` 只进
/// `description`。
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
        /// 业务码表明请求的内容不存在、已删除或对当前身份不可见（-404、62002、62004）；重试不会改变结果。
        case contentUnavailable(code: Int)
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
        case .apiRejected(let code, _) where Self.contentUnavailableCodes.contains(code):
            .contentUnavailable(code: code)
        case .apiRejected(let code, _):
            .rejected(code: code)
        case .noSupportedVideo, .noAACAudio:
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

    /// 内容不存在或不可见的业务码：-404 资源不存在，62002 稿件不可见，62004 稿件审核中。
    private static let contentUnavailableCodes: Set<Int> = [-404, 62_002, 62_004]

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
