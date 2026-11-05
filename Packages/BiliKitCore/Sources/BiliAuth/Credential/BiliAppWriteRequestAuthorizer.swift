import BiliNetworking
import Foundation

/// 只授权用户发起的 App 端（`https://app.bilibili.com`）写入（目前只有首页推荐的「不感兴趣」与撤销）：绑定账户后附加
/// access_token 并做 APP 签名。
///
/// App 端的写入也是 GET，凭据与签名都在 query 里，所以与网页写入的 `BiliAccountWriteRequestAuthorizer`（POST 表单、
/// Cookie 与 csrf）分开；与 App 读取的 `BiliAppRequestAuthorizer` 也分开：写入从不匿名签名，本地无凭据就失败。每个
/// 请求必须精确命中 host、端口与 GET，path 同时在 Composition 声明的 allowlist 与本类型封闭的 schema 表里，query 字段
/// 恰为 schema 的字段且取值形状逐项通过；调用方自带凭据 header 或 `access_key`、签名等保留参数一律拒绝。任一校验不通过
/// 都按 `requestNotAllowed`（客户端编程错误）拒绝，不尝试修正请求。
///
/// 每次授权都重新读 Keychain、不缓存：凭据的 `DedeUserID` 必须等于调用方给出的预期账户（`boundTo`），不符时按凭据失效
/// （`accountMismatch`）拒绝但不删除凭据，理由同网页写入。新增写操作在 schema 表里逐条登记，不泛化（见
/// SECURITY-MODEL §3）。无状态。
public struct BiliAppWriteRequestAuthorizer: HTTPSubjectBoundRequestAuthorizing, Sendable {
    private typealias FieldShape = BiliAccountWriteRequestAuthorizer.FieldShape

    /// 全部可授权的 App 写 path 与它们的 query schema；path 字面量与 BiliAPI 的 `BiliAppWritePath` 相同（BiliAuth 不能依赖
    /// BiliAPI，Composition 的测试核对两边一致）。
    ///
    /// 「不感兴趣」与撤销字段完全相同：只收单个稿件（`goto` 固定为 av，`id` 是 aid）与卡片给出的一个 `reason_id`；
    /// `mobi_app`、`device`、`build` 与首页推荐请求的客户端身份一致。卡片里另有一组「反馈」（举报类，以 `feedback_id`
    /// 发送），不提供，schema 也不接受。
    private static let schemas: [String: [String: FieldShape]] = [
        "/x/feed/dislike": recommendationFeedbackSchema,
        "/x/feed/dislike/cancel": recommendationFeedbackSchema
    ]

    private static let recommendationFeedbackSchema: [String: FieldShape] = [
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
        guard WriteRequestAuthorizationSupport.positiveInteger(subject),
            subject.allSatisfy({ $0.isASCII && $0.isNumber }),
            let target = AppRequestAuthorizationSupport.validatedGET(
                request,
                allowedPaths: allowedPaths
            ),
            let schema = Self.schemas[target.components.path],
            Set(target.parameters.keys) == Set(schema.keys),
            target.parameters.allSatisfy({ name, value in schema[name]?.accepts(value) ?? false })
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
        var parameters = target.parameters
        parameters["access_key"] = credential.appAccessToken.value
        return try AppRequestAuthorizationSupport.signedRequest(
            request,
            components: target.components,
            parameters: parameters
        )
    }
}
