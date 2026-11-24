/// 远端拒绝或拦截请求时观察到的那一种信号，随 `ContentApplicationError.requestRestricted` 交给界面。
///
/// 只是分类，不含 URL、正文、服务端 message 或请求参数；`code` 是给用户转述的固定短码，让报告能区分
/// IP 层面的拦截（HTTP 412）、指纹校验（-352）、挑战响应与代理拦截页（非 JSON）。见 SECURITY-MODEL §8。
public enum RequestRestriction: Sendable, Equatable {
    case httpStatus403
    case httpStatus412
    case serviceCode352
    case serviceCode403
    case serviceCode412
    /// `code` 为 0 但 `data` 只有 `v_voucher` 的挑战响应。
    case voucherChallenge
    /// 期望 JSON 的接口收到别的正文，例如 HTML 风控页或代理拦截页。
    case nonJSONBody
    /// 期望 protobuf 的接口收到别的正文。
    case nonProtobufBody

    /// 不本地化的固定短码，与报告和 issue 里的说法一致。
    public var code: String {
        switch self {
        case .httpStatus403: "HTTP 403"
        case .httpStatus412: "HTTP 412"
        case .serviceCode352: "-352"
        case .serviceCode403: "-403"
        case .serviceCode412: "-412"
        case .voucherChallenge: "v_voucher"
        case .nonJSONBody: "non-JSON"
        case .nonProtobufBody: "non-protobuf"
        }
    }
}
