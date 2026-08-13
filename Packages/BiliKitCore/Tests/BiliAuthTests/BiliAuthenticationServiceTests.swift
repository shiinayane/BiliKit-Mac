import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth

struct BiliAuthenticationServiceTests {
    @Test
    func mapsQRCodeFlowAndCommitsOnlyAfterFinalValidation() async throws {
        let success = try fixtureResponse(
            "qr-poll-success",
            headers: [
                "Content-Type": "application/json",
                "Set-Cookie": fixtureSetCookieHeader,
            ]
        )
        let navigation = navigationResponse(
            isLogin: true,
            includesIdentity: true
        )
        let store = MemoryWebCredentialStore()
        let session = WebQRLoginSession(
            transport: RecordingAuthTransport(
                responses: [
                    try fixtureResponse("qr-generate"),
                    success,
                    navigation,
                ]
            ),
            credentialStore: store
        )
        let service = makeService(
            session: session,
            authorizer: BiliCredentialRequestAuthorizer(
                store: store,
                transport: RecordingAuthTransport()
            ),
            store: store
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
    func restoresStoredCredentialAsNonSecretSignedInState() async throws {
        let store = MemoryWebCredentialStore(
            credential: try makeFixtureCredential()
        )
        let service = makeService(
            session: WebQRLoginSession(
                transport: RecordingAuthTransport(),
                credentialStore: store
            ),
            authorizer: BiliCredentialRequestAuthorizer(
                store: store,
                transport: RecordingAuthTransport(
                    responses: [
                        navigationResponse(
                            isLogin: true,
                            includesIdentity: true
                        )
                    ]
                )
            ),
            store: store
        )

        #expect(await service.restore() == .signedIn(fixtureAccountIdentity))
    }

    @Test
    func confirmedSessionBecomingSignedOutInvalidatesAuthenticatedAPIs() async throws {
        let events = LogoutEventRecorder()
        let store = MemoryWebCredentialStore(
            credential: try makeFixtureCredential()
        )
        let service = BiliAuthenticationService(
            loginSession: WebQRLoginSession(
                transport: RecordingAuthTransport(),
                credentialStore: store
            ),
            authorizer: BiliCredentialRequestAuthorizer(
                store: store,
                transport: RecordingAuthTransport(
                    responses: [
                        navigationResponse(isLogin: true),
                        navigationResponse(isLogin: false),
                    ]
                )
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
                    transport: RecordingAuthTransport()
                )
            },
            additionalSessionInvalidators: [
                RecordingAuthenticatedSessionInvalidator(events: events)
            ]
        )

        #expect(await service.restore() == .signedIn(nil))
        #expect(events.values().isEmpty)

        #expect(await service.restore() == .signedOut)
        #expect(events.values() == ["api-invalidated"])
        #expect(try store.load() == nil)
    }

    @Test
    func initialSignedOutRestoreDoesNotInvalidateAnonymousAPIs() async {
        let events = LogoutEventRecorder()
        let store = MemoryWebCredentialStore()
        let service = BiliAuthenticationService(
            loginSession: WebQRLoginSession(
                transport: RecordingAuthTransport(),
                credentialStore: store
            ),
            authorizer: BiliCredentialRequestAuthorizer(
                store: store,
                transport: RecordingAuthTransport()
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
                    transport: RecordingAuthTransport()
                )
            },
            additionalSessionInvalidators: [
                RecordingAuthenticatedSessionInvalidator(events: events)
            ]
        )

        #expect(await service.restore() == .signedOut)
        #expect(events.values().isEmpty)
    }

    @Test
    func initialInvalidStoredSessionInvalidatesAuthenticatedAPIs() async throws {
        let events = LogoutEventRecorder()
        let store = MemoryWebCredentialStore(
            credential: try makeFixtureCredential()
        )
        let service = BiliAuthenticationService(
            loginSession: WebQRLoginSession(
                transport: RecordingAuthTransport(),
                credentialStore: store
            ),
            authorizer: BiliCredentialRequestAuthorizer(
                store: store,
                transport: RecordingAuthTransport(
                    responses: [navigationResponse(isLogin: false)]
                )
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
                    transport: RecordingAuthTransport()
                )
            },
            additionalSessionInvalidators: [
                RecordingAuthenticatedSessionInvalidator(events: events)
            ]
        )

