import BiliApplication
import CoreGraphics
import Foundation
import Testing
@testable import BiliAuthFeature

struct AuthenticationViewModelTests {
    @Test
    @MainActor
    func drivesQRCodeConfirmationAndFinalizationToSignedIn() async {
        let service = AuthenticationServiceStub(
            requestStates: [.awaitingScan],
            pollStates: [.awaitingConfirmation, .finalizing],
            finalizeState: .signedIn
        )
        let model = AuthenticationViewModel(
            service: service,
            pollInterval: .zero
        )

        model.startLogin()
        await model.waitForCurrentTask()

        #expect(model.state == .signedIn)
        #expect(model.qrCodeImage == nil)
        #expect(
            await service.observedCalls()
                == ["request", "image", "poll", "image", "poll", "finalize"]
        )
    }

    @Test
    @MainActor
    func newerLoginIntentPreventsOldResultFromOverwritingState() async throws {
        let service = AuthenticationServiceStub(
            requestStates: [.failed(.network), .expired],
            firstRequestDelay: .milliseconds(50)
        )
        let model = AuthenticationViewModel(
            service: service,
            pollInterval: .zero
        )

        model.startLogin()
        try await Task.sleep(for: .milliseconds(5))
        model.startLogin()
        await model.waitForCurrentTask()
        try await Task.sleep(for: .milliseconds(60))

        #expect(model.state == .expired)
    }

    @Test
    @MainActor
    func restoreAndLogoutUseApplicationServiceWithoutExposingCredentials() async {
        let service = AuthenticationServiceStub(
            restoreState: .signedIn,
            logoutState: .signedOut
        )
        let model = AuthenticationViewModel(
            service: service,
            pollInterval: .zero
        )

        model.restoreIfNeeded()
        await model.waitForCurrentTask()
        #expect(model.state == .signedIn)

        model.logout()
        #expect(model.state == .signingOut)
        await model.waitForCurrentTask()

        #expect(model.state == .signedOut)
        #expect(await service.observedCalls() == ["restore", "logout"])
    }

    @Test
    @MainActor
    func restoreFailureRetriesRestoreInsteadOfStartingLogin() async {
        let service = AuthenticationServiceStub(
            restoreState: .failed(.network)
        )
        let model = AuthenticationViewModel(
            service: service,
            pollInterval: .zero
        )

        model.restoreIfNeeded()
        await model.waitForCurrentTask()
        model.retry()
        await model.waitForCurrentTask()

        #expect(model.state == .failed(.network))
        #expect(model.canCancelFailure == false)
        #expect(await service.observedCalls() == ["restore", "restore"])
    }

    @Test
    @MainActor
    func logoutFailureRetriesLogoutAndCannotBeCancelledAsLogin() async {
        let service = AuthenticationServiceStub(
            restoreState: .signedIn,
            logoutState: .failed(.credentialUnavailable)
        )
        let model = AuthenticationViewModel(
            service: service,
            pollInterval: .zero
        )

        model.restoreIfNeeded()
        await model.waitForCurrentTask()
        model.logout()
        await model.waitForCurrentTask()
        model.retry()
        await model.waitForCurrentTask()

        #expect(model.state == .failed(.credentialUnavailable))
        #expect(model.canCancelFailure == false)
        #expect(model.retryButtonTitle == "重试退出")
        #expect(
            await service.observedCalls() == ["restore", "logout", "logout"]
        )
    }

    @Test
    @MainActor
    func cancelClearsTransientLoginStateThroughService() async {
        let service = AuthenticationServiceStub(
            requestStates: [.expired],
            cancelState: .signedOut
        )
        let model = AuthenticationViewModel(
            service: service,
            pollInterval: .zero
        )

        model.startLogin()
        await model.waitForCurrentTask()
        #expect(model.state == .expired)

        model.cancelLogin()
        await model.waitForCurrentTask()

        #expect(model.state == .signedOut)
        #expect(await service.observedCalls() == ["request", "cancel"])
    }
}

private actor AuthenticationServiceStub: AuthenticationServicing {
    private var requestStates: [AuthenticationState]
    private var pollStates: [AuthenticationState]
    private let restoreState: AuthenticationState
    private let finalizeState: AuthenticationState
    private let cancelState: AuthenticationState
    private let logoutState: AuthenticationState
    private let firstRequestDelay: Duration?
    private var requestCount = 0
    private var calls: [String] = []

    init(
        requestStates: [AuthenticationState] = [],
        pollStates: [AuthenticationState] = [],
        restoreState: AuthenticationState = .signedOut,
        finalizeState: AuthenticationState = .signedOut,
        cancelState: AuthenticationState = .signedOut,
        logoutState: AuthenticationState = .signedOut,
        firstRequestDelay: Duration? = nil
    ) {
        self.requestStates = requestStates
        self.pollStates = pollStates
        self.restoreState = restoreState
        self.finalizeState = finalizeState
        self.cancelState = cancelState
        self.logoutState = logoutState
        self.firstRequestDelay = firstRequestDelay
    }

    func restore() -> AuthenticationState {
        calls.append("restore")
        return restoreState
    }

    func requestQRCode() async -> AuthenticationState {
        requestCount += 1
        let currentRequest = requestCount
        calls.append("request")
        guard !requestStates.isEmpty else { return .failed(.invalidResponse) }
        let result = requestStates.removeFirst()
        if currentRequest == 1, let firstRequestDelay {
            try? await Task.sleep(for: firstRequestDelay)
        }
        return result
    }

    func pollOnce() -> AuthenticationState {
        calls.append("poll")
        guard !pollStates.isEmpty else { return .failed(.invalidResponse) }
        return pollStates.removeFirst()
    }

    func finalizeLogin() -> AuthenticationState {
        calls.append("finalize")
        return finalizeState
    }

    func makeQRCodeImage(scale: Int) -> CGImage? {
        calls.append("image")
        return nil
    }

    func cancelLogin() -> AuthenticationState {
        calls.append("cancel")
        return cancelState
    }

    func logout() -> AuthenticationState {
        calls.append("logout")
        return logoutState
    }

    func observedCalls() -> [String] {
        calls
    }
}
