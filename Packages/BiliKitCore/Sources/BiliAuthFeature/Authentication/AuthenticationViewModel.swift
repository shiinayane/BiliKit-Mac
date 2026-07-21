import BiliApplication
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
public final class AuthenticationViewModel {
    public private(set) var state: AuthenticationState = .signedOut
    public private(set) var qrCodeImage: CGImage?

    public var isSignedIn: Bool {
        state == .signedIn
    }

    public var canCancelFailure: Bool {
        retryAction == .login
    }

    public var retryButtonTitle: String {
        retryAction == .logout ? "重试退出" : "重试"
    }

    public var canClearLocalCredentials: Bool {
        if case .failed = state {
            return retryAction == .restore
        }
        return false
    }

    @ObservationIgnored private let service: any AuthenticationServicing
    @ObservationIgnored private let qrCodeProvider:
        any AuthenticationQRCodeProviding
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let pollTimeout: Duration
    @ObservationIgnored private let maximumPollAttempts: Int
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var retryAction: RetryAction = .login

    public init(
        service: any AuthenticationServicing,
        qrCodeProvider: any AuthenticationQRCodeProviding
    ) {
        self.service = service
        self.qrCodeProvider = qrCodeProvider
        pollInterval = .seconds(2)
        pollTimeout = .seconds(180)
        maximumPollAttempts = 90
    }

    init(
        service: any AuthenticationServicing,
        qrCodeProvider: any AuthenticationQRCodeProviding,
        pollInterval: Duration,
        pollTimeout: Duration = .seconds(180),
        maximumPollAttempts: Int = 90
    ) {
        self.service = service
        self.qrCodeProvider = qrCodeProvider
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
        self.maximumPollAttempts = maximumPollAttempts
    }

    public func restoreIfNeeded() {
        guard state == .signedOut else { return }
        restore()
    }

    public func revalidate() {
        restore()
    }

    private func restore() {
        retryAction = .restore
        begin(state: .restoring) { [weak self] operationGeneration in
            guard let self else { return }
            let nextState = await service.restore()
            await apply(nextState, generation: operationGeneration)
        }
    }

    public func startLogin() {
        retryAction = .login
        begin(state: .requestingQRCode) { [weak self] operationGeneration in
            guard let self else { return }
            let requested = await service.requestQRCode()
            guard await apply(requested, generation: operationGeneration) else {
                return
            }
            await pollUntilTerminal(generation: operationGeneration)
        }
    }

    public func retry() {
        switch state {
        case .expired:
            startLogin()
        case .failed:
            switch retryAction {
            case .restore:
                restore()
            case .login:
                startLogin()
            case .logout:
                logout()
            }
        default:
            break
        }
    }

    public func cancelLogin() {
        begin(state: state) { [weak self] operationGeneration in
            guard let self else { return }
            let nextState = await service.cancelLogin()
            await apply(nextState, generation: operationGeneration)
        }
    }

    public func logout() {
        retryAction = .logout
        begin(state: .signingOut) { [weak self] operationGeneration in
            guard let self else { return }
            let nextState = await service.logout()
            await apply(nextState, generation: operationGeneration)
        }
    }

    public func clearLocalCredentials() {
        guard canClearLocalCredentials else { return }
        logout()
    }

    public func cancelTransientWork() {
        switch state {
        case .restoring, .requestingQRCode, .awaitingScan, .awaitingConfirmation,
             .finalizing, .expired:
            cancelLogin()
        case .failed:
            if retryAction == .login {
                cancelLogin()
            }
        case .signedOut, .signedIn, .signingOut:
            break
        }
    }

    public func waitForCurrentTask() async {
        await task?.value
    }

    private func begin(
        state initialState: AuthenticationState,
        operation: @escaping @MainActor (Int) async -> Void
    ) {
        generation += 1
        let operationGeneration = generation
        task?.cancel()
        task = nil
        state = initialState
        if initialState != .awaitingScan,
           initialState != .awaitingConfirmation {
            qrCodeImage = nil
        }
        task = Task { [weak self] in
            await operation(operationGeneration)
            guard let self, generation == operationGeneration else { return }
            task = nil
        }
    }

    private func pollUntilTerminal(generation operationGeneration: Int) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: pollTimeout)
        var attempts = 0

        while generation == operationGeneration,
              state == .awaitingScan || state == .awaitingConfirmation {
            if attempts >= maximumPollAttempts || clock.now >= deadline {
                await expireLocalChallenge(generation: operationGeneration)
                return
            }

            do {
                let remaining = clock.now.duration(to: deadline)
                try await Task.sleep(for: min(pollInterval, remaining))
                try Task.checkCancellation()
            } catch {
                return
            }

            guard clock.now < deadline else {
                await expireLocalChallenge(generation: operationGeneration)
                return
            }

            let polled = await service.pollOnce()
            attempts += 1
            guard await apply(polled, generation: operationGeneration) else {
                return
            }
            if polled == .finalizing {
                let finalized = await service.finalizeLogin()
                _ = await apply(finalized, generation: operationGeneration)
                return
            }
        }
    }

    private func expireLocalChallenge(generation operationGeneration: Int) async {
        _ = await service.cancelLogin()
        guard generation == operationGeneration, !Task.isCancelled else {
            return
        }
        state = .expired
        qrCodeImage = nil
    }

    @discardableResult
    private func apply(
        _ nextState: AuthenticationState,
        generation operationGeneration: Int
    ) async -> Bool {
        guard generation == operationGeneration, !Task.isCancelled else {
            return false
        }
        state = nextState
        switch nextState {
        case .awaitingScan, .awaitingConfirmation:
            do {
                qrCodeImage = try await qrCodeProvider.makeQRCodeImage(scale: 12)
            } catch {
                state = .failed(.invalidResponse)
                qrCodeImage = nil
            }
        default:
            qrCodeImage = nil
        }
        return generation == operationGeneration && !Task.isCancelled
    }
}

private enum RetryAction {
    case restore
    case login
    case logout
}
