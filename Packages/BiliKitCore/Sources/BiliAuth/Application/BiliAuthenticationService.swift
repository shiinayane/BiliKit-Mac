import BiliApplication
import CoreGraphics
import Foundation

/// 认证流程 owner，串行协调 QR session、凭据验证、Keychain authorizer 与登出。
///
/// `generation` 隔离旧操作；`requiresLogout` 阻止凭据状态不确定时伪装成安全 signed-out。
/// 新 QR 登录须校验并持久化成功才发布 `.signedIn`；恢复路径会重新验证既存凭据。
public actor BiliAuthenticationService: AuthenticationServicing {
    /// 会话校验（nav）的 path：恢复与换号复核唯一按账户读取的请求，App Composition 用它声明本服务授权器的
    /// allowlist。
    ///
    /// BiliAPI 取 WBI key 也读同一 path，但那是永不带凭据的匿名请求；BiliAuth 不能依赖 BiliAPI、两边也没有
    /// 共同的更低层能放 endpoint 知识，所以各留一份（另一份在 `BiliAPIClient.wbiKey`）。见 SECURITY-MODEL §3。
    public static let sessionValidationPath = "/x/web-interface/nav"

    private var loginSession: TVQRLoginSession
    private var authorizer: BiliCredentialRequestAuthorizer
    private let loginSessionFactory: @Sendable () -> TVQRLoginSession
    private let authorizerFactory: @Sendable () -> BiliCredentialRequestAuthorizer
    private let additionalSessionInvalidators: [any AuthenticatedSessionInvalidating]

    private var state: AuthenticationState = .signedOut
    private var qrCode: TVQRCode?
    /// 每次恢复、请求二维码、取消登录与登出时递增，轮询与提交凭据只读取不递增。
    ///
    /// 各操作 await 之后比对，不等就不再写 `state`，直接返回新操作已发布的状态。
    private var generation: UInt64 = 0
    /// 凭据可能仍在 Keychain（已登录、复核中或复核失败）时为 true：期间拒绝新的 QR 登录与取消登录，
    /// 只在登出成功、复核确认未登录，或扫码登录的远端校验判定未登录时清除。
    private var requiresLogout = false

    public init(
        accountReadAllowedPaths: Set<String>,
        additionalSessionInvalidators: [any AuthenticatedSessionInvalidating] = []
    ) {
        loginSession = TVQRLoginSession()
        authorizer = BiliCredentialRequestAuthorizer(
            allowedPaths: accountReadAllowedPaths
        )
        loginSessionFactory = { TVQRLoginSession() }
        authorizerFactory = {
            BiliCredentialRequestAuthorizer(
                allowedPaths: accountReadAllowedPaths
            )
        }
        self.additionalSessionInvalidators = additionalSessionInvalidators
    }

    init(
        loginSession: TVQRLoginSession,
        authorizer: BiliCredentialRequestAuthorizer,
        loginSessionFactory: @escaping @Sendable () -> TVQRLoginSession,
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
        await restore(propagatesSessionInvalidation: true)
    }

    /// 其他窗口已经推进全局 transport epoch；这里只复核凭据，避免重复传播同一变化。
    public func restoreAfterExternalSessionChange() async -> AuthenticationState {
        await restore(propagatesSessionInvalidation: false)
    }

    private func restore(
        propagatesSessionInvalidation: Bool
    ) async -> AuthenticationState {
        guard state != .signingOut else { return state }
        generation &+= 1
        let operationGeneration = generation
        let hadAuthenticatedSession = requiresLogout
        let activeAuthorizer = authorizer
        qrCode = nil
        state = .restoring
        // 复核完成前凭据是否仍在 Keychain 未知：阻止并发的 QR 登录，并让中途取消保持"需先登出"。
        requiresLogout = true

        do {
            let restored = try await activeAuthorizer.restoreAccountSession()
            guard generation == operationGeneration else { return state }
            switch restored {
            case .signedOut(let hadCredential):
                if propagatesSessionInvalidation,
                    hadAuthenticatedSession || hadCredential
                {
                    for invalidator in additionalSessionInvalidators {
                        await invalidator.invalidateAuthenticatedSession()
                        guard generation == operationGeneration else { return state }
                    }
                }
                requiresLogout = false
                state = .signedOut
            case .signedIn(let identity):
                requiresLogout = true
                state = .signedIn(identity)
            }
        } catch is CancellationError {
            guard generation == operationGeneration else { return state }
            // 复核被取消时凭据状态未知，不能伪装成安全的未登录；保留可重试的失败态。
            state = .failed(.network)
        } catch let error as BiliRequestAuthorizationError {
            guard generation == operationGeneration else { return state }
            // 这里只会是凭据存储或远端校验不可用：凭据是否仍有效未知，保持需先登出，
            // 不在此转为未登录。
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
            let qrState = try await activeSession.requestQRCode()
            guard generation == operationGeneration else { return state }
            state = map(qrState)
        } catch is CancellationError {
            guard generation == operationGeneration else { return state }
            state = .signedOut
        } catch let error as TVQRLoginFailure {
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
            let qrState = try await activeSession.pollOnce()
            guard generation == operationGeneration else { return state }
            state = map(qrState)
        } catch is CancellationError {
            guard generation == operationGeneration else { return state }
            state = .signedOut
        } catch let error as TVQRLoginFailure {
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
            switch stored {
            case .signedOut:
                requiresLogout = false
                state = .failed(.serviceUnavailable)
            case .signedIn(let identity):
                requiresLogout = true
                state = .signedIn(identity)
            }
        } catch is CancellationError {
            guard generation == operationGeneration else { return state }
            qrCode = nil
            state = .signedOut
        } catch let error as TVQRLoginFailure {
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

    /// 先取消 QR generation，再删除凭据、失效认证 API 并重建其他 session，最后发布结果。
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

        for invalidator in additionalSessionInvalidators {
            await invalidator.invalidateAuthenticatedSession()
        }
        await activeSession.invalidateSession()
        activeAuthorizer.invalidateSession()
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

    private func map(_ qrState: TVQRLoginState) -> AuthenticationState {
        switch qrState {
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

    private static func map(_ failure: TVQRLoginFailure) -> AuthenticationFailure {
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
            .missingCredential, .expiredCredential, .invalidCredential, .accountMismatch:
            .invalidResponse
        }
    }
}
