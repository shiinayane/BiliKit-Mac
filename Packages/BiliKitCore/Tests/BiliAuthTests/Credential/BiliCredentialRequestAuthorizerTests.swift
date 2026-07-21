import BiliNetworking
import Foundation
import Testing
@testable import BiliAuth

struct BiliCredentialRequestAuthorizerTests {
    @Test
    func addsCredentialOnlyToExactAllowedEndpoint() async throws {
        let credential = try makeFixtureCredential()
        let authorizer = BiliCredentialRequestAuthorizer(
            store: MemoryWebCredentialStore(credential: credential)
        )
        let request = HTTPRequest(
            url: try #require(
                URL(string: "https://api.bilibili.com/x/web-interface/nav")
            ),
            headers: ["Accept": "application/json"]
        )

        let authorized = try await authorizer.authorize(request)

        #expect(authorized.headers["Accept"] == "application/json")
        #expect(authorized.headers["Cookie"] == credential.cookieHeader)

        let historyRequest = HTTPRequest(
            url: try #require(
                URL(
                    string: "https://api.bilibili.com/x/web-interface/history/cursor?max=0&view_at=0&business=&ps=20"
                )
            )
        )
        let authorizedHistory = try await authorizer.authorize(historyRequest)
        #expect(authorizedHistory.headers["Cookie"] == credential.cookieHeader)
    }

    @Test
    func rejectsHostsPathsMethodsUserInfoFragmentsAndPlainHTTP() async throws {
        let store = MemoryWebCredentialStore(credential: try makeFixtureCredential())
        let authorizer = BiliCredentialRequestAuthorizer(store: store)
        let cases: [(String, HTTPMethod)] = [
            ("http://api.bilibili.com/x/web-interface/nav", .get),
            ("https://api.bilibili.com.evil.invalid/x/web-interface/nav", .get),
            ("https://i0.hdslb.com/x/web-interface/nav", .get),
            ("http://127.0.0.1:8080/x/web-interface/nav", .get),
            ("https://api.bilibili.com/x/web-interface/popular", .get),
            ("https://api.bilibili.com/x/web-interface/nav?extra=1", .get),
            ("https://api.bilibili.com/x/web-interface/history/cursor?ps=20", .get),
            ("https://api.bilibili.com/x/web-interface/history/cursor?max=0&view_at=0&business=&ps=20&extra=1", .get),
            ("https://api.bilibili.com/x/web-interface/history/cursor?max=-1&view_at=0&business=&ps=20", .get),
            ("https://api.bilibili.com/x/web-interface/nav", .post),
            ("https://user@api.bilibili.com/x/web-interface/nav", .get),
            ("https://api.bilibili.com/x/web-interface/nav#fragment", .get),
        ]

        for (urlString, method) in cases {
            let request = HTTPRequest(
                url: try #require(URL(string: urlString)),
                method: method
            )
            await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
                try await authorizer.authorize(request)
            }
        }
    }

    @Test
    func rejectsPreexistingCredentialHeader() async throws {
        let authorizer = BiliCredentialRequestAuthorizer(
            store: MemoryWebCredentialStore(credential: try makeFixtureCredential())
        )
        let request = HTTPRequest(
            url: try #require(
                URL(string: "https://api.bilibili.com/x/web-interface/nav")
            ),
            headers: ["cookie": "FIXTURE_PREEXISTING_VALUE"]
        )

        await #expect(
            throws: BiliRequestAuthorizationError.credentialHeaderAlreadyPresent
        ) {
            try await authorizer.authorize(request)
        }
    }

    @Test
    func missingCredentialFailsWithoutChangingRequest() async throws {
        let authorizer = BiliCredentialRequestAuthorizer(
            store: MemoryWebCredentialStore()
        )
        let request = HTTPRequest(
            url: try #require(
                URL(string: "https://api.bilibili.com/x/web-interface/nav")
            )
        )

        await #expect(throws: BiliRequestAuthorizationError.missingCredential) {
            try await authorizer.authorize(request)
        }
    }

    @Test
    func expiredOrCorruptCredentialIsPurged() async throws {
        let endpoint = try #require(
            URL(string: "https://api.bilibili.com/x/web-interface/nav")
        )
        let expiredStore = MemoryWebCredentialStore(
            credential: try makeFixtureCredential(expiresAt: .distantPast)
        )
        let expiredAuthorizer = BiliCredentialRequestAuthorizer(store: expiredStore)

        await #expect(throws: BiliRequestAuthorizationError.expiredCredential) {
            try await expiredAuthorizer.authorize(HTTPRequest(url: endpoint))
        }
        #expect(expiredStore.deleteCount == 1)

        let corruptStore = MemoryWebCredentialStore(
            loadError: WebCredentialStoreError.corruptCredential
        )
        let corruptAuthorizer = BiliCredentialRequestAuthorizer(store: corruptStore)
        await #expect(throws: BiliRequestAuthorizationError.invalidCredential) {
            try await corruptAuthorizer.authorize(HTTPRequest(url: endpoint))
        }
        #expect(corruptStore.deleteCount == 1)

        let deletionFailure = MemoryWebCredentialStore(
            credential: try makeFixtureCredential(expiresAt: .distantPast),
            deleteError: FixtureValidationError.offline
        )
        let deletionFailureAuthorizer = BiliCredentialRequestAuthorizer(
            store: deletionFailure
        )
        await #expect(
            throws: BiliRequestAuthorizationError.credentialStoreUnavailable
        ) {
            try await deletionFailureAuthorizer.authorize(
                HTTPRequest(url: endpoint)
            )
        }
    }

    @Test
    func restoreValidCredentialUsesAuthorizedNavigationRequest() async throws {
        let transport = CredentialValidationTransport(
            response: navigationResponse(isLogin: true)
        )
        let authorizer = BiliCredentialRequestAuthorizer(
            store: MemoryWebCredentialStore(credential: try makeFixtureCredential()),
            transport: transport
        )

        let isLoggedIn = try await authorizer.restoreLoginState()

        #expect(isLoggedIn)
        let request = try #require(await transport.capturedRequest)
        #expect(request.url.absoluteString == "https://api.bilibili.com/x/web-interface/nav")
        #expect(request.headers["Cookie"]?.contains("SESSDATA=FIXTURE_") == true)
    }

    @Test
    func restoreMissingOrRemotelyInvalidCredentialFallsBackAndPurges() async throws {
        let missingTransport = CredentialValidationTransport(
            response: navigationResponse(isLogin: true)
        )
        let missing = BiliCredentialRequestAuthorizer(
            store: MemoryWebCredentialStore(),
            transport: missingTransport
        )
        #expect(try await missing.restoreLoginState() == false)
        #expect(await missingTransport.capturedRequest == nil)

        let invalidStore = MemoryWebCredentialStore(
            credential: try makeFixtureCredential()
        )
        let invalid = BiliCredentialRequestAuthorizer(
            store: invalidStore,
            transport: CredentialValidationTransport(
                response: navigationResponse(isLogin: false)
            )
        )
        #expect(try await invalid.restoreLoginState() == false)
        #expect(invalidStore.deleteCount == 1)

        let failedPurge = BiliCredentialRequestAuthorizer(
            store: MemoryWebCredentialStore(
                credential: try makeFixtureCredential(),
                deleteError: FixtureValidationError.offline
            ),
            transport: CredentialValidationTransport(
                response: navigationResponse(isLogin: false)
            )
        )
        await #expect(
            throws: BiliRequestAuthorizationError.credentialStoreUnavailable
        ) {
            try await failedPurge.restoreLoginState()
        }
    }

    @Test
    func temporaryValidationFailureKeepsStoredCredential() async throws {
        let store = MemoryWebCredentialStore(credential: try makeFixtureCredential())
        let authorizer = BiliCredentialRequestAuthorizer(
            store: store,
            transport: CredentialValidationTransport(error: FixtureValidationError.offline)
        )

        await #expect(throws: BiliRequestAuthorizationError.validationUnavailable) {
            try await authorizer.restoreLoginState()
        }
        #expect(store.deleteCount == 0)
        #expect(try store.load() != nil)
    }

    private func navigationResponse(isLogin: Bool) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(
                "{\"code\":0,\"data\":{\"isLogin\":\(isLogin)}}".utf8
            )
        )
    }
}

private actor CredentialValidationTransport: HTTPTransport {
    private let response: HTTPResponse?
    private let error: (any Error)?
    private(set) var capturedRequest: HTTPRequest?

    init(response: HTTPResponse) {
        self.response = response
        error = nil
    }

    init(error: any Error) {
        response = nil
        self.error = error
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        capturedRequest = request
        if let error { throw error }
        return try #require(response)
    }
}

private enum FixtureValidationError: Error {
    case offline
}
