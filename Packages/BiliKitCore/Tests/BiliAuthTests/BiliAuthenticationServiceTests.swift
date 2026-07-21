import BiliApplication
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
        let navigation = navigationResponse(isLogin: true)
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

        #expect(await service.finalizeLogin() == .signedIn)
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
                    responses: [navigationResponse(isLogin: true)]
                )
            ),
            store: store
        )

        #expect(await service.restore() == .signedIn)
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
            }
        )

        #expect(await service.restore() == .signedIn)
        #expect(await service.logout() == .signedOut)

        #expect(try store.load() == nil)
        #expect(events.values() == [
            "credential-deleted",
            "qr-invalidated",
            "validation-invalidated",
        ])
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
            }
        )

        #expect(await service.restore() == .signedIn)
        #expect(await service.logout() == .failed(.credentialUnavailable))
        #expect(await service.cancelLogin() == .failed(.credentialUnavailable))

        #expect(try store.load() != nil)
        #expect(events.values() == [
            "credential-delete-failed",
            "qr-invalidated",
            "validation-invalidated",
        ])
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

private func navigationResponse(isLogin: Bool) -> HTTPResponse {
    HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(
            #"{"code":0,"data":{"isLogin":\#(isLogin)}}"#.utf8
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
