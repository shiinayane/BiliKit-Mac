import BiliNetworking
import Foundation

/// 只授权用户发起的账户写入（稍后再看的加入与移除、收藏到收藏夹与从收藏夹移除、点赞、投币、三连，以及首页推荐的
/// 「不感兴趣」与撤销），并在 `BiliAuth` 内绑定账户、注入最小 Cookie 与 CSRF。
///
/// 每个请求必须精确命中：`https://api.bilibili.com`（端口缺省或 443）、POST、无 query／userinfo／fragment、path 同时在
/// Composition 声明的 allowlist 与本类型封闭的 schema 表里；header 集合固定为 `Accept`、`Content-Type`、`Origin`、
/// `Referer`、`User-Agent`，取值逐项相等，Referer 是该 path 规定的固定地址；表单不超过 `maximumBodySize`，字段名
/// 恰为 schema 的必需字段加可选字段的子集，取值形状逐项校验，再查字段之间的约束。调用方自带 `csrf`、Cookie 等凭据类字段或 header 的请求
/// 都不在 schema 内，一律拒绝。任一校验不通过都按 `requestNotAllowed`（客户端编程错误）拒绝，不尝试修正请求。
///
/// 每次授权都重新读 Keychain、不缓存：凭据的 `DedeUserID` 必须等于调用方给出的预期账户（`boundTo`），不符时按凭据失效
/// （`accountMismatch`）拒绝但不删除凭据，因为那多半是本窗口的账户范围过期、Keychain 里已是另一窗口登录的新账户。
/// Cookie 只放该 path 白名单里的项（目前只有 `SESSDATA`），`bili_jct` 只作为表单 `csrf` 拼在末尾。与观看进度的
/// `BiliPlaybackHeartbeatRequestAuthorizer` 相互独立，新增写操作在 schema 表里逐条登记，不泛化（见 SECURITY-MODEL §3）。
public struct BiliAccountWriteRequestAuthorizer: HTTPSubjectBoundRequestAuthorizing, Sendable {
    /// 一个写 path 的封闭表单 schema：必需与可选字段及其取值形状、字段之间的约束、固定 Referer 与要发送的 Cookie。
    struct Schema: Sendable {
        let requiredFields: [String: FieldShape]
        let optionalFields: [String: FieldShape]
        var crossFieldRules: [CrossFieldRule] = []
        let referer: String
        /// 按 path 列出的凭据 Cookie 白名单；点赞、投币与三连要求的 `buvid3` 不是凭据，不在这里，由 BiliAPI 在授权之后附加。
        let cookieNames: [WebCredentialCookieName]
    }

    /// 字段之间的约束，在逐字段的形状都通过之后检查。
    enum CrossFieldRule: Sendable {
        /// 两个夹 id 列表（`positiveIntegerList`）至少一个非空，且没有共同的 id：一次改动必须真有改动，同一个夹不能
        /// 既加入又移出（服务端先做哪一侧不可知）。
        case disjointNonEmptyLists(String, String)

        func accepts(_ fields: [String: String]) -> Bool {
            switch self {
            case .disjointNonEmptyLists(let first, let second):
                let firstIDs = Set(
                    (fields[first] ?? "").split(separator: ",", omittingEmptySubsequences: true)
                )
                let secondIDs = Set(
                    (fields[second] ?? "").split(separator: ",", omittingEmptySubsequences: true)
                )
                return !(firstIDs.isEmpty && secondIDs.isEmpty)
                    && firstIDs.isDisjoint(with: secondIDs)
            }
        }
    }

    /// 字段取值的形状。
    enum FieldShape: Sendable {
        /// 正整数（稿件 aid、收藏夹 id 等），只由 ASCII 数字组成、没有前导零：同一个数只有一种写法，去重与比较按字面进行。
        case positiveInteger
        /// 固定取值（`type=2`、`platform=web`）。
        case literal(String)
        /// 几个固定取值之一（`like=1|2`、`multiply=1|2`、`select_like=0|1`）。
        case oneOf(Set<String>)
        /// 逗号分隔、互不重复的正整数，可以为空串（`fav/resource/deal` 没有要加入或移出的夹时那一侧传空串）；最多
        /// `maximumListCount` 个。
        case positiveIntegerList
        /// 单个视频条目 `<aid>:2`：不收逗号分隔的多个条目，也不收视频以外的类型。
        case singleVideoResource
        /// 推荐流的追踪 ID（`track_id`）：1 到 `maximumTrackingTokenLength` 个 ASCII 字母、数字与 `.`、`_`、`-`。
        case trackingToken

