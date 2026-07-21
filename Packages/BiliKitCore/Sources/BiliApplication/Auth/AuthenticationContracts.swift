import CoreGraphics

public enum AuthenticationState: Sendable, Equatable {
    case signedOut
    case restoring
    case requestingQRCode
    case awaitingScan
    case awaitingConfirmation
    case finalizing
    case signedIn
    case signingOut
    case expired
    case failed(AuthenticationFailure)
}

public enum AuthenticationFailure: Error, Sendable, Equatable {
    case network
    case serviceUnavailable
    case invalidResponse
    case credentialUnavailable
}

public protocol AuthenticationServicing: Sendable {
    func restore() async -> AuthenticationState
    func requestQRCode() async -> AuthenticationState
    func pollOnce() async -> AuthenticationState
    func finalizeLogin() async -> AuthenticationState
    func makeQRCodeImage(scale: Int) async throws -> CGImage?
    func cancelLogin() async -> AuthenticationState
    func logout() async -> AuthenticationState
}
