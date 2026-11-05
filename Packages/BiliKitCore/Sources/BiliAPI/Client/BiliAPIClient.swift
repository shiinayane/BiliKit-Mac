import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// Bilibili endpoint 与 DTO 的 adapter：把远端协议限制在 `BiliAPI`，对外只返回稳定模型。
///
/// 请求默认匿名、不带 Cookie；只有 `RequestAccess.accountRead`、`.historyWrite` 与 `.accountWrite`
/// 经过各自注入的授权器，允许游客增强的读取只在本地明确无凭据时匿名请求同一个 endpoint（见
/// SECURITY-MODEL §3）。响应在解码前还要满足状态、大小与 Content-Type 边界。
///
/// 拥有当前 transport 与 `HTTPClient`、WBI key 缓存和认证 epoch，都由 actor 隔离；跨 `await`
/// 可重入，用户意图的取消与写回代次由上层 ViewModel 管理。实例由 Composition（`LiveAPIClients`）
/// 按用途构造：每个窗口一个主 API（只有它打开用户发起的账户写入），进程级的线路测速与观看进度写入各一个；都登记进
/// 账户会话，登出、换号与凭据失效时经 `invalidateAuthenticatedSession()` 一并失效。
///
/// 本文件只含请求管线（access 选择、授权、epoch 复核、envelope 解码）、WBI key 与签名读取序列
/// （`signedRequest`）；各域 endpoint 在同 actor 的 `BiliAPIClient+*.swift` 扩展中，签名读取一律经
/// `signedRequest`。`RequestAccess` 与管线方法对 `BiliAPI` 内部可见
/// 只为这些扩展；Repository adapter 只调用 endpoint 方法，不得自行构造 `RequestAccess`。
public actor BiliAPIClient: AuthenticatedSessionInvalidating {
    /// 账户读取在本地明确无凭据时的去向：`fail` 失败为“需要登录”，`useAnonymousRequest`
    /// 匿名请求同一 endpoint。
    ///
    /// 未注入账户读取授权器的 client 同样按本地无凭据处理。凭据失效、Keychain
    /// 不可用与授权器拒绝从不回退匿名，见 SECURITY-MODEL §3。
    enum MissingCredentialBehavior: Sendable, Equatable {
        case fail
        case useAnonymousRequest
    }

    /// 一次请求的授权方式，由 endpoint 扩展逐请求选择；Repository adapter 不得构造（见
    /// docs/ARCHITECTURE.md「认证」）。
    ///
    /// `anonymous` 不经授权器；`accountRead` 经账户读取授权器，path 必须来自 `BiliAccountReadPath`
    /// 并在 Composition 的 allowlist 内；`historyWrite` 只用于观看进度 heartbeat，
    /// 经独立的写授权器；`accountWrite` 是用户发起的账户写入，path 来自 `BiliAccountWritePath`，经账户写授权器并绑定
    /// 预期账户 mid（凭据属于其他账户时按凭据失效拒绝）。`appRead` 是 App 端（`app.bilibili.com`）读取，path 来自
    /// `BiliAppReadPath`，总是经 App 授权器签名：有凭据时带 access_token，本地明确无凭据时匿名签名。`appWrite` 是用户
    /// 发起的 App 端写入，path 来自 `BiliAppWritePath`，经 App 写授权器签名并绑定预期账户 mid，从不匿名。需要认证的
    /// 访问与 `appRead` 都绑定认证 epoch，见 `authenticatedSessionEpoch`。
    enum RequestAccess: Sendable {
        case anonymous
        case accountRead(missingCredential: MissingCredentialBehavior)
        case historyWrite
        case accountWrite(expectedAccountID: Int64)
        case appRead
        case appWrite(expectedAccountID: Int64)

        var requiresAuthentication: Bool {
            switch self {
            case .anonymous, .appRead: false
            case .accountRead, .historyWrite, .accountWrite, .appWrite: true
            }
        }

        /// 可能带凭据发出的访问：发出前后都比对认证 epoch。
        var bindsAuthenticatedSession: Bool {
            switch self {
            case .anonymous: false
            case .accountRead, .historyWrite, .accountWrite, .appRead, .appWrite: true
            }
        }

        var permitsMissingCredentialFallback: Bool {
            guard case .accountRead(let behavior) = self else { return false }
            return behavior == .useAnonymousRequest
        }
    }

    /// 请求实际以何种身份发出：`authenticated` 表示授权器写入了凭据，`anonymous`
    /// 含匿名访问与无凭据时的匿名回退。
    ///
    /// -101 的映射与是否采纳只属于账户的数据（playurl 的续播位置与 AI 配音）都按它判定。
    enum AuthorizationProvenance: Sendable {
        case anonymous
        case authenticated

        /// 读取响应的业务码 -101（账号未登录）对应的错误；其他业务码为 nil。
        ///
        /// 只有实际带凭据发出的请求收到 -101 才是凭据失效（触发账户复核）。匿名请求（含本地无凭据时的
        /// 匿名回退）收到 -101 说明该接口要求登录，按“需要登录”处理，不触发复核。heartbeat 写请求另有
        /// 自己的判定。
        func notLoggedInError(statusCode: Int) -> BiliAPIError? {
            guard statusCode == -101 else { return nil }
            return self == .authenticated ? .authenticationInvalid : .authorizationRequired
        }
    }

    /// 解码后的 `data` 与这次请求的实际授权来源。
    struct AuthorizedResponse<Payload: Sendable>: Sendable {
        let payload: Payload
        let authorizationProvenance: AuthorizationProvenance
    }

    /// 已通过状态码与大小检查、尚未解码的 HTTP 响应及其授权来源；JSON、protobuf 与 heartbeat
    /// 各自在其上判定正文。
    struct AuthorizedHTTPResponse: Sendable {
        let response: HTTPResponse
        let authorizationProvenance: AuthorizationProvenance
    }

    private static let baseURL: URL = {
        guard let url = URL(string: "https://api.bilibili.com") else {
            preconditionFailure("Static API base URL must be valid")
        }
        return url
    }()
    /// App 端接口的唯一来源；与 `baseURL` 分开，`appRead` 与 `appWrite` 之外的访问不会发往这里。
    private static let appBaseURL: URL = {
        guard let url = URL(string: "https://app.bilibili.com") else {
            preconditionFailure("Static App API base URL must be valid")
        }
        return url
    }()

    /// JSON 接口默认的响应正文上限，在完整收到正文后检查；超出按 `responseTooLarge` 失败关闭、
    /// 不解码。
    ///
    /// 字幕目录、评论页、弹幕分段与 heartbeat 按各自形状传入更紧的上限；
    /// 调小可能误拒较大的正常列表，调大放宽单次解码的输入规模。
    private static let maximumResponseSize = 5 * 1_024 * 1_024

    /// 搜索、点赞、投币与三连接口要求的 `buvid3`，进程内随机生成一次，只附加到这几种请求。
    ///
    /// 只在内存中，不持久化、不关联账户；格式与 yt-dlp 相同（小写 UUID + `infoc`）。见
    /// SECURITY-MODEL §3。
    static let buvid3Cookie = "buvid3=\(UUID().uuidString.lowercased())infoc"

    private var httpClient: HTTPClient
    private var transport: any HTTPTransport
    private let transportFactory: @Sendable () -> any HTTPTransport
    private let requestAuthorizer: (any HTTPRequestAuthorizing)?
    private let historyWriteAuthorizer: (any HTTPRequestAuthorizing)?
    private let accountWriteAuthorizer: (any HTTPSubjectBoundRequestAuthorizing)?
    private let appRequestAuthorizer: (any HTTPSigningRequestAuthorizing)?
    private let appWriteAuthorizer: (any HTTPSubjectBoundRequestAuthorizing)?
    let userAgent = HTTPUserAgent.browserCompatible
    let decoder: JSONDecoder
    let timestampProvider: @Sendable () -> Int64
    let wbiSigner = WBISigner()
    private var cachedWBIKey: CachedWBIKey?
    /// 认证会话 epoch：只在 `invalidateAuthenticatedSession()` 递增（登出、换号与凭据失效），
    /// 登录成功不推进。
    ///
    /// 需要认证的请求在授权前记录它，授权返回后、发送前与响应返回后比对；`signedRequest` 在取 key
    /// 后与 `send` 返回后比对，WBI nav 返回后比对决定是否写回 key 缓存，playurl
    /// 对带凭据的结果再比对一次。不一致一律抛 `CancellationError`，丢弃授权结果或响应，不以新会话、
    /// 新 key 或匿名身份补发。登录方向由关闭依赖账户的播放器与各页面的 generation 隔离旧结果。见
    /// SECURITY-MODEL §3。
    private(set) var authenticatedSessionEpoch: UInt64 = 0

    /// 端点扩展只需知道是否注入了授权器；授权器本身不离开请求管线。
    var hasAccountAuthorizer: Bool { requestAuthorizer != nil }
    var hasHistoryWriteAuthorizer: Bool { historyWriteAuthorizer != nil }
    var hasAccountWriteAuthorizer: Bool { accountWriteAuthorizer != nil }
    var hasAppWriteAuthorizer: Bool { appWriteAuthorizer != nil }

    /// `transportFactory` 由组合根提供用途专属 transport：初始化时取一次，每次认证会话失效时再取一个
    /// 干净实例替换旧的；不存在回落到 `URLSession.shared` 的默认值（见 SECURITY-MODEL §1）。
    public init(
        requestAuthorizer: (any HTTPRequestAuthorizing)? = nil,
        historyWriteAuthorizer: (any HTTPRequestAuthorizing)? = nil,
        accountWriteAuthorizer: (any HTTPSubjectBoundRequestAuthorizing)? = nil,
        appRequestAuthorizer: (any HTTPSigningRequestAuthorizing)? = nil,
        appWriteAuthorizer: (any HTTPSubjectBoundRequestAuthorizing)? = nil,
        transportFactory: @escaping @Sendable () -> any HTTPTransport,
        timestampProvider: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970)
        }
    ) {
        let activeTransport = transportFactory()
        transport = activeTransport
        httpClient = HTTPClient(transport: activeTransport)
        self.transportFactory = transportFactory
        self.requestAuthorizer = requestAuthorizer
        self.historyWriteAuthorizer = historyWriteAuthorizer
        self.accountWriteAuthorizer = accountWriteAuthorizer
        self.appRequestAuthorizer = appRequestAuthorizer
        self.appWriteAuthorizer = appWriteAuthorizer
        self.timestampProvider = timestampProvider
        decoder = JSONDecoder()
    }

    /// 认证会话失效时推进 epoch、取消旧 transport 的在途请求、换入新 transport，并丢弃 WBI key
    /// 缓存。
    ///
    /// 由账户会话 coordinator 在登出、换号与凭据失效时调用（`AuthenticatedSessionInvalidating`）。
    /// 被取消的需要认证的请求随后看到 epoch 不符，以 `CancellationError` 结束而不是报告网络失败。
    public func invalidateAuthenticatedSession() {
        authenticatedSessionEpoch &+= 1
        if let invalidating = transport as? any HTTPTransportInvalidating {
            invalidating.invalidateAndCancel()
        }
        let replacement = transportFactory()
        transport = replacement
        httpClient = HTTPClient(transport: replacement)
        cachedWBIKey = nil
    }

    /// 不关心授权来源时的薄封装。
    func get<Payload: Decodable & Sendable>(
        url: URL,
        referer: String?,
        access: RequestAccess = .anonymous,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> Payload {
        try await getWithAuthorizationProvenance(
            url: url,
            referer: referer,
            access: access,
            maximumResponseSize: maximumResponseSize
        ).payload
    }

    /// JSON GET 的唯一管线：请求、授权、状态码与 envelope 解码，并返回授权来源。
    func getWithAuthorizationProvenance<
        Payload: Decodable & Sendable
    >(
        url: URL,
        referer: String?,
        access: RequestAccess = .anonymous,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize,
        additionalCookie: String? = nil
    ) async throws -> AuthorizedResponse<Payload> {
        let authorizedResponse = try await response(
            url: url,
            referer: referer,
            access: access,
            maximumResponseSize: maximumResponseSize,
            additionalCookie: additionalCookie
        )
        let response = authorizedResponse.response

        let status: APIStatusEnvelope
        do {
            status = try decoder.decode(APIStatusEnvelope.self, from: response.body)
        } catch {
            throw BiliAPIError.decodingFailed
        }
        if let error = authorizedResponse.authorizationProvenance.notLoggedInError(
            statusCode: status.code
        ) {
            throw error
        }
        guard status.code == 0 else {
            throw BiliAPIError.apiRejected(
                code: status.code,
                message: status.message ?? ""
            )
        }
        if Self.isRiskControlVoucher(response.body) {
            throw BiliAPIError.riskControlVoucher
        }
        let envelope: APIEnvelope<Payload>
        do {
            envelope = try decoder.decode(APIEnvelope<Payload>.self, from: response.body)
        } catch {
            throw BiliAPIError.decodingFailed
        }
        guard let payload = envelope.data else {
            throw BiliAPIError.missingData
        }
        return AuthorizedResponse(
            payload: payload,
            authorizationProvenance:
                authorizedResponse.authorizationProvenance
        )
    }

    /// JSON 请求的 HTTP 层：固定 `Accept`、`User-Agent` 与给出时的 `Referer`（App 端请求不带），经请求管线后要求正文像
    /// JSON。
    ///
    /// 不像 JSON（如 HTML 风控页）按 `nonJSONResponse` 失败关闭；不解码 envelope，WBI nav
    /// 直接读它的正文。
    func response(
        url: URL,
        referer: String?,
        access: RequestAccess = .anonymous,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize,
        additionalCookie: String? = nil
    ) async throws -> AuthorizedHTTPResponse {
        var headers = ["Accept": "application/json", "User-Agent": userAgent]
        headers["Referer"] = referer
        let baseRequest = HTTPRequest(url: url, headers: headers)
        let response = try await response(
            baseRequest: baseRequest,
            access: access,
            maximumResponseSize: maximumResponseSize,
            additionalCookie: additionalCookie
        )
        guard response.response.looksLikeJSON(allowsTopLevelArray: true) else {
            throw BiliAPIError.nonJSONResponse
        }
        return response
    }

    /// 所有请求的唯一管线：按 `access` 选择授权器并授权，附加非秘密 Cookie，
    /// 发送并检查状态码与大小。
    ///
    /// 返回实际授权来源；认证 epoch 的比对规则见 `authenticatedSessionEpoch`。`additionalCookie`
    /// 只承载 endpoint 要求的非秘密 Cookie，在授权之后并入请求，因此不会绕过授权器对调用方自带
    /// Cookie 的拒绝（见 SECURITY-MODEL §3）。
    func response(
        baseRequest: HTTPRequest,
        access: RequestAccess,
        maximumResponseSize: Int,
        additionalCookie: String? = nil
    ) async throws -> AuthorizedHTTPResponse {
        // 在第一个 await 之前取出 client：授权期间会话失效换入的新 transport 不会被这次请求使用。
        let requestClient = httpClient
        // 只有可能带凭据的访问绑定会话 epoch；匿名请求不比对。
        let requestSessionEpoch =
            access.bindsAuthenticatedSession ? authenticatedSessionEpoch : nil
        var request: HTTPRequest
        let authorizationProvenance: AuthorizationProvenance
        if case .appRead = access {
            // App 端请求即使匿名也必须签名，不能走下面“无凭据时发原请求”的回退；没有 App 授权器的 client 不能发。
            guard let appRequestAuthorizer else { throw BiliAPIError.invalidRequest }
            do {
                let signed = try await appRequestAuthorizer.authorize(baseRequest)
                request = signed.request
                authorizationProvenance = signed.carriesCredential ? .authenticated : .anonymous
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw authorizationError(error, sessionEpoch: requestSessionEpoch)
            }
        } else if access.requiresAuthentication, hasAuthorizer(for: access) {
            do {
                request = try await authorize(baseRequest, access: access)
                authorizationProvenance = .authenticated
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as any HTTPRequestAuthorizationFailure
                where error.authorizationFailureKind == .missingCredential
                && access.permitsMissingCredentialFallback
                && requestSessionEpoch == authenticatedSessionEpoch
            {
                // 只有本地明确无凭据且 endpoint 允许时才匿名回退；其余授权失败见 `authorizationError`。
                request = baseRequest
                authorizationProvenance = .anonymous
            } catch {
                throw authorizationError(error, sessionEpoch: requestSessionEpoch)
            }
        } else if access.permitsMissingCredentialFallback {
            // 未注入对应授权器（如观看进度写入 client 没有账户读取授权器）时按本地无凭据处理。
            request = baseRequest
            authorizationProvenance = .anonymous
        } else if access.requiresAuthentication {
            throw BiliAPIError.authorizationRequired
        } else {
            request = baseRequest
            authorizationProvenance = .anonymous
        }
        if let additionalCookie {
            var headers = request.headers
            headers["Cookie"] = [headers["Cookie"], additionalCookie]
                .compactMap { $0 }
                .joined(separator: "; ")
            request = HTTPRequest(
                url: request.url,
                method: request.method,
                headers: headers,
                body: request.body
            )
        }
        try Task.checkCancellation()
        if let requestSessionEpoch,
            requestSessionEpoch != authenticatedSessionEpoch
        {
            throw CancellationError()
        }

        let response: HTTPResponse
        do {
            response = try await requestClient.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPClientError {
            if let requestSessionEpoch,
                requestSessionEpoch != authenticatedSessionEpoch
            {
                throw CancellationError()
            }
            throw BiliAPIError(error)
        } catch {
            if let requestSessionEpoch,
                requestSessionEpoch != authenticatedSessionEpoch
            {
                throw CancellationError()
            }
            throw BiliAPIError.transportFailure
        }
        if let requestSessionEpoch,
            requestSessionEpoch != authenticatedSessionEpoch
        {
            throw CancellationError()
        }

        guard response.body.count <= maximumResponseSize else {
            throw BiliAPIError.responseTooLarge(response.body.count)
        }
        return AuthorizedHTTPResponse(
            response: response,
            authorizationProvenance: authorizationProvenance
        )
    }

    /// 授权失败到 API 错误的唯一映射，匿名回退由调用方先处理。
    ///
    /// 凭据失效、Keychain 不可用与授权器拒绝都失败关闭，见 SECURITY-MODEL §3。授权期间会话已失效时失败属于旧会话，
    /// 按取消结束，不报告为凭据问题。
    private func authorizationError(_ error: any Error, sessionEpoch: UInt64?) -> any Error {
        guard sessionEpoch == authenticatedSessionEpoch else { return CancellationError() }
        guard let failure = error as? any HTTPRequestAuthorizationFailure else {
            return BiliAPIError.authorizationUnavailable
        }
        switch failure.authorizationFailureKind {
        case .invalidCredential:
            return BiliAPIError.authenticationInvalid
        case .missingCredential:
            return BiliAPIError.authorizationRequired
        case .unavailable:
            return BiliAPIError.authorizationUnavailable
        case .denied:
            // 请求形状或 path 不在授权器 allowlist：客户端构造了不该发出的账户请求，属于编程错误，
            // 不是本地凭据问题，因此不显示为 Keychain 类失败。
            return BiliAPIError.invalidRequest
        }
    }

    private func hasAuthorizer(for access: RequestAccess) -> Bool {
        switch access {
        case .anonymous, .appRead: false
        case .accountRead: requestAuthorizer != nil
        case .historyWrite: historyWriteAuthorizer != nil
        case .accountWrite: accountWriteAuthorizer != nil
        case .appWrite: appWriteAuthorizer != nil
        }
    }

    /// 按 `access` 交给对应的授权器；网页与 App 的账户写入另把预期账户 mid 作为绑定主体，调用前已由 `hasAuthorizer`
    /// 确认注入。
    private func authorize(
        _ request: HTTPRequest,
        access: RequestAccess
    ) async throws -> HTTPRequest {
        switch access {
        case .accountRead:
            guard let requestAuthorizer else { break }
            return try await requestAuthorizer.authorize(request)
        case .historyWrite:
            guard let historyWriteAuthorizer else { break }
            return try await historyWriteAuthorizer.authorize(request)
        case .accountWrite(let expectedAccountID):
            guard let accountWriteAuthorizer else { break }
            return try await accountWriteAuthorizer.authorize(
                request,
                boundTo: String(expectedAccountID)
            )
        case .appWrite(let expectedAccountID):
            guard let appWriteAuthorizer else { break }
            return try await appWriteAuthorizer.authorize(
                request,
                boundTo: String(expectedAccountID)
            )
        case .anonymous, .appRead:
            break
        }
        preconditionFailure("调用方先用 hasAuthorizer(for:) 确认已注入对应授权器")
    }

    /// WBI 签名读取的唯一序列：取 key、签名、请求与会话 epoch 复核都在这里，endpoint 只给出 path、
    /// 参数与发送方式。
    ///
    /// 进入时记录认证会话 epoch；取 key 之后与 `send` 返回之后都比对，不一致抛 `CancellationError`，
    /// 结果既不写回也不以新会话、新 key 或匿名身份补发。`parameters` 每次尝试都重新求值，`send` 拿到
    /// 本次尝试用当前 key 与时间戳签好的 URL，自行决定授权方式与解码；重试规则见
    /// `withWBIKeyRefresh`。heartbeat 写请求不经过这里：写入不做换 key 重试。
    func signedRequest<Value>(
        path: String,
        intermittentRestrictionRetryDelay: Duration? = nil,
        parameters: () -> [String: String],
        send: (_ url: URL) async throws -> Value
    ) async throws -> Value {
        let sessionEpoch = authenticatedSessionEpoch
        return try await withWBIKeyRefresh(
            sessionEpoch: sessionEpoch,
            intermittentRestrictionRetryDelay: intermittentRestrictionRetryDelay
        ) { forceKeyRefresh in
            let keys = try await wbiKey(forceRefresh: forceKeyRefresh)
            try requireAuthenticatedSessionEpoch(sessionEpoch)
            let query = try wbiSigner.sign(
                parameters: parameters(),
                keys: keys,
                timestamp: timestampProvider()
            )
            let value = try await send(try endpoint(path: path, percentEncodedQuery: query))
            try requireAuthenticatedSessionEpoch(sessionEpoch)
            return value
        }
    }

    /// WBI 签名请求的唯一重试策略：任何组合下最多请求两次。
    ///
    /// 首次请求被 -403 或 `v_voucher` 挑战拒绝时强制刷新 WBI key 再请求一次。HTTP 403／412 是风控而不是
    /// key 过期，默认按受限失败关闭；只有传入 `intermittentRestrictionRetryDelay` 的调用方在首次请求被
    /// HTTP 412 拒绝时等待后用同一个 key 再请求一次，等待期间会话变化则取消。重试的结果不再进入任何重试。
    private func withWBIKeyRefresh<Value>(
        sessionEpoch: UInt64,
        intermittentRestrictionRetryDelay: Duration?,
        _ request: (_ forceKeyRefresh: Bool) async throws -> Value
    ) async throws -> Value {
        do {
            return try await request(false)
        } catch BiliAPIError.apiRejected(let code, _) where code == -403 {
            return try await request(true)
        } catch BiliAPIError.riskControlVoucher {
            return try await request(true)
        } catch BiliAPIError.httpStatus(412) {
            guard let intermittentRestrictionRetryDelay else {
                throw BiliAPIError.httpStatus(412)
            }
            try await Task.sleep(for: intermittentRestrictionRetryDelay)
            try requireAuthenticatedSessionEpoch(sessionEpoch)
            return try await request(false)
        }
    }

    /// 只有 `data` 恰好是 `{"v_voucher": …}` 才算挑战；正常响应里并列的 `v_voucher` 不影响解码。
    ///
    /// 读取管线与写入的 `postForm` 共用这一处判定。
    static func isRiskControlVoucher(_ body: Data) -> Bool {
        guard body.range(of: Data(#""v_voucher""#.utf8)) != nil,
            let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let data = root["data"] as? [String: Any]
        else { return false }
        return data.count == 1 && data["v_voucher"] != nil
    }

    /// 当前认证 epoch 不等于调用方进入时记录的值就抛 `CancellationError`；endpoint
    /// 扩展在使用带凭据的结果前调用。
    func requireAuthenticatedSessionEpoch(_ expected: UInt64) throws {
        guard authenticatedSessionEpoch == expected else {
            throw CancellationError()
        }
    }

    /// 取 WBI key：非强制时复用同一 UTC 日（时间戳 ÷ 86400）取得的缓存，跨日后首个签名请求重新读取
    /// nav。
    ///
    /// `forceRefresh` 先清空缓存，只在签名读取被 -403 或 `v_voucher` 拒绝后的重试中使用。nav
    /// 永远匿名，见 SECURITY-MODEL §3。
    func wbiKey(forceRefresh: Bool) async throws -> WBIKeyMaterial {
        let currentDay = timestampProvider() / 86_400
        if forceRefresh {
            cachedWBIKey = nil
        } else if let cachedWBIKey, cachedWBIKey.day == currentDay {
            return cachedWBIKey.key
        }

        // 会话失效会清掉缓存的 key；nav 返回前会话已失效时不把迟到的 key 写回去。
        let sessionEpoch = authenticatedSessionEpoch
        // 与 BiliAuth 的会话校验同一 path（`BiliAuthenticationService.sessionValidationPath`），但这里永远匿名、
        // 不在任何 allowlist；BiliAuth 不能依赖 BiliAPI，所以两边各留一份。见 SECURITY-MODEL §3。
        let url = try endpoint(path: "/x/web-interface/nav", queryItems: [])
        let response = try await response(
            url: url,
            referer: "https://www.bilibili.com/"
        ).response
        let envelope: APIEnvelope<NavigationPayload>
        do {
            envelope = try decoder.decode(
                APIEnvelope<NavigationPayload>.self,
                from: response.body
            )
        } catch {
            throw BiliAPIError.decodingFailed
        }
        guard let image = envelope.data?.wbiImage else {
            throw BiliAPIError.invalidWBIKey
        }
        let key = try WBIKeyMaterial(
            imageURL: image.imageURL,
            subURL: image.subURL
        )
        if authenticatedSessionEpoch == sessionEpoch {
            cachedWBIKey = CachedWBIKey(key: key, day: currentDay)
        }
        return key
    }

    /// endpoint 地址都只拼到固定的 `https://api.bilibili.com`，调用方只给 path 与 query。
    func endpoint(
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        try endpoint(path: path) { $0.queryItems = queryItems }
    }

    /// 不带 query 的地址（写请求）：不写空的 `?`，授权器要求写请求没有 query。
    func endpoint(path: String) throws -> URL {
        try endpoint(path: path) { _ in }
    }

    /// App 端接口的地址；签名与 access_token 由 App 授权器在授权时写入 query。
    func appEndpoint(path: String, queryItems: [URLQueryItem]) throws -> URL {
        try endpoint(baseURL: Self.appBaseURL, path: path) { $0.queryItems = queryItems }
    }

    /// WBI 签名后的 query 已按签名顺序编码，必须原样使用。
    func endpoint(
        path: String,
        percentEncodedQuery: String
    ) throws -> URL {
        try endpoint(path: path) { $0.percentEncodedQuery = percentEncodedQuery }
    }

    private func endpoint(
        baseURL: URL = BiliAPIClient.baseURL,
        path: String,
        applyingQuery applyQuery: (inout URLComponents) -> Void
    ) throws -> URL {
        guard
            var components = URLComponents(
                url: baseURL,
                resolvingAgainstBaseURL: false
            )
        else {
            throw BiliAPIError.invalidRequest
        }
        components.path = path
        applyQuery(&components)
        guard let url = components.url else {
            throw BiliAPIError.invalidRequest
        }
        return url
    }

    /// 视频请求的 Referer：`BVID.webPageURL` 加尾部斜杠，与网页版一致，播放心跳授权器也按这个形状核对；
    /// BVID 不合法时抛 `invalidRequest`，不发出请求。
    static func videoReferer(_ bvid: String) throws -> String {
        guard let webPage = BVID.webPageURL(bvid) else { throw BiliAPIError.invalidRequest }
        return webPage.absoluteString + "/"
    }
}

/// 缓存的 WBI key 及取得它的 UTC 日序号。
private struct CachedWBIKey: Sendable {
    let key: WBIKeyMaterial
    let day: Int64
}

/// B 站 JSON 响应顶层的 `code` 与 `message`，在解码 `data` 之前读取；`code` 决定 -101 映射、
/// 业务拒绝或成功。
struct APIStatusEnvelope: Decodable, Sendable {
    let code: Int
    let message: String?
}

private struct APIEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let data: Payload?
}