        /// 一次收藏改动最多涉及的收藏夹数：远多于一个账户实际拥有的夹数，超出说明请求构造有误。
        static let maximumListCount = 100
        /// 追踪 ID 的长度上限：网页实测的推荐流取值远短于它，超出说明取值不是推荐流给的。
        static let maximumTrackingTokenLength = 200

        func accepts(_ value: String) -> Bool {
            switch self {
            case .positiveInteger:
                Self.isPositiveInteger(value)
            case .literal(let expected):
                value == expected
            case .oneOf(let allowed):
                allowed.contains(value)
            case .positiveIntegerList:
                Self.isPositiveIntegerList(value)
            case .singleVideoResource:
                Self.isSingleVideoResource(value)
            case .trackingToken:
                (1...Self.maximumTrackingTokenLength).contains(value.count)
                    && value.allSatisfy {
                        $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0))
                    }
            }
        }

        private static func isPositiveInteger<S: StringProtocol>(_ value: S) -> Bool {
            value.first != "0"
                && value.allSatisfy { $0.isASCII && $0.isNumber }
                && WriteRequestAuthorizationSupport.positiveInteger(String(value))
        }

        private static func isPositiveIntegerList(_ value: String) -> Bool {
            guard !value.isEmpty else { return true }
            let items = value.split(separator: ",", omittingEmptySubsequences: false)
            return items.count <= maximumListCount
                && Set(items).count == items.count
                && items.allSatisfy { isPositiveInteger($0) }
        }

        private static func isSingleVideoResource(_ value: String) -> Bool {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            return parts.count == 2 && isPositiveInteger(parts[0]) && parts[1] == "2"
        }
    }

    /// 全部可授权的写 path 与它们的 schema；path 字面量与 BiliAPI 的 `BiliAccountWritePath` 相同（BiliAuth 不能依赖
    /// BiliAPI，Composition 的测试核对两边一致）。
    ///
    /// 稍后再看移除用单条接口 `toview/del`（urlencoded、不签 WBI）：它有接口文档、多个第三方客户端在用，表单只有
    /// aid 与 csrf。它的 `aid` 在文档里是可选的，带 `viewed=true` 时会删除全部已看完的视频；这里强制要求 `aid` 且不收
    /// `viewed`，挡住的正是“一次清空”，不能把 `aid` 改成可选或放进 `viewed`。
    ///
    /// 实机失效时的后备：
    /// 1. urlencoded、不签 WBI 的 `toview/v2/dels`：加一行 schema，必需字段 `resources`，取值形状 `.positiveInteger`
    ///    （只收单个 aid，不收逗号分隔的批量），Referer 与 Cookie 同 `toview/del`。
    /// 2. 网页实际的 WBI 签名 + multipart：本类型目前把 `Content-Type` 固定为 urlencoded、csrf 以 `&csrf=` 拼在 urlencoded
    ///    正文末尾、要求没有 query，写管线 `postForm` 也只编码 urlencoded 且不经 `signedRequest`。换用它要给 schema 加正文
    ///    格式维度，封闭校验 multipart 的 boundary 与各 part，把 csrf 注入为单独的 part，并像 heartbeat 授权器那样校验签名
    ///    query（`w_rid`／`wts` 的形状），写管线另要取 WBI key 签名；不能放宽成接受任意正文或 query。
    ///
    /// 收藏只登记两条：`fav/resource/deal` 一次改一个视频在若干收藏夹里的归属（`rid` 单个、`type` 固定为视频），
    /// `fav/resource/batch-del` 从一个收藏夹移除一个视频条目（`resources` 只收单个 `<aid>:2`，挡住一次移除多条）。
    /// 网页附带的 `spmid`、`statistics` 等统计字段不发送，schema 也不接受。
    ///
    /// 点赞、投币与三连各一条，只收单个稿件：点赞 `like` 只能是 1（赞）或 2（取消）；投币 `multiply` 只能是 1 或 2（单个
    /// 稿件的上限），`select_like` 0 或 1；三连只有 `aid`。网页同样附带的统计字段与 `cross_domain` 不发送。这三个接口
    /// 要求 Cookie 带 `buvid3`，它不是凭据、不在这里注入，由 BiliAPI 在授权之后附加（见 SECURITY-MODEL §3）。
    ///
    /// 关注只登记 `relation/modify` 的关注与取消：`fid` 单个 UP 主，`act` 只能是 1（关注）或 2（取消），`re_src` 固定为
    /// 11。同一接口的其他 `act`（悄悄关注、拉黑、移除粉丝等）改动的是另一种关系，一律拒绝；网页附带的 `gaia_source`、
    /// `spmid`、`extend_content` 不发送，schema 也不接受。
    ///
    /// 首页推荐的「不感兴趣」与撤销字段完全相同、共用 `recommendationFeedbackSchema`：只收单个稿件与它的 UP 主 `mid`
    /// （推荐流的普通视频总有 UP 主，0 只会是构造有误），`reason_id` 只能是 1（内容不感兴趣）或 4（不想看此 UP 主），其余
    /// 是网页固定发送的取值。网页对这两个接口签 WBI，这里不签（多个第三方
    /// 客户端不签也能用）；实机被拒时再给 schema 加签名 query 维度并封闭校验 `w_rid`／`wts`，不能放宽成接受任意 query。
    static let schemas: [String: Schema] = [
        "/x/web-interface/feedback/dislike": recommendationFeedbackSchema,
        "/x/web-interface/feedback/dislike/cancel": recommendationFeedbackSchema,
        "/x/v2/history/toview/add": Schema(
            requiredFields: ["aid": .positiveInteger],
            optionalFields: [:],
            referer: "https://www.bilibili.com/",
            cookieNames: [.session]
        ),
        "/x/v2/history/toview/del": Schema(
            requiredFields: ["aid": .positiveInteger],
            optionalFields: [:],
            referer: "https://www.bilibili.com/watchlater/",
            cookieNames: [.session]
        ),
        "/x/v3/fav/resource/deal": Schema(
            requiredFields: [
                "rid": .positiveInteger,
                "type": .literal("2"),
                "add_media_ids": .positiveIntegerList,
                "del_media_ids": .positiveIntegerList,
                "platform": .literal("web")
            ],
            optionalFields: [:],
            crossFieldRules: [.disjointNonEmptyLists("add_media_ids", "del_media_ids")],
            referer: "https://www.bilibili.com/",
            cookieNames: [.session]
        ),
        "/x/web-interface/archive/like": Schema(
            requiredFields: ["aid": .positiveInteger, "like": .oneOf(["1", "2"])],
            optionalFields: [:],
            referer: "https://www.bilibili.com/",
            cookieNames: [.session]
        ),
        "/x/web-interface/coin/add": Schema(
            requiredFields: [
                "aid": .positiveInteger,
                "multiply": .oneOf(["1", "2"]),
                "select_like": .oneOf(["0", "1"])
            ],
            optionalFields: [:],
            referer: "https://www.bilibili.com/",
            cookieNames: [.session]
        ),
        "/x/web-interface/archive/like/triple": Schema(
            requiredFields: ["aid": .positiveInteger],
            optionalFields: [:],
            referer: "https://www.bilibili.com/",
            cookieNames: [.session]
        ),
        "/x/relation/modify": Schema(
            requiredFields: [
                "fid": .positiveInteger,
                "act": .oneOf(["1", "2"]),
                "re_src": .literal("11")
            ],
            optionalFields: [:],
            referer: "https://www.bilibili.com/",
            cookieNames: [.session]
        ),
        "/x/v3/fav/resource/batch-del": Schema(
            requiredFields: [
                "resources": .singleVideoResource,
                "media_id": .positiveInteger,
                "platform": .literal("web")
            ],
            optionalFields: [:],
            referer: "https://www.bilibili.com/",
            cookieNames: [.session]
        )
    ]

    /// 「不感兴趣」与撤销共用的 schema，见 `schemas` 的说明。
    private static let recommendationFeedbackSchema = Schema(
        requiredFields: [
            "app_id": .literal("100"),
            "platform": .literal("5"),
            "from_spmid": .literal(""),
            "spmid": .literal("333.1007.0.0"),
            "goto": .literal("av"),
            "id": .positiveInteger,
            "mid": .positiveInteger,
            "track_id": .trackingToken,
            "feedback_page": .literal("1"),
            "reason_id": .oneOf(["1", "4"])
        ],
        optionalFields: [:],
        referer: "https://www.bilibili.com/",
        cookieNames: [.session]
    )

    /// 写请求固定的 `Origin`：浏览器跨域 POST 会带它，B 站据此与 Referer 一起判断来源。
    static let origin = "https://www.bilibili.com"
    /// 表单正文上限：最长的收藏改动带两列各至多 `FieldShape.maximumListCount` 个夹 id（写管线不编码逗号，按 19 位 id
    /// 计约 4 KB），仍在 4 KiB 以内；超出说明请求构造有误，直接拒绝。
    private static let maximumBodySize = 4_096
    private typealias Support = WriteRequestAuthorizationSupport

    private let store: any WebCredentialStoring
    private let allowedPaths: Set<String>

    /// `allowedPaths` 由 Composition 声明（窗口主 API 的写 allowlist），只有同时在 schema 表里的 path 可授权。
    public init(allowedPaths: Set<String>) {
        store = KeychainWebCredentialStore()
        self.allowedPaths = allowedPaths
    }

    /// Keychain 边界；`init(allowedPaths:)` 由此接入 Keychain store。
    init(store: any WebCredentialStoring, allowedPaths: Set<String>) {
        self.store = store
        self.allowedPaths = allowedPaths
    }

    /// `subject` 是窗口账户的 mid（十进制正整数）；返回附带短生命周期 Cookie 与 csrf 的新请求，原请求不被修改或缓存。
    public func authorize(
        _ request: HTTPRequest,
        boundTo subject: String
    ) async throws -> HTTPRequest {
        guard Support.positiveInteger(subject), subject.allSatisfy({ $0.isASCII && $0.isNumber }),
            let schema = schema(for: request),
            let body = request.body,
            body.count <= Self.maximumBodySize,
            let bodyString = String(data: body, encoding: .utf8),
            Self.matches(bodyString, schema: schema),
            Self.hasExactHeaders(request.headers, referer: schema.referer)
        else {
            throw BiliRequestAuthorizationError.requestNotAllowed
        }

        let credential = try store.loadCredentialForWrite()
        // 账户绑定：窗口以为的账户与 Keychain 里的凭据不是同一个时不发出写请求，见 SECURITY-MODEL §3。
        guard credential.value(for: .userID) == subject else {
            throw BiliRequestAuthorizationError.accountMismatch
        }
        let cookies = schema.cookieNames.map { name in
            credential.value(for: name).map { "\(name.rawValue)=\($0)" }
        }
        guard let csrf = credential.value(for: .csrf),
            let encodedCSRF = Support.encodedCSRFField(csrf),
            cookies.allSatisfy({ $0 != nil })
        else {
            throw BiliRequestAuthorizationError.invalidCredential
        }

        var headers = request.headers
        headers["Cookie"] = cookies.compactMap(\.self).joined(separator: "; ")
        return HTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: Data("\(bodyString)&\(encodedCSRF)".utf8)
        )
    }

    /// 目标精确、方法为 POST 且 path 同时在 allowlist 与 schema 表里时返回该 path 的 schema。
    private func schema(for request: HTTPRequest) -> Schema? {
        guard
            let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            components.host?.lowercased() == "api.bilibili.com",
            components.port == nil || components.port == 443,
            components.user == nil,
            components.password == nil,
            components.percentEncodedPath == components.path,
            components.percentEncodedQuery == nil,
            components.fragment == nil,
            request.method == .post,
            allowedPaths.contains(components.path)
        else { return nil }
        return Self.schemas[components.path]
    }

    private static func matches(_ body: String, schema: Schema) -> Bool {
        guard let fields = Support.decodedUniqueFields(body) else { return false }
        let names = Set(fields.keys)
        let required = Set(schema.requiredFields.keys)
        guard names.isSuperset(of: required),
            names.isSubset(of: required.union(schema.optionalFields.keys))
        else { return false }
        return fields.allSatisfy { name, value in
            (schema.requiredFields[name] ?? schema.optionalFields[name])?.accepts(value) ?? false
        } && schema.crossFieldRules.allSatisfy { $0.accepts(fields) }
    }

    private static func hasExactHeaders(_ headers: [String: String], referer: String) -> Bool {
        let normalized = Dictionary(grouping: headers, by: { $0.key.lowercased() })
        let expected: [String: String] = [
            "accept": "application/json",
            "content-type": "application/x-www-form-urlencoded",
            "origin": origin,
            "referer": referer,
            "user-agent": HTTPUserAgent.browserCompatible
        ]
        guard Set(normalized.keys) == Set(expected.keys) else { return false }
        return expected.allSatisfy { name, value in
            normalized[name]?.count == 1 && normalized[name]?.first?.value == value
        }
    }
}
