import BiliApplication
import CoreGraphics
import Foundation

/// 认证流程 owner，串行协调 QR session、凭据验证、Keychain authorizer 与登出。
///
/// `generation` 隔离旧操作；`requiresLogout` 阻止凭据状态不确定时伪装成安全 signed-out。
/// 新 QR 登录须校验并持久化成功才发布 `.signedIn`；恢复路径会重新验证既存凭据。
public actor BiliAuthenticationService: AuthenticationServicing {
    private var loginSession: WebQRLoginSession
    private var authorizer: BiliCredentialRequestAuthorizer
    private let loginSessionFactory: @Sendable () -> WebQRLoginSession
    private let authorizerFactory: @Sendable () -> BiliCredentialRequestAuthorizer
    private let additionalSessionInvalidators: [any AuthenticatedSessionInvalidating]

    private var state: AuthenticationState = .signedOut
    private var qrCode: WebQRCode?
    private var generation: UInt64 = 0
    private var requiresLogout = false

    public init(
        additionalSessionInvalidators: [any AuthenticatedSessionInvalidating] = []
    ) {
        loginSession = WebQRLoginSession()
        authorizer = BiliCredentialRequestAuthorizer()
        loginSessionFactory = { WebQRLoginSession() }
        authorizerFactory = { BiliCredentialRequestAuthorizer() }
        self.additionalSessionInvalidators = additionalSessionInvalidators
    }

    init(
        loginSession: WebQRLoginSession,
        authorizer: BiliCredentialRequestAuthorizer,
        loginSessionFactory: @escaping @Sendable () -> WebQRLoginSession,
        authorizerFactory: @escaping @Sendable () -> BiliCredentialRequestAuthorizer,
        additionalSessionInvalidators: [any AuthenticatedSessionInvalidating] = []
    ) {
        self.loginSession = loginSession
        self.authorizer = authorizer
        self.loginSessionFactory = loginSessionFactory
        self.authorizerFactory = authorizerFactory
        self.additionalSessionInvalidators = additionalSessionInvalidators
    }

    /// 从 Keychain 恢复后再次向登录态 endpoint 验证；临时网络失败不会删除凭据。
    public func restore() async -> AuthenticationState {
        generation &+= 1
        let operationGeneration = generation
        let activeAuthorizer = authorizer
        qrCode = nil
        state = .restoring

        do {
            let restored = try await activeAuthorizer.restoreLoginState()
            guard generation == operationGeneration else { return state }
            requiresLogout = restored
            state = restored ? .signedIn : .signedOut
        } catch is CancellationError {
            guard generation == operationGeneration else { return state }
            state = .signedOut
        } catch let error as BiliRequestAuthorizationError {
            guard generation == operationGeneration else { return state }
            // restoreLoginState only throws after credential access or validation
            // becomes unavailable. Keep logout as the sole signed-out transition.
            requiresLogout = true
            state = .failed(Self.map(error))
        } catch {
            guard generation == operationGeneration else { return state }
            state = .failed(.network)
        }
        return state
    }

    public func requestQRCode() async -> AuthenticationState {
        guard !requiresLogout else { return state }
        generation &+= 1
        let operationGeneration = generation
        let activeSession = loginSession
        qrCode = nil
        state = .requestingQRCode

        do {
            let webState = try await activeSession.requestQRCode()
            guard generation == operationGeneration else { return state }
            state = map(webState)
        } catch is CancellationError {
            guard generation == operationGeneration else { return state }
            state = .signedOut
        } catch let error as WebQRLoginFailure {
            guard generation == operationGeneration else { return state }
            state = .failed(Self.map(error))
        } catch {
            guard generation == operationGeneration else { return state }
            state = .failed(.network)
        }
        return state
    }

    public func pollOnce() async -> AuthenticationState {
        guard state == .awaitingScan || state == .awaitingConfirmation else {
            return state
        }
        let operationGeneration = generation
        let activeSession = loginSession

        do {
            let webState = try await activeSession.pollOnce()
            guard generation == operationGeneration else { return state }
            state = map(webState)
        } catch is CancellationError {
            guard generation == operationGeneration else { return state }
            state = .signedOut
        } catch let error as WebQRLoginFailure {
            guard generation == operationGeneration else { return state }
            state = .failed(Self.map(error))
        } catch {
            guard generation == operationGeneration else { return state }
            state = .failed(.network)
        }
        return state
    }

    /// 消费一次待提交凭据，在同一 QR generation 内完成远端验证与原子持久化。
    public func finalizeLogin() async -> AuthenticationState {
        guard state == .finalizing else { return state }
        let operationGeneration = generation
        let activeSession = loginSession

        do {
            let stored = try await activeSession.validateAndStorePendingCredential()
            guard generation == operationGeneration else { return state }
            qrCode = nil
            requiresLogout = stored
            state = stored ? .signedIn : .failed(.serviceUnavailable)
        } catch is CancellationError {
            guard generation == operationGeneration else { return state }
            qrCode = nil
            state = .signedOut
        } catch let error as WebQRLoginFailure {
            guard generation == operationGeneration else { return state }
            qrCode = nil
            state = .failed(Self.map(error))
        } catch {
            guard generation == operationGeneration else { return state }
            qrCode = nil
            state = .failed(.invalidResponse)
        }
        return state
    }

    public func makeQRCodeImage(scale: Int) async throws -> CGImage? {
        try qrCode?.makeCGImage(scale: scale)
    }

    public func cancelLogin() async -> AuthenticationState {
        guard !requiresLogout, state != .signingOut else { return state }
        generation &+= 1
        let activeSession = loginSession
        await activeSession.cancel()
        qrCode = nil
        state = .signedOut
        return state
    }

    /// 先取消临时工作并删除本地凭据，再失效所有认证 session，最后发布退出结果。
    ///
    /// 删除 Keychain 失败时仍重建网络 session，但保持失败状态，不能声称本机已安全退出。
    public func logout() async -> AuthenticationState {
        generation &+= 1
        let activeSession = loginSession
        let activeAuthorizer = authorizer
        state = .signingOut

        await activeSession.cancel()
        qrCode = nil

        let credentialDeleted: Bool
        do {
            try activeAuthorizer.deleteStoredCredential()
            credentialDeleted = true
        } catch {
            credentialDeleted = false
        }

        await activeSession.invalidateSession()
        activeAuthorizer.invalidateSession()
        for invalidator in additionalSessionInvalidators {
            await invalidator.invalidateAuthenticatedSession()
        }
        loginSession = loginSessionFactory()
        authorizer = authorizerFactory()

        if credentialDeleted {
            requiresLogout = false
            state = .signedOut
        } else {
            state = .failed(.credentialUnavailable)
        }
        return state
    }

    private func map(_ webState: WebQRLoginState) -> AuthenticationState {
        switch webState {
        case .signedOut:
            qrCode = nil
            return .signedOut
        case .requestingQRCode:
            qrCode = nil
            return .requestingQRCode
        case .awaitingScan(let code):
            qrCode = code
            return .awaitingScan
        case .awaitingConfirmation(let code):
            qrCode = code
            return .awaitingConfirmation
        case .awaitingCredentialValidation:
            qrCode = nil
            return .finalizing
        case .expired:
            qrCode = nil
            return .expired
        case .failed(let failure):
            qrCode = nil
            return .failed(Self.map(failure))
        }
    }

    private static func map(_ failure: WebQRLoginFailure) -> AuthenticationFailure {
        switch failure {
        case .network, .httpStatus:
            .network
        case .credentialStoreUnavailable:
            .credentialUnavailable
        case .serviceRejected:
            .serviceUnavailable
        case .noActiveChallenge, .responseTooLarge, .nonJSONResponse,
            .invalidResponse, .incompleteCredential, .unsupportedStatus:
            .invalidResponse
        }
    }

    private static func map(
        _ error: BiliRequestAuthorizationError
    ) -> AuthenticationFailure {
        switch error {
        case .validationUnavailable:
            .network
        case .credentialStoreUnavailable:
            .credentialUnavailable
        case .requestNotAllowed, .credentialHeaderAlreadyPresent,
            .missingCredential, .expiredCredential, .invalidCredential:
            .invalidResponse
        }
    }
}