        #expect(await service.restore() == .signedOut)
        #expect(events.values() == ["api-invalidated"])
        #expect(try store.load() == nil)
    }

    @Test
    func externalSessionChangeRestoreDoesNotRepeatGlobalInvalidation() async throws {
        let events = LogoutEventRecorder()
        let store = MemoryWebCredentialStore(
            credential: try makeFixtureCredential()
        )
        let service = BiliAuthenticationService(
            loginSession: WebQRLoginSession(
                transport: RecordingAuthTransport(),
                credentialStore: store
            ),
            authorizer: BiliCredentialRequestAuthorizer(
                store: store,
                transport: RecordingAuthTransport(
                    responses: [navigationResponse(isLogin: false)]
                )
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
                    transport: RecordingAuthTransport()
                )
            },
            additionalSessionInvalidators: [
                RecordingAuthenticatedSessionInvalidator(events: events)
            ]
        )

        #expect(await service.restoreAfterExternalSessionChange() == .signedOut)
        #expect(events.values().isEmpty)
        #expect(try store.load() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func logoutCancelsLateCredentialFinalizationBeforeDeletingStore() async throws {
        let store = MemoryWebCredentialStore()
        let transport = SuspendingFinalizationTransport(
            generateResponse: try fixtureResponse("qr-generate"),
            pollResponse: try fixtureResponse(
                "qr-poll-success",
                headers: [
                    "Content-Type": "application/json",
                    "Set-Cookie": fixtureSetCookieHeader,
                ]
            ),
            validationResponse: navigationResponse(isLogin: true)
        )
        let service = makeService(
            session: WebQRLoginSession(
                transport: transport,
                credentialStore: store
            ),
            authorizer: BiliCredentialRequestAuthorizer(
                store: store,
                transport: RecordingAuthTransport()
            ),
            store: store
        )

        #expect(await service.requestQRCode() == .awaitingScan)
        #expect(await service.pollOnce() == .finalizing)
        let finalizeTask = Task { await service.finalizeLogin() }
        await transport.waitUntilValidationStarts()

        #expect(await service.logout() == .signedOut)
        await transport.resumeValidation()
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
        let service = BiliAuthenticationService(
            loginSession: WebQRLoginSession(
                transport: RecordingAuthTransport(),
                credentialStore: store
            ),
            authorizer: BiliCredentialRequestAuthorizer(
                store: store,
                transport: RecordingAuthTransport(
                    responses: [navigationResponse(isLogin: true)]
                )
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
                    transport: RecordingAuthTransport()
                )
            },
            additionalSessionInvalidators: [invalidator]
        )

        #expect(await service.restore() == .signedIn(nil))
        let logoutTask = Task { await service.logout() }
        await invalidator.waitUntilInvalidationStarts()

        #expect(await service.restore() == .signingOut)
        await invalidator.resumeInvalidation()
        #expect(await logoutTask.value == .signedOut)
        #expect(try store.load() == nil)
    }

    @Test
    func logoutDeletesCredentialBeforeInvalidatingBothSessions() async throws {
        let events = LogoutEventRecorder()
        let store = EventCredentialStore(
            credential: try makeFixtureCredential(),
            events: events
        )
        let qrTransport = RecordingInvalidatingTransport(
            name: "qr-invalidated",
            events: events
        )
        let validationTransport = RecordingInvalidatingTransport(
            name: "validation-invalidated",
            responses: [navigationResponse(isLogin: true)],
            events: events
        )
        let service = BiliAuthenticationService(
            loginSession: WebQRLoginSession(
                transport: qrTransport,
                credentialStore: store
            ),
            authorizer: BiliCredentialRequestAuthorizer(
                store: store,
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
                    transport: RecordingAuthTransport()
                )
            },
            additionalSessionInvalidators: [
                RecordingAuthenticatedSessionInvalidator(events: events)
            ]
        )

        #expect(await service.restore() == .signedIn(nil))
        #expect(await service.logout() == .signedOut)

        #expect(try store.load() == nil)
        #expect(
            events.values() == [
                "credential-deleted",
                "api-invalidated",
                "qr-invalidated",
                "validation-invalidated",
            ]
        )
    }

    @Test
    func logoutFailureNeverPublishesSignedOutAndStillInvalidatesSessions() async throws {
        let events = LogoutEventRecorder()
        let store = EventCredentialStore(
            credential: try makeFixtureCredential(),
            deleteFails: true,
            events: events
        )
        let qrTransport = RecordingInvalidatingTransport(
            name: "qr-invalidated",
            events: events
        )
        let validationTransport = RecordingInvalidatingTransport(
            name: "validation-invalidated",
            responses: [navigationResponse(isLogin: true)],
            events: events
        )
        let service = BiliAuthenticationService(
            loginSession: WebQRLoginSession(
                transport: qrTransport,
                credentialStore: store
            ),
            authorizer: BiliCredentialRequestAuthorizer(
                store: store,
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
                    transport: RecordingAuthTransport()
                )
            },
            additionalSessionInvalidators: [
                RecordingAuthenticatedSessionInvalidator(events: events)
            ]
        )

        #expect(await service.restore() == .signedIn(nil))
        #expect(await service.logout() == .failed(.credentialUnavailable))
        #expect(await service.cancelLogin() == .failed(.credentialUnavailable))

        #expect(try store.load() != nil)
        #expect(
            events.values() == [
                "credential-delete-failed",
                "api-invalidated",
                "qr-invalidated",
                "validation-invalidated",
            ]
        )
    }

    private func makeService(
        session: WebQRLoginSession,
        authorizer: BiliCredentialRequestAuthorizer,
        store: MemoryWebCredentialStore
    ) -> BiliAuthenticationService {
        BiliAuthenticationService(
            loginSession: session,
            authorizer: authorizer,
            loginSessionFactory: {
                WebQRLoginSession(
                    transport: RecordingAuthTransport(),
                    credentialStore: store
                )
            },
            authorizerFactory: {
                BiliCredentialRequestAuthorizer(
                    store: store,
                    transport: RecordingAuthTransport()
                )
            }
        )
    }
}

