import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// Bilibili endpoint/DTO adapter；把远端协议限制在 `BiliAPI`，并返回稳定模型。
///
/// 请求默认匿名，只有 `RequestAccess.accountRead` 才经过 authorizer。允许游客增强的读取
/// 也只有在本地明确无凭据时保持匿名，并继续使用同一个 endpoint。
/// 响应在解码前还要满足状态、大小与 Content-Type 边界。actor 隔离可变
/// transport/WBI cache；跨 `await` 可重入，用户意图的取消与写回代次仍由上层 owner 管理。
///
/// 本文件只含请求管线（access 选择、授权、epoch 复核、envelope 解码）与 WBI key；各域 endpoint
/// 在同 actor 的 `BiliAPIClient+*.swift` 扩展中。`RequestAccess` 与管线方法对 `BiliAPI` 内部可见
/// 只为这些扩展；Repository adapter 只调用 endpoint 方法，不得自行构造 `RequestAccess`。
public actor BiliAPIClient: AuthenticatedSessionInvalidating {
    enum MissingCredentialBehavior: Sendable, Equatable {
        case fail
        case useAnonymousRequest
    }

    enum RequestAccess: Sendable {
        case anonymous
        case accountRead(
            missingCredential: MissingCredentialBehavior,
            mapsAuthenticationInvalidation: Bool
        )
        case historyWrite

        var requiresAuthentication: Bool {
            switch self {
            case .anonymous: false
            case .accountRead, .historyWrite: true
            }
        }

        var permitsMissingCredentialFallback: Bool {
            guard case .accountRead(let behavior, _) = self else { return false }
            return behavior == .useAnonymousRequest
        }

        var mapsAuthenticationInvalidation: Bool {
            switch self {
            case .accountRead(_, let mapsInvalidation): mapsInvalidation
            case .anonymous, .historyWrite: false
            }
        }
    }

    enum AuthorizationProvenance: Sendable {
        case anonymous
        case authenticated
    }

    struct AuthorizedResponse<Payload: Sendable>: Sendable {
        let payload: Payload
        let authorizationProvenance: AuthorizationProvenance
    }

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

    private static let maximumResponseSize = 5 * 1_024 * 1_024

    /// 搜索接口要求的 `buvid3`，进程内随机生成一次，只附加到搜索请求。
    ///
    /// 只在内存中，不持久化、不关联账户；格式与 yt-dlp 相同（小写 UUID + `infoc`）。
    static let searchBuvid3Cookie = "buvid3=\(UUID().uuidString.lowercased())infoc"

    private var httpClient: HTTPClient
    private var transport: any HTTPTransport
    private let transportFactory: (@Sendable () -> any HTTPTransport)?
    private let requestAuthorizer: (any HTTPRequestAuthorizing)?
    private let historyWriteAuthorizer: (any HTTPRequestAuthorizing)?
    let userAgent = HTTPUserAgent.browserCompatible
    let decoder: JSONDecoder
    let timestampProvider: @Sendable () -> Int64
    let wbiSigner = WBISigner()
    private var cachedWBIKey: CachedWBIKey?
    private(set) var authenticatedSessionEpoch: UInt64 = 0

    /// 端点扩展只需知道是否注入了授权器；授权器本身不离开请求管线。
    var hasAccountAuthorizer: Bool { requestAuthorizer != nil }
    var hasHistoryWriteAuthorizer: Bool { historyWriteAuthorizer != nil }

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        requestAuthorizer: (any HTTPRequestAuthorizing)? = nil,
        historyWriteAuthorizer: (any HTTPRequestAuthorizing)? = nil,
        transportFactory: (@Sendable () -> any HTTPTransport)? = nil,
        timestampProvider: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970)
        }
    ) {
        let activeTransport = transportFactory?() ?? transport
        self.transport = activeTransport
        httpClient = HTTPClient(transport: activeTransport)
        self.transportFactory = transportFactory
        self.requestAuthorizer = requestAuthorizer
        self.historyWriteAuthorizer = historyWriteAuthorizer
        self.timestampProvider = timestampProvider
        decoder = JSONDecoder()
    }

    /// 认证会话失效时取消旧 transport 请求、换入干净 session，并丢弃关联 WBI key。
    public func invalidateAuthenticatedSession() {
        authenticatedSessionEpoch &+= 1
        if let invalidating = transport as? any HTTPTransportInvalidating {
            invalidating.invalidateAndCancel()
        }
        if let transportFactory {
            let replacement = transportFactory()
            transport = replacement
            httpClient = HTTPClient(transport: replacement)
        }
        cachedWBIKey = nil
    }

    func get<Payload: Decodable & Sendable>(
        path: String,
        queryItems: [URLQueryItem],
        referer: String,
        access: RequestAccess = .anonymous,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> Payload {
        try await getWithAuthorizationProvenance(
            path: path,
            queryItems: queryItems,
            referer: referer,
            access: access,
            maximumResponseSize: maximumResponseSize
        ).payload
    }

    func getWithAuthorizationProvenance<
        Payload: Decodable & Sendable
    >(
        path: String,
        queryItems: [URLQueryItem],
        referer: String,
        access: RequestAccess = .anonymous,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> AuthorizedResponse<Payload> {
        let url = try endpoint(path: path, queryItems: queryItems)
        return try await getWithAuthorizationProvenance(
            url: url,
            referer: referer,
            access: access,
            maximumResponseSize: maximumResponseSize
        )
    }

    func get<Payload: Decodable & Sendable>(
        path: String,
        percentEncodedQuery: String,
        referer: String,
        access: RequestAccess = .anonymous,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> Payload {
        let url = try endpoint(
            path: path,
            percentEncodedQuery: percentEncodedQuery
        )
        return try await get(
            url: url,
            referer: referer,
            access: access,
            maximumResponseSize: maximumResponseSize
        )
    }

    func get<Payload: Decodable & Sendable>(
        url: URL,
        referer: String,
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

    func getWithAuthorizationProvenance<
        Payload: Decodable & Sendable
    >(
        url: URL,
        referer: String,
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
        if access.mapsAuthenticationInvalidation, status.code == -101 {
            throw BiliAPIError.authenticationInvalid
        }
        guard status.code == 0 else {
            throw BiliAPIError.apiRejected(
                code: status.code,
                message: status.message ?? ""
            )
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

    func response(
        url: URL,
        referer: String,
        access: RequestAccess = .anonymous,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize,
        additionalCookie: String? = nil
    ) async throws -> AuthorizedHTTPResponse {
        let baseRequest = HTTPRequest(
            url: url,
            headers: [
                "Accept": "application/json",
                "Referer": referer,
                "User-Agent": userAgent
            ]
        )
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

    /// `additionalCookie` 只承载 endpoint 要求的非秘密 Cookie，在授权之后并入请求，
    /// 因此不会绕过授权器对调用方自带 Cookie 的拒绝。
    func response(
        baseRequest: HTTPRequest,
        access: RequestAccess,
        maximumResponseSize: Int,
        additionalCookie: String? = nil
    ) async throws -> AuthorizedHTTPResponse {
        let requestClient = httpClient
        let requestSessionEpoch =
            access.requiresAuthentication ? authenticatedSessionEpoch : nil
        var request: HTTPRequest
        let authorizationProvenance: AuthorizationProvenance
        let activeAuthorizer: (any HTTPRequestAuthorizing)? =
            switch access {
            case .historyWrite:
                historyWriteAuthorizer
            case .accountRead:
                requestAuthorizer
            case .anonymous:
                nil
            }
        if access.requiresAuthentication, let activeAuthorizer {
            do {
                request = try await activeAuthorizer.authorize(baseRequest)
                authorizationProvenance = .authenticated
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as any HTTPRequestAuthorizationFailure {
                guard requestSessionEpoch == authenticatedSessionEpoch else {
                    throw CancellationError()
                }
                switch error.authorizationFailureKind {
                case .missingCredential where access.permitsMissingCredentialFallback:
                    request = baseRequest
                    authorizationProvenance = .anonymous
                case .invalidCredential:
                    throw BiliAPIError.authenticationInvalid
                case .missingCredential:
                    throw BiliAPIError.authorizationRequired
                case .unavailable, .denied:
                    throw BiliAPIError.authorizationUnavailable
                }
            } catch {
                guard requestSessionEpoch == authenticatedSessionEpoch else {
                    throw CancellationError()
                }
                throw BiliAPIError.authorizationUnavailable
            }
        } else if access.permitsMissingCredentialFallback {
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

    /// WBI 签名请求被服务端以 -403（以及可选的 HTTP 403）拒绝时，强制刷新 WBI key 并只重试一次。
    func withWBIKeyRefresh<Value>(
        retryingHTTPForbidden: Bool = true,
        _ request: (_ forceKeyRefresh: Bool) async throws -> Value
    ) async throws -> Value {
        do {
            return try await request(false)
        } catch BiliAPIError.apiRejected(let code, _) where code == -403 {
            return try await request(true)
        } catch BiliAPIError.httpStatus(403) where retryingHTTPForbidden {
            return try await request(true)
        }
    }

    func requireAuthenticatedSessionEpoch(_ expected: UInt64) throws {
        guard authenticatedSessionEpoch == expected else {
            throw CancellationError()
        }
    }

    func wbiKey(forceRefresh: Bool) async throws -> WBIKeyMaterial {
        let currentDay = timestampProvider() / 86_400
        if forceRefresh {
            cachedWBIKey = nil
        } else if let cachedWBIKey, cachedWBIKey.day == currentDay {
            return cachedWBIKey.key
        }

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
        cachedWBIKey = CachedWBIKey(key: key, day: currentDay)
        return key
    }

    func endpoint(
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        guard
            var components = URLComponents(
                url: Self.baseURL,
                resolvingAgainstBaseURL: false
            )
        else {
            throw BiliAPIError.invalidRequest
        }
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else {
            throw BiliAPIError.invalidRequest
        }
        return url
    }

    func endpoint(
        path: String,
        percentEncodedQuery: String
    ) throws -> URL {
        guard
            var components = URLComponents(
                url: Self.baseURL,
                resolvingAgainstBaseURL: false
            )
        else {
            throw BiliAPIError.invalidRequest
        }
        components.path = path
        components.percentEncodedQuery = percentEncodedQuery
        guard let url = components.url else {
            throw BiliAPIError.invalidRequest
        }
        return url
    }

    static func isValidBVID(_ bvid: String) -> Bool {
        bvid.hasPrefix("BV")
            && bvid.count > 2
            && bvid.count <= 24
            && bvid.dropFirst(2).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func videoReferer(_ bvid: String) -> String {
        "https://www.bilibili.com/video/\(bvid)/"
    }
}

private struct CachedWBIKey: Sendable {
    let key: WBIKeyMaterial
    let day: Int64
}

struct APIStatusEnvelope: Decodable, Sendable {
    let code: Int
    let message: String?
}

private struct APIEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let data: Payload?
}
