import BiliNetworking
import Foundation

/// 拥有一次 TV 端扫码登录的 challenge、轮询序列与尚未持久化的候选凭据。
///
/// 取码与轮询都是带 APP 签名的 POST（`BiliAppSigning`）。generation 隔离新旧二维码，poll ID 隔离同一二维码的并发
/// 轮询；取消或未知协议状态会失败关闭并清除临时秘密。成功响应仍须登录态验证后才能写入 Keychain。
public actor TVQRLoginSession {
    /// QR 生成与轮询唯一连接的来源，见 SECURITY-MODEL §2。
    private static let baseURL: URL = {
        guard let url = URL(string: "https://passport.bilibili.com") else {
            preconditionFailure("Static TV QR base URL must be valid")
        }
        return url
    }()
    private static let generatePath = "/x/passport-tv-login/qrcode/auth_code"
    private static let pollPath = "/x/passport-tv-login/qrcode/poll"
    /// 待显示二维码 URL 唯一允许的主机与路径，见 SECURITY-MODEL §2。
    private static let qrCodeHost = "passport.bilibili.com"
    private static let qrCodePath = "/x/passport-tv-login/h5/qrcode/auth"
    /// 取码与轮询都要带的设备标识；TV 协议接受 `0`，不发送任何真实设备信息。
    private static let localID = "0"

    public private(set) var state: TVQRLoginState = .signedOut

    private let httpClient: HTTPClient
    private let credentialStore: any AccountCredentialStoring
    private let transportInvalidator: (@Sendable () -> Void)?
    private let decoder = JSONDecoder()
    /// 每次请求二维码与取消时递增；challenge 与候选凭据记录发起时的值，响应返回后不等即丢弃结果。
    private var generation: UInt64 = 0
    private var activeChallenge: ActiveChallenge?
    private var pendingCredential: PendingCredential?
    /// 每次轮询与取消时递增，请求新二维码时归零；轮询响应返回时不是最新一次就丢弃，
    /// 旧轮询不能覆盖状态。
    private var latestPollID: UInt64 = 0

    public init() {
        let transport = AuthenticationHTTP.makeProductionTransport()
        httpClient = HTTPClient(transport: transport)
        credentialStore = KeychainAccountCredentialStore()
        transportInvalidator = { transport.invalidateAndCancel() }
    }

    /// 网络与 Keychain 两个系统边界；`init()` 由此接入认证专用 session 与 Keychain store。
    init(
        transport: any HTTPTransport,
        credentialStore: any AccountCredentialStoring
    ) {
        httpClient = HTTPClient(transport: transport)
        self.credentialStore = credentialStore
        if let invalidating = transport as? any HTTPTransportInvalidating {
            transportInvalidator = { invalidating.invalidateAndCancel() }
        } else {
            transportInvalidator = nil
        }
    }

    @discardableResult
    public func requestQRCode() async throws -> TVQRLoginState {
        generation &+= 1
        let operationGeneration = generation
        activeChallenge = nil
        pendingCredential = nil
        latestPollID = 0
        state = .requestingQRCode

        do {
            let response = try await sendSignedForm(
                path: Self.generatePath,
                parameters: ["local_id": Self.localID]
            )
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
                Self.isValidAuthCode(data.authCode),
                Self.isValidQRCodeURL(data.url, authCode: data.authCode)
            else {
                return fail(.invalidResponse, generation: operationGeneration)
            }

            let qrCode = TVQRCode(payload: data.url)
            activeChallenge = ActiveChallenge(
                generation: operationGeneration,
                authCode: data.authCode,
                qrCode: qrCode
            )
            state = .awaitingScan(qrCode)
            return state
        } catch is StaleOperationError {
            throw CancellationError()
        } catch is CancellationError {
            resetIfCurrent(operationGeneration)
            throw CancellationError()
        } catch let failure as TVQRLoginFailure {
            return fail(failure, generation: operationGeneration)
        } catch {
            return fail(.network, generation: operationGeneration)
        }
    }

    @discardableResult
    public func pollOnce() async throws -> TVQRLoginState {
        guard let challenge = activeChallenge,
            challenge.generation == generation
        else {
            state = .failed(.noActiveChallenge)
            return state
        }

        latestPollID &+= 1
        let pollID = latestPollID

        do {
            let response = try await sendSignedForm(
                path: Self.pollPath,
                parameters: ["auth_code": challenge.authCode, "local_id": Self.localID]
            )
            try Task.checkCancellation()
            try requireCurrentPoll(
                generation: challenge.generation,
                pollID: pollID
            )

            // 扫码状态在顶层 `code`，未扫码时 `data` 为 null。已确认的状态见 SECURITY-MODEL §2。
            let status: PollStatusEnvelope
            do {
                status = try decoder.decode(PollStatusEnvelope.self, from: response.body)
            } catch {
                return fail(.invalidResponse, generation: challenge.generation)
            }

            switch status.code {
            case 0:
                // 成功正文另行解码：结构不符只是没有候选凭据，后续校验以 `incompleteCredential` 失败关闭。
                let success = try? decoder.decode(PollSuccessEnvelope.self, from: response.body)
                pendingCredential = success?.data.credential(receivedAt: .now).map {
                    PendingCredential(generation: challenge.generation, credential: $0.credential)
                }
                activeChallenge = nil
                state = .awaitingCredentialValidation
                return state
            case 86_039:
                state = .awaitingScan(challenge.qrCode)
                return state
            case 86_090:
                // 已扫码待确认：协议文档与参考实现都列出这一状态；现场观察里扫码与确认一步完成，没有出现过。
                state = .awaitingConfirmation(challenge.qrCode)
                return state
            case 86_038:
                activeChallenge = nil
                state = .expired
                return state
            default:
                return fail(
                    .unsupportedStatus(status.code),
                    generation: challenge.generation
                )
            }
        } catch is StaleOperationError {
            throw CancellationError()
        } catch is CancellationError {
            resetIfCurrent(challenge.generation)
            throw CancellationError()
        } catch let failure as TVQRLoginFailure {
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
            throw TVQRLoginFailure.incompleteCredential
        }
        do {
            try credentialStore.save(pendingCredential.credential)
        } catch {
            throw TVQRLoginFailure.credentialStoreUnavailable
        }
        return result
    }

    private func takePendingCredential() throws -> PendingCredential {
        guard let pendingCredential else {
            throw TVQRLoginFailure.incompleteCredential
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
            throw TVQRLoginFailure.invalidResponse
        }
    }

    private func sendSignedForm(
        path: String,
        parameters: [String: String]
    ) async throws -> HTTPResponse {
        guard
            let request = AuthenticationHTTP.signedFormRequest(
                url: try endpoint(path: path),
                parameters: parameters
            )
        else {
            throw TVQRLoginFailure.invalidResponse
        }
        return try await send(request)
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
                throw TVQRLoginFailure.httpStatus(status)
            case .nonHTTPResponse:
                throw TVQRLoginFailure.network
            }
        } catch {
            throw TVQRLoginFailure.network
        }

        guard response.body.count <= AuthenticationHTTP.maximumResponseSize else {
            throw TVQRLoginFailure.responseTooLarge
        }
        guard response.looksLikeJSON() else {
            throw TVQRLoginFailure.nonJSONResponse
        }
        return response
    }

    private func endpoint(path: String) throws -> URL {
        guard
            var components = URLComponents(
                url: Self.baseURL,
                resolvingAgainstBaseURL: false
            )
        else {
            throw TVQRLoginFailure.invalidResponse
        }
        components.path = path
        guard let url = components.url else {
            throw TVQRLoginFailure.invalidResponse
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
        _ failure: TVQRLoginFailure,
        generation expected: UInt64
    ) -> TVQRLoginState {
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

    /// `auth_code` 只接受 32 个 ASCII 十六进制字符（现场观察的形状）；其他形状按无效响应失败关闭，见 SECURITY-MODEL §2。
    private static func isValidAuthCode(_ code: String) -> Bool {
        ASCIIHexShape.matches(code, length: 32)
    }

    /// 精确 `https://passport.bilibili.com/x/passport-tv-login/h5/qrcode/auth?auth_code=<本次 auth_code>`：公开 HTTPS
    /// 基线（无 userinfo／fragment、端口缺省或 443）加固定主机与路径，query 只能有这一项且必须是本次的码，免得二维码
    /// 把用户的手机带去别处确认，见 SECURITY-MODEL §2。
    private static func isValidQRCodeURL(_ value: String, authCode: String) -> Bool {
        guard let url = URL(string: value),
            PublicHTTPSURLPolicy().allows(url),
            url.host?.lowercased() == qrCodeHost,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.path == qrCodePath,
            let queryItems = components.queryItems,
            queryItems.count == 1,
            queryItems[0].name == "auth_code",
            queryItems[0].value == authCode
        else {
            return false
        }
        return true
    }
}

private struct ActiveChallenge: Sendable {
    let generation: UInt64
    let authCode: String
    let qrCode: TVQRCode
}

private struct PendingCredential: Sendable {
    let generation: UInt64
    let credential: AccountCredential
}

private struct StaleOperationError: Error {}

private struct GenerateEnvelope: Decodable, Sendable {
    let code: Int
    let data: GenerateData?
}

private struct GenerateData: Decodable, Sendable {
    let url: String
    let authCode: String

    private enum CodingKeys: String, CodingKey {
        case url
        case authCode = "auth_code"
    }
}

/// 轮询响应只先读顶层状态码；`data` 只在成功时另行解码。
private struct PollStatusEnvelope: Decodable, Sendable {
    let code: Int
}

private struct PollSuccessEnvelope: Decodable, Sendable {
    let data: IssuedCredentialPayload
}
