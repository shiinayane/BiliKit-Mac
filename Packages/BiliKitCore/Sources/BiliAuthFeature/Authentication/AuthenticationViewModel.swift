import BiliApplication
import BiliModels
import CoreGraphics
import Foundation
import Observation

public enum AccountSessionPhase: Sendable, Equatable {
    case unresolved
    case signedOut
    case signedIn
}

/// 供产品界面使用的诚实账户呈现状态；不可用与确定登出保持区分。
public enum AccountPresentationState: Sendable, Equatable {
    case resolving
    case unavailable
    case signedOut
    case signedIn(AccountIdentity?)

    public var displayName: String? {
        guard case .signedIn(let identity) = self else { return nil }
        return identity?.displayName
    }

    public var avatarURL: URL? {
        guard case .signedIn(let identity) = self else { return nil }
        return identity?.avatarURL
    }
}

@MainActor
@Observable
/// 拥有恢复、登录、轮询与登出的单一 UI Task，并仅发布非秘密认证状态和二维码图像。
///
/// generation 拒绝旧操作写回；轮询同时受总时限与次数上限约束。Cookie、QR key 与完整 URL
/// 始终留在 `BiliAuth` adapter，失败重试也保持原操作类型，避免把登出失败误当成登录失败。
public final class AuthenticationViewModel {
    public private(set) var state: AuthenticationState = .signedOut
    public private(set) var sessionState: AccountSessionState = .unresolved
    public private(set) var qrCodeImage: CGImage?

    public var sessionPhase: AccountSessionPhase {
        switch sessionState {
        case .unresolved:
            .unresolved
        case .signedOut:
            .signedOut
        case .signedIn:
            .signedIn
        }
    }

    public var accountPresentationState: AccountPresentationState {
        switch sessionState {
        case .unresolved:
            if case .failed = state {
                return .unavailable
            }
            return .resolving
        case .signedOut:
            return .signedOut
        case .signedIn(let identity):
            return .signedIn(identity)
        }
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
    @ObservationIgnored private let qrCodeProvider: any AuthenticationQRCodeProviding
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let pollTimeout: Duration
    @ObservationIgnored private let maximumPollAttempts: Int
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var didStartInitialRestore = false
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
        guard !didStartInitialRestore else { return }
        didStartInitialRestore = true
        restore()
    }

    public func revalidate() {
        didStartInitialRestore = true
        restore()
    }

    private func restore() {
        retryAction = .restore
        begin(state: .restoring) { [weak self] operationGeneration in
            guard let self else { return }
            let nextState = await service.restore()
            await apply(
                nextState,
                generation: operationGeneration,
                commitsConfirmedSession: true
            )
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
            await apply(
                nextState,
                generation: operationGeneration,
                commitsConfirmedSession: true
            )
        }
    }

    public func clearLocalCredentials() {
        guard canClearLocalCredentials else { return }
        logout()
    }

    /// Sheet 关闭时只取消由该登录界面发起的挑战，不接管窗口级启动恢复。
    public func cancelPresentedLoginWork() {
        switch state {
        case .requestingQRCode, .awaitingScan, .awaitingConfirmation,
            .finalizing, .expired:
            cancelLogin()
        case .failed:
            if retryAction == .login {
                cancelLogin()
            }
        case .signedOut, .restoring, .signedIn, .signingOut:
            break
        }
    }

    /// 窗口生命周期结束时取消所有临时认证工作，包括启动恢复。
    public func cancelTransientWork() {
        if state == .restoring {
            cancelLogin()
        } else {
            cancelPresentedLoginWork()
        }
    }

    public func waitForCurrentTask() async {
        await task?.value
    }

    func taskSnapshotForTesting() -> Task<Void, Never>? {
        task
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
            initialState != .awaitingConfirmation
        {
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
            state == .awaitingScan || state == .awaitingConfirmation
        {
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
                _ = await apply(
                    finalized,
                    generation: operationGeneration,
                    commitsConfirmedSession: true
                )
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
        generation operationGeneration: Int,
        commitsConfirmedSession: Bool = false
    ) async -> Bool {
        guard generation == operationGeneration, !Task.isCancelled else {
            return false
        }
        state = nextState
        if commitsConfirmedSession {
            updateConfirmedSession(from: nextState)
        }
        switch nextState {
        case .awaitingScan, .awaitingConfirmation:
            do {
                let image = try await qrCodeProvider.makeQRCodeImage(scale: 12)
                guard generation == operationGeneration, !Task.isCancelled else {
                    return false
                }
                qrCodeImage = image
            } catch {
                guard generation == operationGeneration, !Task.isCancelled else {
                    return false
                }
                state = .failed(.invalidResponse)
                qrCodeImage = nil
            }
        default:
            qrCodeImage = nil
        }
        return generation == operationGeneration && !Task.isCancelled
    }

    private func updateConfirmedSession(from nextState: AuthenticationState) {
        switch nextState {
        case .signedOut:
            sessionState = .signedOut
        case .signedIn(let identity):
            sessionState = .signedIn(identity)
        case .restoring, .requestingQRCode, .awaitingScan,
            .awaitingConfirmation, .finalizing, .signingOut, .expired, .failed:
            break
        }
    }
}

private enum RetryAction {
    case restore
    case login
    case logout
}
