import BiliApplication
import BiliModels
import CoreGraphics
import Foundation
import Observation

/// App composition 可观察的已确认会话阶段（未解析、已登出、已登录），不携带账户身份；由
/// `sessionState` 投影。
public enum AccountSessionPhase: Sendable, Equatable {
    case unresolved
    case signedOut
    case signedIn
}

/// App composition 可观察的认证恢复阶段；不向 App shell 暴露 Application 层状态或失败细节。
public enum AuthenticationResolutionPhase: Sendable, Equatable {
    /// 登录流程中（取码、等待扫码、确认、写入）或登出中。
    case other
    case restoring
    case signedIn
    case signedOut
    case failed
}

/// 拥有恢复、登录、轮询与登出的单一 UI Task，并仅发布非秘密认证状态和二维码图像。
///
/// `operationTask`（`LatestTask`）只保留最新操作：新操作开始即取消旧 Task，旧结果经 `isCurrent`
/// 丢弃、不写回状态；取消登录本身也是一次替换。`AuthenticationView` 消失时调用
/// `cancelPresentedLoginWork`，窗口关闭时 App 调用 `cancelTransientWork`（连同启动恢复）。
/// 轮询同时受总时限与次数上限约束。Cookie、QR key 与完整 URL 始终留在 `BiliAuth` adapter（见
/// SECURITY-MODEL §1），失败重试也保持原操作类型，避免把登出失败误当成登录失败。
@MainActor
@Observable
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

    public var sessionScope: AccountSessionScope {
        switch sessionState {
        case .unresolved:
            .unresolved
        case .signedOut:
            .signedOut
        case .signedIn(let identity):
            .signedIn(accountID: identity?.id)
        }
    }

    public var resolutionPhase: AuthenticationResolutionPhase {
        switch state {
        case .restoring:
            .restoring
        case .signedIn:
            .signedIn
        case .signedOut:
            .signedOut
        case .failed:
            .failed
        default:
            .other
        }
    }

    /// 供 App composition 在登出意图开始时立即停止账户相关临时工作。
    public var isSigningOut: Bool { state == .signingOut }

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
        retryAction == .logout
            ? AuthFeatureStrings.localized("重试退出")
            : AuthFeatureStrings.localized("重试")
    }

    public var canClearLocalCredentials: Bool {
        if case .failed = state {
            return retryAction == .restore
        }
        return false
    }

    /// 等待给定时长后返回；被取消时抛出。
    typealias PollWait = @Sendable (Duration) async throws -> Void

    @ObservationIgnored private let service: any AuthenticationServicing
    @ObservationIgnored private let qrCodeProvider: any AuthenticationQRCodeProviding
    /// 本地兜底时限：远端一直没有给出终态（过期、确认或失败）时，轮询满 180 秒即本地判为过期。
    ///
    /// 调短会让用户来不及扫码确认，调长则在远端异常时多发轮询请求。
    private static let pollTimeout: Duration = .seconds(180)
    /// 扫码状态的轮询间隔；调短更快感知确认但多发请求，调长则确认后要多等一会儿才登录。
    private static let pollInterval: Duration = .seconds(2)
    /// 一次挑战最多发出的轮询请求数：按轮询间隔走满时限的次数，两者任一先到即本地过期。
    private static let maximumPollAttempts = Int((pollTimeout / pollInterval).rounded(.up))

    /// 两次轮询之间的等待，是时钟边界；public init 按要求的时长真实等待。
    @ObservationIgnored private let waitBeforePoll: PollWait
    @ObservationIgnored private let operationTask = LatestTask()
    /// 启动恢复只发起一次；`revalidate` 等显式复核也会置位，之后 `restoreIfNeeded` 不再重复恢复。
    @ObservationIgnored private var didStartInitialRestore = false
    /// 最近一次操作的类型：决定重试走恢复、登录还是登出，以及失败页是否提供取消与清除本机登录状态。
    @ObservationIgnored private var retryAction: RetryAction = .login

    public convenience init(
        service: any AuthenticationServicing,
        qrCodeProvider: any AuthenticationQRCodeProviding
    ) {
        self.init(
            service: service,
            qrCodeProvider: qrCodeProvider,
            waitBeforePoll: { try await Task.sleep(for: $0) }
        )
    }

    init(
        service: any AuthenticationServicing,
        qrCodeProvider: any AuthenticationQRCodeProviding,
        waitBeforePoll: @escaping PollWait
    ) {
        self.service = service
        self.qrCodeProvider = qrCodeProvider
        self.waitBeforePoll = waitBeforePoll
    }

    public func restoreIfNeeded() {
        guard !didStartInitialRestore else { return }
        didStartInitialRestore = true
        restore()
    }

    public func revalidate() {
        guard state != .signingOut else { return }
        didStartInitialRestore = true
        restore()
    }

    public func revalidateAfterExternalSessionChange() {
        guard state != .signingOut else { return }
        didStartInitialRestore = true
        retryAction = .restore
        begin(state: .restoring) { [weak self] isCurrent in
            guard let self else { return }
            let nextState = await service.restoreAfterExternalSessionChange()
            await apply(
                nextState,
                isCurrent: isCurrent,
                commitsConfirmedSession: true
            )
        }
    }

    private func restore() {
        retryAction = .restore
        begin(state: .restoring) { [weak self] isCurrent in
            guard let self else { return }
            let nextState = await service.restore()
            await apply(
                nextState,
                isCurrent: isCurrent,
                commitsConfirmedSession: true
            )
        }
    }

    public func startLogin() {
        retryAction = .login
        begin(state: .requestingQRCode) { [weak self] isCurrent in
            guard let self else { return }
            let requested = await service.requestQRCode()
            guard await apply(requested, isCurrent: isCurrent) else {
                return
            }
            await pollUntilTerminal(isCurrent: isCurrent)
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
        begin(state: state) { [weak self] isCurrent in
            guard let self else { return }
            let nextState = await service.cancelLogin()
            await apply(nextState, isCurrent: isCurrent)
        }
    }

    public func logout() {
        guard state != .signingOut else { return }
        retryAction = .logout
        begin(state: .signingOut) { [weak self] isCurrent in
            guard let self else { return }
            let nextState = await service.logout()
            await apply(
                nextState,
                isCurrent: isCurrent,
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
        case .requestingQRCode, .awaitingScan, .awaitingConfirmation, .expired:
            cancelLogin()
        case .failed:
            if retryAction == .login {
                cancelLogin()
            }
        case .signedOut, .restoring, .finalizing, .signedIn, .signingOut:
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
        await operationTask.wait()
    }

    private func begin(
        state initialState: AuthenticationState,
        operation: @escaping @MainActor (_ isCurrent: @escaping LatestTask.IsCurrent) async -> Void
    ) {
        state = initialState
        if initialState != .awaitingScan,
            initialState != .awaitingConfirmation
        {
            qrCodeImage = nil
        }
        operationTask.replace(operation)
    }

    private func pollUntilTerminal(isCurrent: LatestTask.IsCurrent) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.pollTimeout)
        var attempts = 0

        while isCurrent(),
            state == .awaitingScan || state == .awaitingConfirmation
        {
            if attempts >= Self.maximumPollAttempts || clock.now >= deadline {
                await expireLocalChallenge(isCurrent: isCurrent)
                return
            }

            do {
                let remaining = clock.now.duration(to: deadline)
                try await waitBeforePoll(min(Self.pollInterval, remaining))
                try Task.checkCancellation()
            } catch {
                return
            }

            guard clock.now < deadline else {
                await expireLocalChallenge(isCurrent: isCurrent)
                return
            }

            let polled = await service.pollOnce()
            attempts += 1
            guard await apply(polled, isCurrent: isCurrent) else {
                return
            }
            if polled == .finalizing {
                let finalized = await service.finalizeLogin()
                _ = await apply(
                    finalized,
                    isCurrent: isCurrent,
                    commitsConfirmedSession: true
                )
                return
            }
        }
    }

    private func expireLocalChallenge(isCurrent: LatestTask.IsCurrent) async {
        _ = await service.cancelLogin()
        guard isCurrent() else { return }
        state = .expired
        qrCodeImage = nil
    }

    @discardableResult
    private func apply(
        _ nextState: AuthenticationState,
        isCurrent: LatestTask.IsCurrent,
        commitsConfirmedSession: Bool = false
    ) async -> Bool {
        guard isCurrent() else { return false }
        state = nextState
        if commitsConfirmedSession {
            updateConfirmedSession(from: nextState)
        }
        switch nextState {
        case .awaitingScan, .awaitingConfirmation:
            do {
                let image = try await qrCodeProvider.makeQRCodeImage(scale: 12)
                guard isCurrent() else { return false }
                qrCodeImage = image
            } catch {
                guard isCurrent() else { return false }
                state = .failed(.invalidResponse)
                qrCodeImage = nil
            }
        default:
            qrCodeImage = nil
        }
        return isCurrent()
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
