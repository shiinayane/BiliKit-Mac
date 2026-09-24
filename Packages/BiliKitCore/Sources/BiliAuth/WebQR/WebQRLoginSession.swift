import BiliNetworking
import Foundation

/// 拥有一次 Web QR challenge、轮询序列与尚未持久化的候选凭据。
///
/// generation 隔离新旧二维码，poll ID 隔离同一二维码的并发轮询；取消或未知协议状态会
/// 失败关闭并清除临时秘密。成功响应仍须登录态验证后才能写入 Keychain。
public actor WebQRLoginSession {
    public static let productionBaseURL: URL = {
        guard let url = URL(string: "https://passport.bilibili.com") else {
            preconditionFailure("Static Web QR base URL must be valid")
        }
        return url
    }()
    private static let qrCodeHost = "account.bilibili.com"

    public private(set) var state: WebQRLoginState = .signedOut

    private let httpClient: HTTPClient
    private let baseURL: URL
    private let credentialStore: any WebCredentialStoring
    private let transportInvalidator: (@Sendable () -> Void)?
    private let decoder = JSONDecoder()
    private var generation: UInt64 = 0
    private var activeChallenge: ActiveChallenge?
    private var pendingCredential: PendingCredential?
    private var latestPollID: UInt64 = 0

    public init() {
        let transport = AuthenticationHTTP.makeProductionTransport()
        httpClient = HTTPClient(transport: transport)
        baseURL = Self.productionBaseURL
        credentialStore = KeychainWebCredentialStore()
        transportInvalidator = { transport.invalidateAndCancel() }
    }

    init(
        transport: any HTTPTransport,
        baseURL: URL = WebQRLoginSession.productionBaseURL,
        credentialStore: any WebCredentialStoring = KeychainWebCredentialStore()
    ) {
        httpClient = HTTPClient(transport: transport)
        self.baseURL = baseURL
        self.credentialStore = credentialStore
        if let invalidating = transport as? any HTTPTransportInvalidating {
            transportInvalidator = { invalidating.invalidateAndCancel() }
        } else {
            transportInvalidator = nil
        }
    }

    @discardableResult
    public func requestQRCode() async throws -> WebQRLoginState {
        generation &+= 1
        let operationGeneration = generation
        activeChallenge = nil
        pendingCredential = nil
        latestPollID = 0
        state = .requestingQRCode

        do {
            let response = try await send(path: "/x/passport-login/web/qrcode/generate")
            try Task.checkCancellation()
            try requireCurrentGeneration(operationGeneration)

            let envelope: GenerateEnvelope
            do {
                envelope = try decoder.decode(GenerateEnvelope.self, from: response.body)
            } catch {
                return fail(.invalidResponse, generation: operationGeneration)
            }
            guard envelope.code == 0 else {
                return fail(
                    .serviceRejected(envelope.code),
                    generation: operationGeneration
                )
            }
            guard let data = envelope.data,
                Self.isValidQRCodeKey(data.qrcodeKey),
                Self.isValidQRCodeURL(data.url)
            else {
                return fail(.invalidResponse, generation: operationGeneration)
            }

            let qrCode = WebQRCode(payload: data.url)
            activeChallenge = ActiveChallenge(
                generation: operationGeneration,
                key: data.qrcodeKey,
                qrCode: qrCode
            )
            state = .awaitingScan(qrCode)
            return state
        } catch is StaleOperationError {
            throw CancellationError()
        } catch is CancellationError {
            resetIfCurrent(operationGeneration)
            throw CancellationError()
        } catch let failure as WebQRLoginFailure {
            return fail(failure, generation: operationGeneration)
        } catch {
            return fail(.network, generation: operationGeneration)
        }
    }

    @discardableResult
    public func pollOnce() async throws -> WebQRLoginState {
        guard let challenge = activeChallenge,
            challenge.generation == generation
        else {
            state = .failed(.noActiveChallenge)
            return state
        }

        latestPollID &+= 1
        let pollID = latestPollID

        do {
            let response = try await send(
                path: "/x/passport-login/web/qrcode/poll",
                queryItems: [
                    URLQueryItem(name: "qrcode_key", value: challenge.key)
                ]
            )
            try Task.checkCancellation()
            try requireCurrentPoll(
                generation: challenge.generation,
                pollID: pollID
            )

            let envelope: PollEnvelope
            do {
                envelope = try decoder.decode(PollEnvelope.self, from: response.body)
            } catch {
                return fail(.invalidResponse, generation: challenge.generation)
            }
            guard envelope.code == 0 else {
                return fail(
                    .serviceRejected(envelope.code),
                    generation: challenge.generation
                )
            }
            guard let data = envelope.data else {
                return fail(.invalidResponse, generation: challenge.generation)
            }

            switch data.code {
            case 0:
                pendingCredential = Self.pendingCredential(
                    from: response,
                    generation: challenge.generation
                )
                activeChallenge = nil
                state = .awaitingCredentialValidation
                return state
            case 86_101:
                state = .awaitingScan(challenge.qrCode)
                return state
            case 86_090:
                state = .awaitingConfirmation(challenge.qrCode)
                return state
            case 86_038:
                activeChallenge = nil
                state = .expired
                return state
            default:
                return fail(
                    .unsupportedStatus(data.code),
                    generation: challenge.generation
                )
            }
        } catch is StaleOperationError {
            throw CancellationError()
        } catch is CancellationError {
            resetIfCurrent(challenge.generation)
            throw CancellationError()
        } catch let failure as WebQRLoginFailure {
            return fail(failure, generation: challenge.generation)
        } catch {
            return fail(.network, generation: challenge.generation)
        }
    }

    /// 使 challenge、待验证凭据及所有旧轮询结果失效，但不修改已持久化凭据。
    public func cancel() {
        generation &+= 1
        latestPollID &+= 1
        activeChallenge = nil
        pendingCredential = nil
        state = .signedOut
    }

    public func invalidateSession() {
        cancel()
        transportInvalidator?()
    }

    /// 一次性消费候选凭据，验证登录态与有效期后才提交 Keychain。
    func validateAndStorePendingCredential() async throws
        -> NavigationAuthenticationResult
    {
        let pendingCredential = try takePendingCredential()
        let result = try await validate(pendingCredential)
        guard case .signedIn = result else { return .signedOut }
        guard !pendingCredential.credential.isExpired() else {
            throw WebQRLoginFailure.incompleteCredential
        }
        do {
            try credentialStore.save(pendingCredential.credential)
        } catch {
            throw WebQRLoginFailure.credentialStoreUnavailable
        }
        return result
    }

    private func takePendingCredential() throws -> PendingCredential {
        guard let pendingCredential else {
            throw WebQRLoginFailure.incompleteCredential
        }
        self.pendingCredential = nil
        guard generation == pendingCredential.generation else {
            throw CancellationError()
        }
        return pendingCredential
    }

    private func validate(
        _ pendingCredential: PendingCredential
    ) async throws -> NavigationAuthenticationResult {
        let response = try await send(
            AuthenticationHTTP.navigationValidationRequest(
                cookieHeader: pendingCredential.credential.cookieHeader
            )
        )
        try Task.checkCancellation()
        guard generation == pendingCredential.generation else {
            throw CancellationError()
        }
        do {
            return try AuthenticationHTTP.navigationResult(from: response)
        } catch {
            throw WebQRLoginFailure.invalidResponse
        }
    }

    private func send(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> HTTPResponse {
        try await send(
            HTTPRequest(
                url: try endpoint(path: path, queryItems: queryItems),
                headers: [
                    "Accept": "application/json",
                    "User-Agent": HTTPUserAgent.short
                ]
            )
        )
    }

    private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await httpClient.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPClientError {
            switch error {
            case .unacceptableStatusCode(let status):
                throw WebQRLoginFailure.httpStatus(status)
            case .nonHTTPResponse:
                throw WebQRLoginFailure.network
            }
        } catch {
            throw WebQRLoginFailure.network
        }

        guard response.body.count <= AuthenticationHTTP.maximumResponseSize else {
            throw WebQRLoginFailure.responseTooLarge
        }
        guard response.looksLikeJSON() else {
            throw WebQRLoginFailure.nonJSONResponse
        }
        return response
    }

    private func endpoint(
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        guard
            var components = URLComponents(
                url: baseURL,
                resolvingAgainstBaseURL: false
            )
        else {
            throw WebQRLoginFailure.invalidResponse
        }
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw WebQRLoginFailure.invalidResponse
        }
        return url
    }

    private func requireCurrentGeneration(_ expected: UInt64) throws {
        guard generation == expected else {
            throw StaleOperationError()
        }
    }

    private func requireCurrentPoll(
        generation expectedGeneration: UInt64,
        pollID expectedPollID: UInt64
    ) throws {
        guard generation == expectedGeneration,
            latestPollID == expectedPollID
        else {
            throw StaleOperationError()
        }
    }

    private func fail(
        _ failure: WebQRLoginFailure,
        generation expected: UInt64
    ) -> WebQRLoginState {
        guard generation == expected else {
            return state
        }
        activeChallenge = nil
        state = .failed(failure)
        return state
    }

    private func resetIfCurrent(_ expected: UInt64) {
        guard generation == expected else { return }
        activeChallenge = nil
        state = .signedOut
    }

    private static func isValidQRCodeKey(_ key: String) -> Bool {
        key.utf8.count == 32 && !key.utf8.contains(where: { $0 < 0x21 || $0 > 0x7E })
    }

    private static func isValidQRCodeURL(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == qrCodeHost
            && url.user == nil
            && url.password == nil
    }

    private static func pendingCredential(
        from response: HTTPResponse,
        generation: UInt64
    ) -> PendingCredential? {
        let allowedNames = Set(WebCredentialCookieName.allCases.map(\.rawValue))
        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: response.headers,
            for: productionBaseURL
        ).filter { allowedNames.contains($0.name) }
        guard cookies.count == allowedNames.count,
            Set(cookies.map(\.name)) == allowedNames
        else {
            return nil
        }
        let credentialCookies: [WebCredentialCookie] = cookies.compactMap { cookie in
            guard let name = WebCredentialCookieName(rawValue: cookie.name),
                let expiresAt = cookie.expiresDate
            else {
                return nil
            }
            return WebCredentialCookie(
                name: name,
                value: cookie.value,
                domain: cookie.domain,
                path: cookie.path,
                isSecure: cookie.isSecure,
                isHTTPOnly: cookie.isHTTPOnly,
                expiresAt: expiresAt
            )
        }
        guard let credential = try? WebCredential(cookies: credentialCookies) else {
            return nil
        }
        return PendingCredential(
            generation: generation,
            credential: credential
        )
    }
}

private struct ActiveChallenge: Sendable {
    let generation: UInt64
    let key: String
    let qrCode: WebQRCode
}

private struct PendingCredential: Sendable {
    let generation: UInt64
    let credential: WebCredential
}

private struct StaleOperationError: Error {}

private struct GenerateEnvelope: Decodable, Sendable {
    let code: Int
    let data: GenerateData?
}

private struct GenerateData: Decodable, Sendable {
    let url: String
    let qrcodeKey: String

    private enum CodingKeys: String, CodingKey {
        case url
        case qrcodeKey = "qrcode_key"
    }
}

private struct PollEnvelope: Decodable, Sendable {
    let code: Int
    let data: PollData?
}

/// 只解码状态码；URL、refresh_token 与 message 不进入内存模型。
private struct PollData: Decodable, Sendable {
    let code: Int
}
