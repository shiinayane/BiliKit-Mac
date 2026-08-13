import BiliApplication
import CoreGraphics
import Foundation
import Testing

@testable import BiliAuthFeature

@Suite(.timeLimit(.minutes(1)))
struct AuthenticationViewModelTests {
    @Test
    @MainActor
    func drivesQRCodeConfirmationAndFinalizationToSignedIn() async {
        let service = AuthenticationServiceStub(
            requestStates: [.awaitingScan],
            pollStates: [.awaitingConfirmation, .finalizing],
            finalizeState: .signedIn(nil)
        )
        let model = AuthenticationViewModel(
            service: service,
            qrCodeProvider: service,
            pollInterval: .zero
        )

        #expect(model.accountPresentationState == .resolving)
        model.startLogin()
        await model.waitForCurrentTask()

        #expect(model.state == .signedIn(nil))
        #expect(model.sessionState == .signedIn(nil))
        #expect(model.accountPresentationState == .signedIn(nil))
        #expect(model.qrCodeImage == nil)
        #expect(
            await service.observedCalls()
                == ["request", "image", "poll", "image", "poll", "finalize"]
        )
    }

    @Test(arguments: StaleQRCodeCompletion.allCases)
    @MainActor
    func newerLoginIntentPreventsOldQRCodeFromOverwritingState(
        completion: StaleQRCodeCompletion
    ) async throws {
        let service = AuthenticationServiceStub(
            requestStates: [.awaitingScan, .expired],
            suspendedFirstImageCompletion: completion
        )
        let model = AuthenticationViewModel(
            service: service,
            qrCodeProvider: service,
            pollInterval: .zero
        )

        model.startLogin()
        try await service.waitForFirstImageStart()
        let supersededTask = try #require(model.taskSnapshotForTesting())
        model.startLogin()
        await model.waitForCurrentTask()
        await service.releaseFirstImage()
        await supersededTask.value

        #expect(model.state == .expired)
        #expect(model.qrCodeImage == nil)
    }

    @Test
    @MainActor
    func restoreAndLogoutUseApplicationServiceWithoutExposingCredentials() async {
        let service = AuthenticationServiceStub(
            restoreState: .signedIn(nil),
            logoutState: .signedOut
        )
        let model = AuthenticationViewModel(
            service: service,
            qrCodeProvider: service,
            pollInterval: .zero
        )

        model.restoreIfNeeded()
        await model.waitForCurrentTask()
        #expect(model.state == .signedIn(nil))
        #expect(model.sessionState == .signedIn(nil))

        model.logout()
        #expect(model.state == .signingOut)
        #expect(model.sessionState == .signedIn(nil))
        await model.waitForCurrentTask()

        #expect(model.state == .signedOut)
        #expect(model.sessionState == .signedOut)
        #expect(model.accountPresentationState == .signedOut)
        #expect(await service.observedCalls() == ["restore", "logout"])
    }

    @Test
    @MainActor
    func revalidationCannotReplaceInFlightLogoutOwner() async throws {
        let service = AuthenticationServiceStub(
            restoreState: .signedIn(nil),
            logoutState: .signedOut,
            suspendsFirstLogout: true
        )
        let model = AuthenticationViewModel(
            service: service,
            qrCodeProvider: service,
            pollInterval: .zero
        )

        model.restoreIfNeeded()
        await model.waitForCurrentTask()
        model.logout()
        try await service.waitForFirstLogoutStart()
        _ = try #require(model.taskSnapshotForTesting())

        model.revalidate()
        model.logout()

        #expect(model.state == .signingOut)
        #expect(await service.observedCalls() == ["restore", "logout"])

        await service.releaseFirstLogout()
        await model.waitForCurrentTask()

        #expect(model.state == .signedOut)
        #expect(model.sessionState == .signedOut)
        #expect(await service.observedCalls() == ["restore", "logout"])
    }

    @Test
    @MainActor
    func initialRestoreConfirmsSignedOutOnlyOnce() async {
        let service = AuthenticationServiceStub(restoreState: .signedOut)
        let model = AuthenticationViewModel(
            service: service,
            qrCodeProvider: service,
            pollInterval: .zero
        )

        #expect(model.sessionState == .unresolved)
        model.restoreIfNeeded()
        await model.waitForCurrentTask()
        model.restoreIfNeeded()
        await model.waitForCurrentTask()

        #expect(model.state == .signedOut)
        #expect(model.sessionState == .signedOut)
        #expect(await service.observedCalls() == ["restore"])
    }

    @Test
    @MainActor
    func concurrentInitialRestoreCallsReuseTheInFlightIntent() async throws {
        let service = AuthenticationServiceStub(
            restoreState: .signedIn(nil),
            suspendsFirstRestore: true
        )
        let model = AuthenticationViewModel(
            service: service,
            qrCodeProvider: service,
            pollInterval: .zero
        )

        model.restoreIfNeeded()
        try await service.waitForFirstRestoreStart()
        model.restoreIfNeeded()

        #expect(model.state == .restoring)
        #expect(model.sessionState == .unresolved)
        #expect(await service.observedCalls() == ["restore"])

        await service.releaseFirstRestore()
        await model.waitForCurrentTask()

        #expect(model.state == .signedIn(nil))
        #expect(model.sessionState == .signedIn(nil))
        #expect(await service.observedCalls() == ["restore"])
    }

    @Test
    @MainActor
    func dismissingAuthenticationSheetDoesNotCancelWindowRestore() async throws {
        let service = AuthenticationServiceStub(
            restoreState: .signedIn(nil),
            suspendsFirstRestore: true
        )
        let model = AuthenticationViewModel(
            service: service,
            qrCodeProvider: service,
            pollInterval: .zero
        )

        model.restoreIfNeeded()
        try await service.waitForFirstRestoreStart()
        model.cancelPresentedLoginWork()

        #expect(model.state == .restoring)
        #expect(model.sessionState == .unresolved)
        #expect(await service.observedCalls() == ["restore"])

        await service.releaseFirstRestore()
        await model.waitForCurrentTask()

        #expect(model.state == .signedIn(nil))
        #expect(model.sessionState == .signedIn(nil))
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
        #expect(model.sessionState == .unresolved)
        model.retry()
        await model.waitForCurrentTask()

        #expect(model.state == .failed(.network))
        #expect(model.sessionState == .unresolved)
        #expect(model.accountPresentationState == .unavailable)
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
        #expect(model.sessionState == .signedOut)
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
            restoreState: .signedIn(nil),
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
        #expect(model.sessionState == .signedIn(nil))
        await model.waitForCurrentTask()
        #expect(model.sessionState == .signedIn(nil))
        model.retry()
        await model.waitForCurrentTask()

        #expect(model.state == .failed(.credentialUnavailable))
        #expect(model.sessionState == .signedIn(nil))
        #expect(model.accountPresentationState == .signedIn(nil))
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
        #expect(model.sessionState == .unresolved)
        #expect(await service.observedCalls() == ["request", "cancel"])
    }

    @Test
    @MainActor
    func revalidationKeepsConfirmedSessionUntilTerminalResult() async {
        let service = AuthenticationServiceStub(
            restoreState: .signedIn(nil)
        )
        let model = AuthenticationViewModel(
            service: service,
            qrCodeProvider: service,
            pollInterval: .zero
        )

        model.restoreIfNeeded()
        await model.waitForCurrentTask()
        #expect(model.sessionState == .signedIn(nil))

        model.revalidate()
        #expect(model.state == .restoring)
        #expect(model.sessionState == .signedIn(nil))
        await model.waitForCurrentTask()

        #expect(model.sessionState == .signedIn(nil))
        #expect(await service.observedCalls() == ["restore", "restore"])
    }

    @Test
    @MainActor
    func externalSessionChangeUsesItsDedicatedRestoreOperation() async {
        let service = AuthenticationServiceStub(
            restoreState: .signedOut
        )
        let model = AuthenticationViewModel(
            service: service,
            qrCodeProvider: service,
            pollInterval: .zero
        )

        model.revalidateAfterExternalSessionChange()
        await model.waitForCurrentTask()

        #expect(model.sessionState == .signedOut)
        #expect(await service.observedCalls() == ["externalRestore"])
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
    private let suspendedFirstImageCompletion: StaleQRCodeCompletion?
    private let suspendsFirstRestore: Bool
    private let suspendsFirstLogout: Bool
    private var imageCount = 0
    private var restoreCount = 0
    private var calls: [String] = []
    private var firstImageReleased = false
    private var firstRestoreReleased = false
    private let firstImageEvents = TestEventCounter()
    private let firstRestoreEvents = TestEventCounter()
    private let firstLogoutEvents = TestEventCounter()
    private var imageReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var restoreReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var logoutReleased = false
    private var logoutReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        requestStates: [AuthenticationState] = [],
        pollStates: [AuthenticationState] = [],
        restoreState: AuthenticationState = .signedOut,
        finalizeState: AuthenticationState = .signedOut,
        cancelState: AuthenticationState = .signedOut,
        logoutState: AuthenticationState = .signedOut,
        suspendedFirstImageCompletion: StaleQRCodeCompletion? = nil,
        suspendsFirstRestore: Bool = false,
        suspendsFirstLogout: Bool = false
    ) {
        self.requestStates = requestStates
        self.pollStates = pollStates
        self.restoreState = restoreState
        self.finalizeState = finalizeState
        self.cancelState = cancelState
        self.logoutState = logoutState
        self.suspendedFirstImageCompletion = suspendedFirstImageCompletion
        self.suspendsFirstRestore = suspendsFirstRestore
        self.suspendsFirstLogout = suspendsFirstLogout
    }

    func restore() async -> AuthenticationState {
        calls.append("restore")
        restoreCount += 1
        if suspendsFirstRestore, restoreCount == 1 {
            await firstRestoreEvents.signal()
            await withCheckedContinuation { continuation in
                if firstRestoreReleased {
                    continuation.resume()
                } else {
                    restoreReleaseWaiters.append(continuation)
                }
            }
        }
        return restoreState
    }

    func restoreAfterExternalSessionChange() async -> AuthenticationState {
        calls.append("externalRestore")
        return restoreState
    }

    func requestQRCode() async -> AuthenticationState {
        calls.append("request")
        guard !requestStates.isEmpty else { return .failed(.invalidResponse) }
        return requestStates.removeFirst()
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

    func makeQRCodeImage(scale: Int) async throws -> CGImage? {
        imageCount += 1
        calls.append("image")
        guard imageCount == 1, let suspendedFirstImageCompletion else {
            return nil
        }
        await firstImageEvents.signal()
        await withCheckedContinuation { continuation in
            if firstImageReleased {
                continuation.resume()
            } else {
                imageReleaseWaiters.append(continuation)
            }
        }
        switch suspendedFirstImageCompletion {
        case .image:
            return Self.makeFixtureImage()
        case .failure:
            throw QRCodeFixtureError()
        }
    }

    func cancelLogin() -> AuthenticationState {
        calls.append("cancel")
        return cancelState
    }

    func logout() async -> AuthenticationState {
        calls.append("logout")
        if suspendsFirstLogout {
            await firstLogoutEvents.signal()
            await withCheckedContinuation { continuation in
                if logoutReleased {
                    continuation.resume()
                } else {
                    logoutReleaseWaiters.append(continuation)
                }
            }
        }
        return logoutState
    }

    func observedCalls() -> [String] {
        calls
    }

    func waitForFirstImageStart() async throws {
        do {
            try await firstImageEvents.wait(until: 1)
        } catch {
            releaseFirstImage()
            throw error
        }
    }

    func releaseFirstImage() {
        firstImageReleased = true
        resume(&imageReleaseWaiters)
    }

    func waitForFirstRestoreStart() async throws {
        do {
            try await firstRestoreEvents.wait(until: 1)
        } catch {
            releaseFirstRestore()
            throw error
        }
    }

    func releaseFirstRestore() {
        firstRestoreReleased = true
        resume(&restoreReleaseWaiters)
    }

    func waitForFirstLogoutStart() async throws {
        do {
            try await firstLogoutEvents.wait(until: 1)
        } catch {
            releaseFirstLogout()
            throw error
        }
    }

    func releaseFirstLogout() {
        logoutReleased = true
        resume(&logoutReleaseWaiters)
    }

    private static func makeFixtureImage() -> CGImage? {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage()
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

enum StaleQRCodeCompletion: CaseIterable, Sendable {
    case image
    case failure
}

private struct QRCodeFixtureError: Error {}

private actor TestEventCounter {
    private struct Waiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var count = 0
    private var waiters: [UUID: Waiter] = [:]

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
