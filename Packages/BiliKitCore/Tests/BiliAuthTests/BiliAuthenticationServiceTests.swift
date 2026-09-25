import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth

private let accountSessionValidationAllowedPaths: Set<String> = [
    "/x/web-interface/nav"
]

struct BiliAuthenticationServiceTests {
    @Test
    func mapsQRCodeFlowAndCommitsOnlyAfterFinalValidation() async throws {
        let store = MemoryWebCredentialStore()
        let service = makeService(
            store: store,
            qrTransport: RecordingAuthTransport(
                responses: [
                    try fixtureResponse("qr-generate"),
                    try successfulPollResponse(),
                    navigationResponse(isLogin: true, includesIdentity: true)
                ]
            )
        )

        #expect(await service.requestQRCode() == .awaitingScan)
        #expect(try await service.makeQRCodeImage(scale: 2) != nil)
        #expect(await service.pollOnce() == .finalizing)
        #expect(store.saveCount == 0)

        #expect(
            await service.finalizeLogin() == .signedIn(fixtureAccountIdentity)
        )
        #expect(store.saveCount == 1)
        #expect(try store.load() != nil)
    }

    @Test
    func unknownPollStatusMapsToInvalidResponse() async throws {
        let service = makeService(
            store: MemoryWebCredentialStore(),
            qrTransport: RecordingAuthTransport(
                responses: [
                    try fixtureResponse("qr-generate"),
                    HTTPResponse(
                        statusCode: 200,
                        headers: ["Content-Type": "application/json"],
                        body: Data(#"{"code":0,"data":{"code":12345}}"#.utf8)
                    )
                ]
            )
        )

        #expect(await service.requestQRCode() == .awaitingScan)
        #expect(await service.pollOnce() == .failed(.invalidResponse))
        #expect(try await service.makeQRCodeImage(scale: 2) == nil)
    }

    @Test
    func cancelledRestoreNeverPublishesSignedOutWhileCredentialRemains() async throws {
        let store = MemoryWebCredentialStore(
            credential: try makeFixtureCredential()
        )
        let service = makeService(
            store: store,
            validationTransport: RecordingAuthTransport(errors: [CancellationError()])
        )

        #expect(await service.restore() == .failed(.network))
        #expect(try store.load() != nil)
        // 凭据仍在时不能直接开始新的扫码登录。
        #expect(await service.requestQRCode() == .failed(.network))
    }

    @Test(arguments: RestoreCase.allCases)
    func restoreInvalidatesAuthenticatedAPIsOnlyForLocallyObservedSessionLoss(
        _ restoreCase: RestoreCase
    ) async throws {
        let events = AuthEventRecorder()
        let store = MemoryWebCredentialStore(
            credential: restoreCase.hasStoredCredential
                ? try makeFixtureCredential() : nil
        )
        let service = makeService(
            store: store,
            validationTransport: RecordingAuthTransport(
                responses: restoreCase.navigationLoginStates.map {
                    navigationResponse(isLogin: $0)
                }
            ),
            invalidators: [RecordingAuthenticatedSessionInvalidator(events: events)]
        )

        var states: [AuthenticationState] = []
        for _ in restoreCase.expectedStates {
            states.append(
                restoreCase.isExternalChange
                    ? await service.restoreAfterExternalSessionChange()
                    : await service.restore()
            )
        }

        #expect(states == restoreCase.expectedStates)
        #expect(events.values() == restoreCase.expectedEvents)
        #expect(try store.load() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func logoutCancelsLateCredentialFinalizationBeforeDeletingStore() async throws {
        let store = MemoryWebCredentialStore()
        let qrTransport = RecordingAuthTransport(
            responses: [
                try fixtureResponse("qr-generate"),
                try successfulPollResponse(),
                navigationResponse(isLogin: true)
            ],
            suspendingRequest: 3
        )
        let service = makeService(store: store, qrTransport: qrTransport)

        #expect(await service.requestQRCode() == .awaitingScan)
        #expect(await service.pollOnce() == .finalizing)
        let finalizeTask = Task { await service.finalizeLogin() }
        await qrTransport.waitForSuspendedRequest()

        #expect(await service.logout() == .signedOut)
        await qrTransport.resumeSuspendedRequest()
        _ = await finalizeTask.value

        #expect(try store.load() == nil)
        #expect(store.saveCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func restoreCannotEnterWhileLogoutCleanupIsSuspended() async throws {
        let store = MemoryWebCredentialStore(
            credential: try makeFixtureCredential()
        )
        let invalidator = SuspendingAuthenticatedSessionInvalidator()
        let service = makeService(
            store: store,
            validationTransport: RecordingAuthTransport(
                responses: [navigationResponse(isLogin: true)]
            ),
            invalidators: [invalidator]
        )

        #expect(await service.restore() == .signedIn(nil))
        let logoutTask = Task { await service.logout() }
        await invalidator.waitUntilInvalidationStarts()

        #expect(await service.restore() == .signingOut)
        await invalidator.resumeInvalidation()
        #expect(await logoutTask.value == .signedOut)
        #expect(try store.load() == nil)
    }

    @Test(arguments: [false, true])
    func logoutDeletesCredentialBeforeInvalidatingSessionsAndReportsDeleteFailure(
        deleteFails: Bool
    ) async throws {
        let events = AuthEventRecorder()
        let store = MemoryWebCredentialStore(
            credential: try makeFixtureCredential(),
            deleteError: deleteFails ? StubAuthError.storeUnavailable : nil,
            events: events
        )
        let service = makeService(
            store: store,
            qrTransport: RecordingAuthTransport(
                invalidationEvent: (events, "qr-invalidated")
            ),
            validationTransport: RecordingAuthTransport(
                responses: [navigationResponse(isLogin: true)],
                invalidationEvent: (events, "validation-invalidated")
            ),
            invalidators: [RecordingAuthenticatedSessionInvalidator(events: events)]
        )
        let expectedState: AuthenticationState =
            deleteFails ? .failed(.credentialUnavailable) : .signedOut

        #expect(await service.restore() == .signedIn(nil))
        #expect(await service.logout() == expectedState)
        // 删除失败后仍须先登出，取消登录不能把状态改成未登录。
        #expect(await service.cancelLogin() == expectedState)

        #expect((try store.load() == nil) == !deleteFails)
        #expect(
            events.values() == [
                deleteFails ? "credential-delete-failed" : "credential-deleted",
                "api-invalidated",
                "qr-invalidated",
                "validation-invalidated"
            ]
        )
    }

    private func makeService(
        store: MemoryWebCredentialStore,
        qrTransport: RecordingAuthTransport = RecordingAuthTransport(),
        validationTransport: RecordingAuthTransport = RecordingAuthTransport(),
        invalidators: [any AuthenticatedSessionInvalidating] = []
    ) -> BiliAuthenticationService {
        BiliAuthenticationService(
            loginSession: WebQRLoginSession(
                transport: qrTransport,
                credentialStore: store
            ),
            authorizer: BiliCredentialRequestAuthorizer(
                store: store,
                allowedPaths: accountSessionValidationAllowedPaths,
                transport: validationTransport
            ),
            loginSessionFactory: {
                WebQRLoginSession(
                    transport: RecordingAuthTransport(),
                    credentialStore: store
                )
            },
            authorizerFactory: {
                BiliCredentialRequestAuthorizer(
                    store: store,
                    allowedPaths: accountSessionValidationAllowedPaths,
                    transport: RecordingAuthTransport()
                )
            },
            additionalSessionInvalidators: invalidators
        )
    }

    enum RestoreCase: CaseIterable, Sendable {
        case confirmedSessionBecomesSignedOut
        case initialSignedOutWithoutCredential
        case initialInvalidStoredCredential
        case externalSessionChange

        var hasStoredCredential: Bool {
            self != .initialSignedOutWithoutCredential
        }

        var isExternalChange: Bool { self == .externalSessionChange }

        var navigationLoginStates: [Bool] {
            switch self {
            case .confirmedSessionBecomesSignedOut: [true, false]
            case .initialSignedOutWithoutCredential: []
            case .initialInvalidStoredCredential, .externalSessionChange: [false]
            }
        }

        var expectedStates: [AuthenticationState] {
            switch self {
            case .confirmedSessionBecomesSignedOut: [.signedIn(nil), .signedOut]
            default: [.signedOut]
            }
        }

        /// 只有本窗口发现的会话丢失才全局失效认证 API；外部变化已由来源窗口传播。
        var expectedEvents: [String] {
            switch self {
            case .confirmedSessionBecomesSignedOut, .initialInvalidStoredCredential:
                ["api-invalidated"]
            case .initialSignedOutWithoutCredential, .externalSessionChange:
                []
            }
        }
    }
}

private let fixtureAccountIdentity = AccountIdentity(
    id: 42,
    displayName: "Fixture Account",
    avatarURL: URL(string: "https://i0.hdslb.com/fixture/avatar.png")
)

private actor RecordingAuthenticatedSessionInvalidator:
    AuthenticatedSessionInvalidating
{
    private let events: AuthEventRecorder

    init(events: AuthEventRecorder) {
        self.events = events
    }

    func invalidateAuthenticatedSession() {
        events.append("api-invalidated")
    }
}

private actor SuspendingAuthenticatedSessionInvalidator:
    AuthenticatedSessionInvalidating
{
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var invalidationContinuation: CheckedContinuation<Void, Never>?

    func invalidateAuthenticatedSession() async {
        started = true
        startWaiters.resumeAll()
        await withCheckedContinuation { continuation in
            invalidationContinuation = continuation
        }
    }

    func waitUntilInvalidationStarts() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeInvalidation() {
        invalidationContinuation?.resume()
        invalidationContinuation = nil
    }
}
