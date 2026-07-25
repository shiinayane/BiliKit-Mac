import BiliApplication
import CoreGraphics
import Foundation
import Testing

@testable import BiliAuthFeature

@Suite(.timeLimit(.minutes(1)))
struct AuthenticationViewModelTests {
    @Test
    func eventCounterCancellationCannotLeaveOrResumeAStaleWaiter() async throws {
        let counter = TestEventCounter()

        let cancelledBeforeRegistration = Task {
            try await counter.wait(until: 1)
        }
        cancelledBeforeRegistration.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledBeforeRegistration.value
        }

        let cancelledAfterRegistration = Task {
            try await counter.wait(until: 2)
        }
        while await counter.pendingWaiterCount == 0 {
            try Task.checkCancellation()
            await Task.yield()
        }
        cancelledAfterRegistration.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledAfterRegistration.value
        }

        #expect(await counter.pendingWaiterCount == 0)
        await counter.signal()
        await counter.signal()
    }

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
            qrCodeProvider: service,
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
            suspendsFirstRequest: true
        )
        let model = AuthenticationViewModel(
            service: service,
            qrCodeProvider: service,
            pollInterval: .zero
        )

        model.startLogin()
        try await service.waitForFirstRequestStart()
        let supersededTask = try #require(model.taskSnapshotForTesting())
        model.startLogin()
        await model.waitForCurrentTask()
        await service.releaseFirstRequest()
        await supersededTask.value

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
            qrCodeProvider: service,
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
            qrCodeProvider: service,
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
    func restoreFailureCanExplicitlyClearLocalCredentials() async {
        let service = AuthenticationServiceStub(
            restoreState: .failed(.network),
            logoutState: .signedOut
        )
        let model = AuthenticationViewModel(
            service: service,
            qrCodeProvider: service,
            pollInterval: .zero
        )

        model.restoreIfNeeded()
        await model.waitForCurrentTask()
        #expect(model.canClearLocalCredentials)

        model.clearLocalCredentials()
        await model.waitForCurrentTask()

        #expect(model.state == .signedOut)
        #expect(!model.canClearLocalCredentials)
        #expect(await service.observedCalls() == ["restore", "logout"])
    }

    @Test
    @MainActor
    func localPollingLimitCancelsChallengeAndExpires() async {
        let service = AuthenticationServiceStub(
            requestStates: [.awaitingScan],
            pollStates: [.awaitingScan, .awaitingScan],
            cancelState: .signedOut
        )
        let model = AuthenticationViewModel(
            service: service,
            qrCodeProvider: service,
            pollInterval: .zero,
            maximumPollAttempts: 2
        )

        model.startLogin()
        await model.waitForCurrentTask()

        #expect(model.state == .expired)
        #expect(model.qrCodeImage == nil)
        #expect(
            await service.observedCalls()
                == ["request", "image", "poll", "image", "poll", "image", "cancel"]
        )
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
            qrCodeProvider: service,
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
            qrCodeProvider: service,
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

private actor AuthenticationServiceStub: AuthenticationServicing,
    AuthenticationQRCodeProviding
{
    private var requestStates: [AuthenticationState]
    private var pollStates: [AuthenticationState]
    private let restoreState: AuthenticationState
    private let finalizeState: AuthenticationState
    private let cancelState: AuthenticationState
    private let logoutState: AuthenticationState
    private let suspendsFirstRequest: Bool
    private var requestCount = 0
    private var calls: [String] = []
    private var firstRequestReleased = false
    private let firstRequestEvents = TestEventCounter()
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        requestStates: [AuthenticationState] = [],
        pollStates: [AuthenticationState] = [],
        restoreState: AuthenticationState = .signedOut,
        finalizeState: AuthenticationState = .signedOut,
        cancelState: AuthenticationState = .signedOut,
        logoutState: AuthenticationState = .signedOut,
        suspendsFirstRequest: Bool = false
    ) {
        self.requestStates = requestStates
        self.pollStates = pollStates
        self.restoreState = restoreState
        self.finalizeState = finalizeState
        self.cancelState = cancelState
        self.logoutState = logoutState
        self.suspendsFirstRequest = suspendsFirstRequest
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
        if currentRequest == 1, suspendsFirstRequest {
            await firstRequestEvents.signal()
            await withCheckedContinuation { continuation in
                if firstRequestReleased {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
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

    func waitForFirstRequestStart() async throws {
        do {
            try await firstRequestEvents.wait(until: 1)
        } catch {
            releaseFirstRequest()
            throw error
        }
    }

    func releaseFirstRequest() {
        firstRequestReleased = true
        resume(&releaseWaiters)
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor TestEventCounter {
    private struct Waiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var count = 0
    private var waiters: [UUID: Waiter] = [:]

    var pendingWaiterCount: Int {
        waiters.count
    }

    func signal() {
        count += 1
        let ready = waiters.filter { count >= $0.value.expectedCount }
        for (id, waiter) in ready where waiters.removeValue(forKey: id) != nil {
            waiter.continuation.resume()
        }
    }

    func wait(until expectedCount: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if count >= expectedCount {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = Waiter(
                        expectedCount: expectedCount,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}
