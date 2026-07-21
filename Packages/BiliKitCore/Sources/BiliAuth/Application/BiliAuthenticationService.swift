import BiliApplication
import CoreGraphics
import Foundation

public actor BiliAuthenticationService: AuthenticationServicing {
    private var loginSession: WebQRLoginSession
    private var authorizer: BiliCredentialRequestAuthorizer
    private let loginSessionFactory: @Sendable () -> WebQRLoginSession
    private let authorizerFactory: @Sendable () -> BiliCredentialRequestAuthorizer

    private var state: AuthenticationState = .signedOut
    private var qrCode: WebQRCode?
    private var generation: UInt64 = 0
    private var requiresLogout = false

    public init() {
        loginSession = WebQRLoginSession()
        authorizer = BiliCredentialRequestAuthorizer()
        loginSessionFactory = { WebQRLoginSession() }
        authorizerFactory = { BiliCredentialRequestAuthorizer() }
    }

    init(
        loginSession: WebQRLoginSession,
        authorizer: BiliCredentialRequestAuthorizer,
        loginSessionFactory: @escaping @Sendable () -> WebQRLoginSession,
        authorizerFactory: @escaping @Sendable () -> BiliCredentialRequestAuthorizer
    ) {
        self.loginSession = loginSession
        self.authorizer = authorizer
        self.loginSessionFactory = loginSessionFactory
        self.authorizerFactory = authorizerFactory
    }

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
        case let .awaitingScan(code):
            qrCode = code
            return .awaitingScan
        case let .awaitingConfirmation(code):
            qrCode = code
            return .awaitingConfirmation
        case .awaitingCredentialValidation:
            qrCode = nil
            return .finalizing
        case .expired:
            qrCode = nil
            return .expired
        case let .failed(failure):
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
