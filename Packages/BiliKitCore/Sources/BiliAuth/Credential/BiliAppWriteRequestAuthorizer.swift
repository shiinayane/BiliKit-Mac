import BiliNetworking
import Foundation

/// 只授权用户发起的 App 端（`https://app.bilibili.com`）写入（首页推荐的「不感兴趣」与撤销，播放页的点赞、投币与三连）：
/// 绑定账户后附加 access_token 并做 APP 签名。
///
/// App 端的写入凭据与签名都在 query 或表单里（「不感兴趣」是 GET，点赞、投币、三连是 POST 表单），不带 Cookie、csrf 与
/// Referer，所以与网页写入的 `BiliAccountWriteRequestAuthorizer`（POST 表单、Cookie 与 csrf）分开；与 App 读取的
/// `BiliAppRequestAuthorizer` 也分开：写入从不匿名签名，本地无凭据就失败。每个请求必须精确命中 host、端口与 schema 规定的
/// 方法，path 同时在 Composition 声明的 allowlist 与本类型封闭的 schema 表里，字段恰为 schema 的字段且取值形状逐项通过；
/// 调用方自带凭据 header 或 `access_key`、签名等保留参数一律拒绝。任一校验不通过都按 `requestNotAllowed`（客户端编程错误）
/// 拒绝，不尝试修正请求。
///
/// 每次授权都重新读 Keychain、不缓存：凭据的 `DedeUserID` 必须等于调用方给出的预期账户（`boundTo`），不符时按凭据失效
/// （`accountMismatch`）拒绝但不删除凭据，理由同网页写入。新增写操作在 schema 表里逐条登记，不泛化（见
/// SECURITY-MODEL §3）。无状态。
public struct BiliAppWriteRequestAuthorizer: HTTPSubjectBoundRequestAuthorizing, Sendable {
    private typealias FieldShape = BiliAccountWriteRequestAuthorizer.FieldShape

    /// 一个 App 写 path 的方法与封闭字段：GET 的字段在 query 里，POST 的在 urlencoded 正文里。
    private struct Schema: Sendable {
        let method: HTTPMethod
        let fields: [String: FieldShape]
    }

    /// 全部可授权的 App 写 path 与它们的 schema；path 字面量与 BiliAPI 的 `BiliAppWritePath` 相同（BiliAuth 不能依赖
    /// BiliAPI，Composition 的测试核对两边一致）。
    ///
    /// - 「不感兴趣」与撤销字段完全相同：只收单个稿件（`goto` 固定为 av，`id` 是 aid）与卡片给出的一个 `reason_id`；
    ///   `mobi_app`、`device`、`build` 与首页推荐请求的客户端身份一致。卡片里另有一组「反馈」（举报类，以 `feedback_id`
    ///   发送），不提供，schema 也不接受。
    /// - 点赞只收单个 aid 与 `like`（App 端 0 是点赞、1 是取消，与网页相反）；投币只收 1 或 2 枚与是否同时点赞；三连只收
    ///   aid。三者都只带实测成功的最少字段，不带客户端身份。
    private static let schemas: [String: Schema] = [
        "/x/feed/dislike": Schema(method: .get, fields: recommendationFeedbackFields),
        "/x/feed/dislike/cancel": Schema(method: .get, fields: recommendationFeedbackFields),
        "/x/v2/view/like": Schema(
            method: .post,
            fields: ["aid": .positiveInteger, "like": .oneOf(["0", "1"])]
        ),
        "/x/v2/view/coin/add": Schema(
            method: .post,
            fields: [
                "aid": .positiveInteger,
                "multiply": .oneOf(["1", "2"]),
                "select_like": .oneOf(["0", "1"])
            ]
        ),
        "/x/v2/view/like/triple": Schema(method: .post, fields: ["aid": .positiveInteger])
    ]

    private static let recommendationFeedbackFields: [String: FieldShape] = [
        "goto": .literal("av"),
        "id": .positiveInteger,
        "reason_id": .positiveInteger,
        "mobi_app": .literal("iphone"),
        "device": .literal("pad"),
        "build": .literal("1")
    ]

    private let store: any AccountCredentialStoring
    private let allowedPaths: Set<String>

    /// `allowedPaths` 由 Composition 声明（窗口主 API 的 App 写 allowlist），只有同时在 schema 表里的 path 可授权。
    public init(allowedPaths: Set<String>) {
        store = KeychainAccountCredentialStore()
        self.allowedPaths = allowedPaths
    }

    /// Keychain 边界；`init(allowedPaths:)` 由此接入 Keychain store。
    init(store: any AccountCredentialStoring, allowedPaths: Set<String>) {
        self.store = store
        self.allowedPaths = allowedPaths
    }

    /// `subject` 是窗口账户的 mid（十进制正整数）；返回带 access_token 并签好名的新请求，原请求不被修改或缓存。
    public func authorize(
        _ request: HTTPRequest,
        boundTo subject: String
    ) async throws -> HTTPRequest {
        let path = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.path
        guard WriteRequestAuthorizationSupport.positiveInteger(subject),
            subject.allSatisfy({ $0.isASCII && $0.isNumber }),
            let schema = path.flatMap({ Self.schemas[$0] }),
            schema.method == request.method,
            let parameters = Self.parameters(of: request, allowedPaths: allowedPaths),
            Set(parameters.fields.keys) == Set(schema.fields.keys),
            parameters.fields.allSatisfy({ name, value in
                schema.fields[name]?.accepts(value) ?? false
            })
        else {
            throw BiliRequestAuthorizationError.requestNotAllowed
        }
        guard !request.headers.containsCredentialHeader else {
            throw BiliRequestAuthorizationError.credentialHeaderAlreadyPresent
        }

        let credential = try store.loadCredential(isConfirmedSignedOut: { false })
        // 账户绑定：窗口以为的账户与 Keychain 里的凭据不是同一个时不发出写请求，见 SECURITY-MODEL §3。
        guard credential.value(for: .userID) == subject else {
            throw BiliRequestAuthorizationError.accountMismatch
        }
        var fields = parameters.fields
        fields["access_key"] = credential.appAccessToken.value
        if let components = parameters.queryComponents {
            return try AppRequestAuthorizationSupport.signedRequest(
                request,
                components: components,
                parameters: fields
            )
        }
        return try AppRequestAuthorizationSupport.signedFormRequest(request, parameters: fields)
    }

    /// GET 返回 query 字段与 URL 组成（签名写回 query），POST 返回表单字段（签名写回正文）；目标或编码不合规时为 nil。
    private static func parameters(
        of request: HTTPRequest,
        allowedPaths: Set<String>
    ) -> (fields: [String: String], queryComponents: URLComponents?)? {
        switch request.method {
        case .get:
            AppRequestAuthorizationSupport.validatedGET(request, allowedPaths: allowedPaths)
                .map { ($0.parameters, $0.components) }
        case .post:
            AppRequestAuthorizationSupport.validatedPOSTForm(request, allowedPaths: allowedPaths)
                .map { ($0, nil) }
        case .head:
            nil
        }
    }
}
