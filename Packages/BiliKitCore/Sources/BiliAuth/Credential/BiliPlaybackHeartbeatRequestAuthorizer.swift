import BiliModels
import BiliNetworking
import Foundation

/// 只授权自动的观看进度写入（heartbeat），并在 `BiliAuth` 内注入最小 Cookie 与 CSRF。
///
/// 请求的 method、host、path、header 集合、query 与表单字段按固定 schema 逐项校验并交叉核对，
/// 只附加 `SESSDATA`，`bili_jct` 作为表单 `csrf` 注入；不得泛化给其他写请求：用户发起的账户写入由
/// `BiliAccountWriteRequestAuthorizer` 按自己的 schema 与账户绑定授权（见 SECURITY-MODEL §3）。
public struct BiliPlaybackHeartbeatRequestAuthorizer: HTTPRequestAuthorizing,
    Sendable
{
    private static let allowedPath = "/x/click-interface/web/heartbeat"
    /// 表单正文上限：固定 schema 的字段远小于 2 KiB，超出说明请求构造有误，直接拒绝。
    private static let maximumBodySize = 2 * 1_024
    private static let userAgent = HTTPUserAgent.browserCompatible
    private static let requiredQueryNames: Set<String> = [
        "w_aid", "w_dt", "w_last_play_progress_time", "w_played_time",
        "w_real_played_time", "w_realtime", "w_start_ts", "web_location",
        "wts", "w_rid"
    ]
    private static let optionalQueryNames: Set<String> = ["w_video_duration"]
    private static let requiredBodyNames: Set<String> = [
        "start_ts", "aid", "cid", "type", "sub_type", "dt", "play_type",
        "realtime", "played_time", "real_played_time", "refer_url",
        "last_play_progress_time", "max_play_progress_time", "outer",
        "mobi_app", "device", "platform", "session"
    ]
    private static let optionalBodyNames: Set<String> = ["video_duration"]

    private typealias Support = WriteRequestAuthorizationSupport

    private let store: any AccountCredentialStoring

    public init() {
        store = KeychainAccountCredentialStore()
    }

    /// Keychain 边界；`init()` 由此接入 Keychain store。
    init(store: any AccountCredentialStoring) {
        self.store = store
    }

    public func authorize(_ request: HTTPRequest) async throws -> HTTPRequest {
        // 任一校验不通过都按 `requestNotAllowed` 拒绝，不尝试修正请求，见 SECURITY-MODEL §3。
        guard Self.isAllowedRequest(request),
            let body = request.body,
            body.count <= Self.maximumBodySize,
            let bodyString = String(data: body, encoding: .utf8),
            let bodyFields = Self.allowedBodyFields(bodyString),
            let queryFields = Self.allowedQueryFields(request.url),
            Self.matchesSignedFacts(body: bodyFields, query: queryFields),
            Self.hasMatchingReferer(request.headers, body: bodyFields)
        else {
            throw BiliRequestAuthorizationError.requestNotAllowed
        }
        guard !request.headers.containsCredentialHeader else {
            throw BiliRequestAuthorizationError.credentialHeaderAlreadyPresent
        }

        let credential = try store.loadCredential(isConfirmedSignedOut: { false })
        guard let session = credential.value(for: .session),
            let csrf = credential.value(for: .csrf),
            let encodedCSRF = Support.encodedCSRFField(csrf)
        else {
            throw BiliRequestAuthorizationError.invalidCredential
        }

        var headers = request.headers
        headers["Cookie"] = "SESSDATA=\(session)"
        return HTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: Data("\(bodyString)&\(encodedCSRF)".utf8)
        )
    }

    private static func isAllowedRequest(_ request: HTTPRequest) -> Bool {
        guard
            let components = URLComponents(
                url: request.url,
                resolvingAgainstBaseURL: false
            )
        else { return false }
        let normalizedHeaders = Dictionary(
            grouping: request.headers,
            by: { $0.key.lowercased() }
        )
        let allowedHeaderNames: Set<String> = [
            "accept", "content-type", "referer", "user-agent"
        ]
        guard Set(normalizedHeaders.keys) == allowedHeaderNames,
            normalizedHeaders.values.allSatisfy({ $0.count == 1 }),
            normalizedHeaders["accept"]?.first?.value == "application/json",
            normalizedHeaders["content-type"]?.first?.value
                == "application/x-www-form-urlencoded",
            normalizedHeaders["user-agent"]?.first?.value == userAgent
        else { return false }

        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "api.bilibili.com"
            && (components.port == nil || components.port == 443)
            && components.user == nil
            && components.password == nil
            && components.path == allowedPath
            && components.percentEncodedPath == allowedPath
            && components.percentEncodedQuery != nil
            && components.fragment == nil
            && request.method == .post
    }

    private static func allowedQueryFields(_ url: URL) -> [String: String]? {
        guard
            let encodedQuery = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.percentEncodedQuery,
            let fields = Support.decodedUniqueFields(encodedQuery)
        else { return nil }
        let names = Set(fields.keys)
        guard names.isSuperset(of: requiredQueryNames),
            names.isSubset(of: requiredQueryNames.union(optionalQueryNames)),
            Support.positiveInteger(fields["w_aid"]),
            fields["w_dt"] == "2",
            nonnegativeInteger(fields["w_last_play_progress_time"]),
            signedPlayedTime(fields["w_played_time"]),
            nonnegativeInteger(fields["w_real_played_time"]),
            nonnegativeInteger(fields["w_realtime"]),
            Support.positiveInteger(fields["w_start_ts"]),
            fields["web_location"] == "1315873",
            Support.positiveInteger(fields["wts"]),
            isLowercaseHex(fields["w_rid"], count: 32),
            fields["w_video_duration"].map(Support.positiveInteger) ?? true
        else { return nil }
        return fields
    }

    private static func allowedBodyFields(_ body: String) -> [String: String]? {
        guard let fields = Support.decodedUniqueFields(body) else { return nil }
        let names = Set(fields.keys)
        guard names.isSuperset(of: requiredBodyNames),
            names.isSubset(of: requiredBodyNames.union(optionalBodyNames)),
            Support.positiveInteger(fields["start_ts"]),
            Support.positiveInteger(fields["aid"]),
            Support.positiveInteger(fields["cid"]),
            fields["type"] == "3",
            fields["sub_type"] == "0",
            fields["dt"] == "2",
            let playType = Support.integer(fields["play_type"]),
            (0...4).contains(playType),
            nonnegativeInteger(fields["realtime"]),
            signedPlayedTime(fields["played_time"]),
            nonnegativeInteger(fields["real_played_time"]),
            nonnegativeInteger(fields["last_play_progress_time"]),
            nonnegativeInteger(fields["max_play_progress_time"]),
            fields["outer"] == "0",
            fields["mobi_app"] == "web",
            fields["device"] == "web",
            fields["platform"] == "web",
            isLowercaseHex(fields["session"], count: 32),
            fields["video_duration"].map(Support.positiveInteger) ?? true,
            let played = Support.integer(fields["played_time"]),
            played != -1 || playType == 4,
            let position = Support.integer(fields["last_play_progress_time"]),
            let maximum = Support.integer(fields["max_play_progress_time"]),
            maximum >= position,
            let realtime = Support.integer(fields["realtime"]),
            let realPlayed = Support.integer(fields["real_played_time"]),
            realtime >= realPlayed
        else { return nil }
        return fields
    }

    /// query 里经 WBI 签名的 `w_*` 字段必须与表单对应字段逐一相等（含可选的视频时长），
    /// 签名与实际上报的事实不能不一致。
    private static func matchesSignedFacts(
        body: [String: String],
        query: [String: String]
    ) -> Bool {
        let mirrors = [
            ("aid", "w_aid"),
            ("dt", "w_dt"),
            ("last_play_progress_time", "w_last_play_progress_time"),
            ("played_time", "w_played_time"),
            ("real_played_time", "w_real_played_time"),
            ("realtime", "w_realtime"),
            ("start_ts", "w_start_ts")
        ]
        return mirrors.allSatisfy { body[$0.0] == query[$0.1] }
            && body["video_duration"] == query["w_video_duration"]
    }

    /// Referer 必须与表单 `refer_url` 相同，且是不带 query 的
    /// `https://www.bilibili.com/video/BV…/`。
    private static func hasMatchingReferer(
        _ headers: [String: String],
        body: [String: String]
    ) -> Bool {
        guard
            let header = headers.first(where: {
                $0.key.caseInsensitiveCompare("Referer") == .orderedSame
            })?.value,
            header == body["refer_url"],
            let components = URLComponents(string: header)
        else { return false }
        let pathParts = components.path.split(separator: "/")
        return components.scheme == "https"
            && components.host == "www.bilibili.com"
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
            && components.percentEncodedPath == components.path
            && header.hasSuffix("/")
            && pathParts.count == 2
            && pathParts[0] == "video"
            && BVID.isValid(String(pathParts[1]))
    }

    private static func nonnegativeInteger(_ value: String?) -> Bool {
        (Support.integer(value) ?? -1) >= 0
    }

    private static func signedPlayedTime(_ value: String?) -> Bool {
        guard let number = Support.integer(value) else { return false }
        return number >= -1
    }

    /// 按 UTF-8 字节判断：只有 ASCII `0-9a-f` 才合法；`Character.isNumber` 会放过阿拉伯-印度数字、全角数字与 `½`，
    /// 带组合符的字母按字符比较也会落进 `a...f`。
    private static func isLowercaseHex(_ value: String?, count: Int) -> Bool {
        guard let value, value.utf8.count == count else { return false }
        return value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