private let fixtureAccountIdentity = AccountIdentity(
    id: 42,
    displayName: "Fixture Account",
    avatarURL: URL(string: "https://i0.hdslb.com/fixture/avatar.png")
)

private func navigationResponse(
    isLogin: Bool,
    includesIdentity: Bool = false
) -> HTTPResponse {
    let identityFields: String
    if includesIdentity {
        identityFields =
            ",\"mid\":42,\"uname\":\"  Fixture Account  \""
            + ",\"face\":\"//i0.hdslb.com/fixture/avatar.png\""
    } else {
        identityFields = ""
    }
    return HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(
            "{\"code\":0,\"data\":{\"isLogin\":\(isLogin)\(identityFields)}}".utf8
        )
    )
}

private final class LogoutEventRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BiliAuthenticationServiceTests.events")
    private var storage: [String] = []

    func append(_ event: String) {
        queue.sync { storage.append(event) }
    }

    func values() -> [String] {
        queue.sync { storage }
    }
}

private final class EventCredentialStore: WebCredentialStoring,
    @unchecked Sendable
{
    private let queue = DispatchQueue(label: "BiliAuthenticationServiceTests.store")
    private var credential: WebCredential?
    private let deleteFails: Bool
    private let events: LogoutEventRecorder

    init(
        credential: WebCredential?,
        deleteFails: Bool = false,
        events: LogoutEventRecorder
    ) {
        self.credential = credential
        self.deleteFails = deleteFails
        self.events = events
    }

    func load() throws -> WebCredential? {
        queue.sync { credential }
    }

    func save(_ credential: WebCredential) throws {
        queue.sync { self.credential = credential }
    }

    func delete() throws {
        try queue.sync {
            if deleteFails {
                events.append("credential-delete-failed")
                throw EventStoreError.unavailable
            }
            credential = nil
            events.append("credential-deleted")
        }
    }
}

private final class RecordingInvalidatingTransport: HTTPTransport,
    HTTPTransportInvalidating, @unchecked Sendable
{
    private let queue = DispatchQueue(label: "BiliAuthenticationServiceTests.transport")
    private let name: String
    private var responses: [HTTPResponse]
    private let events: LogoutEventRecorder

    init(
        name: String,
        responses: [HTTPResponse] = [],
        events: LogoutEventRecorder
    ) {
        self.name = name
        self.responses = responses
        self.events = events
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try queue.sync {
            guard !responses.isEmpty else { throw EventStoreError.missingResponse }
            return responses.removeFirst()
        }
    }

    func invalidateAndCancel() {
        events.append(name)
    }
}

private enum EventStoreError: Error {
    case unavailable
    case missingResponse
}

private actor RecordingAuthenticatedSessionInvalidator:
    AuthenticatedSessionInvalidating
{
    private let events: LogoutEventRecorder

    init(events: LogoutEventRecorder) {
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
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
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

private actor SuspendingFinalizationTransport: HTTPTransport {
    private let generateResponse: HTTPResponse
    private let pollResponse: HTTPResponse
    private let validationResponse: HTTPResponse
    private var requestCount = 0
    private var validationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var validationContinuation: CheckedContinuation<Void, Never>?

    init(
        generateResponse: HTTPResponse,
        pollResponse: HTTPResponse,
        validationResponse: HTTPResponse
    ) {
        self.generateResponse = generateResponse
        self.pollResponse = pollResponse
        self.validationResponse = validationResponse
    }

    func send(_ request: HTTPRequest) async -> HTTPResponse {
        requestCount += 1
        switch requestCount {
        case 1:
            return generateResponse
        case 2:
            return pollResponse
        default:
            validationStarted = true
            for waiter in startWaiters {
                waiter.resume()
            }
            startWaiters.removeAll()
            await withCheckedContinuation { continuation in
                validationContinuation = continuation
            }
            return validationResponse
        }
    }

    func waitUntilValidationStarts() async {
        guard !validationStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeValidation() {
        validationContinuation?.resume()
        validationContinuation = nil
    }
}
