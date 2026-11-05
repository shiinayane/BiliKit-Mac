import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth

private let fixturePlaybackAllowedPaths: Set<String> = [
    "/x/player/playurl"
]

/// 读授权器只为配置的精确 path 注入存储的 Cookie，不同授权器放行的能力互不相交。
///
/// 调用方自带凭据头，或 scheme、host、端口、方法、path 有任何变形都拒绝；过期或损坏的凭据被清除；
/// Keychain 不可用时只有已确认未登录才按无凭据处理；nav 恢复只在明确未登录时清除凭据，其余失败保留凭据。
@Suite(.timeLimit(.minutes(1)))
struct BiliCredentialRequestAuthorizerTests {
    @Test(arguments: [navigationAllowedPaths, fixturePlaybackAllowedPaths])
    func authorizesConfiguredPathsAndInjectsOnlyStoredCredential(
        allowedPaths: Set<String>
    ) async throws {
        let credential = try makeFixtureCredential()
        let authorizer = makeCredentialAuthorizer(
            store: MemoryAccountCredentialStore(credential: credential),
            allowedPaths: allowedPaths
        )
        for path in allowedPaths {
            let request = HTTPRequest(
                url: try #require(
                    URL(
                        string: "https://api.bilibili.com:443\(path)?fixture=1"
                    )
                ),
                headers: ["Accept": "application/json"]
            )

            let authorized = try await authorizer.authorize(request)

            #expect(authorized.headers["Accept"] == "application/json")
            #expect(authorized.headers["Cookie"] == credential.cookieHeader)
            #expect(authorized.headers["Authorization"] == nil)
            #expect(authorized.headers["X-CSRF-Token"] == nil)
            #expect(authorized.headers.count == 2)
        }
    }

    @Test
    func keepsConfiguredReadCapabilitiesDisjoint() async throws {
        let store = MemoryAccountCredentialStore(credential: try makeFixtureCredential())
        let validationAuthorizer = makeCredentialAuthorizer(store: store)
        let apiAuthorizer = makeCredentialAuthorizer(
            store: store,
            allowedPaths: fixturePlaybackAllowedPaths
        )
        let navigationRequest = HTTPRequest(
            url: try #require(
                URL(string: "https://api.bilibili.com/x/web-interface/nav")
            )
        )
        let playbackRequest = HTTPRequest(
            url: try #require(
                URL(string: "https://api.bilibili.com/x/player/playurl")
            )
        )

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await validationAuthorizer.authorize(playbackRequest)
        }
        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await apiAuthorizer.authorize(navigationRequest)
        }
    }

    @Test(
        arguments: [
            ("http://api.bilibili.com/x/player/playurl", .get),
            ("https://api.bilibili.com.evil.invalid/x/player/playurl", .get),
            ("https://i0.hdslb.com/x/player/playurl", .get),
            ("http://127.0.0.1:8080/x/player/playurl", .get),
            (
                "https://api.bilibili.com:444/x/player/playurl",
                .get
            ),
            ("https://api.bilibili.com/x/player/playurl", .post),
            ("https://user@api.bilibili.com/x/player/playurl", .get),
            ("https://api.bilibili.com/x/player/playurl#fragment", .get),
            ("https://api.bilibili.com/x/player/playurl/", .get),
            ("https://api.bilibili.com/x/player/playurl/extra", .get),
            ("https://api.bilibili.com/x/player/playurl-similar", .get),
            ("https://api.bilibili.com/%78/player/playurl", .get),
            ("https://api.bilibili.com/x/player/wbi/playurl", .get),
            ("https://api.bilibili.com/x/v2/history/report", .get),
            ("https://api.bilibili.com/x/web-interface/future", .get)
        ] as [(String, HTTPMethod)]
    )
    func rejectsNonAPIReadCapabilities(urlString: String, method: HTTPMethod) async throws {
        let authorizer = makeCredentialAuthorizer(
            store: MemoryAccountCredentialStore(credential: try makeFixtureCredential()),
            allowedPaths: fixturePlaybackAllowedPaths
        )
        let request = HTTPRequest(
            url: try #require(URL(string: urlString)),
            method: method
        )

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(request)
        }
    }

    @Test(arguments: ["cOoKiE", "aUtHoRiZaTiOn", "x-CsRf-ToKeN"])
    func rejectsPreexistingCredentialHeadersCaseInsensitively(header: String) async throws {
        let authorizer = makeCredentialAuthorizer(
            store: MemoryAccountCredentialStore(credential: try makeFixtureCredential())
        )
        let request = HTTPRequest(
            url: try #require(
                URL(string: "https://api.bilibili.com/x/web-interface/nav")
            ),
            headers: [header: "FIXTURE_PREEXISTING_VALUE"]
        )

        await #expect(
            throws: BiliRequestAuthorizationError.credentialHeaderAlreadyPresent
        ) {
            try await authorizer.authorize(request)
        }
    }

    @Test
    func missingCredentialFailsWithoutChangingRequest() async throws {
        let authorizer = makeCredentialAuthorizer(store: MemoryAccountCredentialStore())
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
        let expiredStore = MemoryAccountCredentialStore(
            credential: try makeFixtureCredential(expiresAt: .distantPast)
        )
        let expiredAuthorizer = makeCredentialAuthorizer(store: expiredStore)

        await #expect(throws: BiliRequestAuthorizationError.expiredCredential) {
            try await expiredAuthorizer.authorize(HTTPRequest(url: endpoint))
        }
        #expect(expiredStore.deleteCount == 1)

        let corruptStore = MemoryAccountCredentialStore(
            loadError: AccountCredentialStoreError.corruptCredential
        )
        let corruptAuthorizer = makeCredentialAuthorizer(store: corruptStore)
        await #expect(throws: BiliRequestAuthorizationError.invalidCredential) {
            try await corruptAuthorizer.authorize(HTTPRequest(url: endpoint))
        }
        #expect(corruptStore.deleteCount == 1)

        let deletionFailure = MemoryAccountCredentialStore(
            credential: try makeFixtureCredential(expiresAt: .distantPast),
            deleteError: StubAuthError.offline
        )
        let deletionFailureAuthorizer = makeCredentialAuthorizer(store: deletionFailure)
        await #expect(
            throws: BiliRequestAuthorizationError.credentialStoreUnavailable
        ) {
            try await deletionFailureAuthorizer.authorize(
                HTTPRequest(url: endpoint)
            )
        }
    }

    /// Keychain 不可用：只有调用方已确认未登录时才按无凭据处理，否则失败关闭；都不改动 Keychain。
    @Test(arguments: [
        (true, BiliRequestAuthorizationError.missingCredential),
        (false, .credentialStoreUnavailable)
    ])
    func unavailableStoreCountsAsMissingOnlyWhenSignedOutIsConfirmed(
        isConfirmedSignedOut: Bool,
        expected: BiliRequestAuthorizationError
    ) async throws {
        let endpoint = try #require(
            URL(string: "https://api.bilibili.com/x/web-interface/nav")
        )
        let store = MemoryAccountCredentialStore(loadError: StubAuthError.offline)
        let authorizer = makeCredentialAuthorizer(
            store: store,
            isConfirmedSignedOut: { isConfirmedSignedOut }
        )

        await #expect(throws: expected) {
            try await authorizer.authorize(HTTPRequest(url: endpoint))
        }
        #expect(store.deleteCount == 0)
    }

    @Test
    func restoreValidCredentialUsesAuthorizedNavigationRequest() async throws {
        let transport = RecordingAuthTransport(
            responses: [navigationResponse(isLogin: true)]
        )
        let authorizer = makeCredentialAuthorizer(
            store: MemoryAccountCredentialStore(credential: try makeFixtureCredential()),
            transport: transport
        )

        let session = try await authorizer.restoreAccountSession()

        #expect(session == .signedIn(nil))
        let request = try #require(await transport.requests.last)
        #expect(request.url.absoluteString == "https://api.bilibili.com/x/web-interface/nav")
        #expect(request.headers["Cookie"]?.contains("SESSDATA=FIXTURE_") == true)
    }

    @Test
    func restoreMissingOrRemotelyInvalidCredentialFallsBackAndPurges() async throws {
        let missingTransport = RecordingAuthTransport(
            responses: [navigationResponse(isLogin: true)]
        )
        let missing = makeCredentialAuthorizer(
            store: MemoryAccountCredentialStore(),
            transport: missingTransport
        )
        #expect(
            try await missing.restoreAccountSession()
                == .signedOut(hadCredential: false)
        )
        #expect(await missingTransport.requests.isEmpty)

        let invalidStore = MemoryAccountCredentialStore(
            credential: try makeFixtureCredential()
        )
        let invalid = makeCredentialAuthorizer(
            store: invalidStore,
            transport: RecordingAuthTransport(
                responses: [navigationResponse(isLogin: false)]
            )
        )
        #expect(
            try await invalid.restoreAccountSession()
                == .signedOut(hadCredential: true)
        )
        #expect(invalidStore.deleteCount == 1)

        let failedPurge = makeCredentialAuthorizer(
            store: MemoryAccountCredentialStore(
                credential: try makeFixtureCredential(),
                deleteError: StubAuthError.offline
            ),
            transport: RecordingAuthTransport(
                responses: [navigationResponse(isLogin: false)]
            )
        )
        await #expect(
            throws: BiliRequestAuthorizationError.credentialStoreUnavailable
        ) {
            try await failedPurge.restoreAccountSession()
        }
    }

    @Test(arguments: [0, -101])
    func explicitSignedOutAnswerPurgesWhicheverCodeCarriesIt(code: Int) async throws {
        let store = MemoryAccountCredentialStore(credential: try makeFixtureCredential())
        let authorizer = makeCredentialAuthorizer(
            store: store,
            transport: RecordingAuthTransport(
                responses: [navigationResponse(isLogin: false, code: code)]
            )
        )

        #expect(
            try await authorizer.restoreAccountSession()
                == .signedOut(hadCredential: true)
        )
        #expect(store.deleteCount == 1)
    }

    /// 校验旧凭据期间另一窗口的续期换上了新凭据：不删新凭据，改用它再校验一次。
    @Test
    func signedOutAnswerForAReplacedCredentialRevalidatesTheReplacement() async throws {
        let store = MemoryAccountCredentialStore(credential: try makeFixtureCredential())
        let renewed = try makeFixtureCredential(
            expiresAt: Date(timeIntervalSince1970: 4_133_980_800)
        )
        let transport = RecordingAuthTransport(
            responses: [
                navigationResponse(isLogin: false),
                navigationResponse(isLogin: true, includesIdentity: true)
            ],
            suspendingRequest: 1
        )
        let authorizer = makeCredentialAuthorizer(store: store, transport: transport)

        async let restored = authorizer.restoreAccountSession()
        await transport.waitForSuspendedRequest()
        try store.save(renewed)
        await transport.resumeSuspendedRequest()

        guard case .signedIn = try await restored else {
            Issue.record("新凭据仍有效时应恢复为已登录")
            return
        }
        #expect(store.deleteCount == 0)
        #expect(try store.load() == renewed)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: [-412, -352])
    func otherRejectionCodesKeepStoredCredential(code: Int) async throws {
        let store = MemoryAccountCredentialStore(credential: try makeFixtureCredential())
        let authorizer = makeCredentialAuthorizer(
            store: store,
            transport: RecordingAuthTransport(
                responses: [navigationResponse(isLogin: false, code: code)]
            )
        )

        await #expect(throws: BiliRequestAuthorizationError.validationUnavailable) {
            try await authorizer.restoreAccountSession()
        }
        #expect(store.deleteCount == 0)
    }

    /// 只有 -101 与 `isLogin=false` 同时出现才算明确未登录；矛盾或缺字段的响应按校验不可用，凭据保留。
    @Test(arguments: [
        #"{"code":-101,"data":{"isLogin":true}}"#,
        #"{"code":-101,"message":"账号未登录"}"#,
        #"{"code":-101,"data":{}}"#
    ])
    func malformedNotLoggedInAnswerKeepsStoredCredential(body: String) async throws {
        let store = MemoryAccountCredentialStore(credential: try makeFixtureCredential())
        let authorizer = makeCredentialAuthorizer(
            store: store,
            transport: RecordingAuthTransport(
                responses: [
                    HTTPResponse(
                        statusCode: 200,
                        headers: ["Content-Type": "application/json"],
                        body: Data(body.utf8)
                    )
                ]
            )
        )

        await #expect(throws: BiliRequestAuthorizationError.validationUnavailable) {
            try await authorizer.restoreAccountSession()
        }
        #expect(store.deleteCount == 0)
    }

    @Test
    func temporaryValidationFailureKeepsStoredCredential() async throws {
        let store = MemoryAccountCredentialStore(credential: try makeFixtureCredential())
        let authorizer = makeCredentialAuthorizer(
            store: store,
            transport: RecordingAuthTransport(errors: [StubAuthError.offline])
        )

        await #expect(throws: BiliRequestAuthorizationError.validationUnavailable) {
            try await authorizer.restoreAccountSession()
        }
        #expect(store.deleteCount == 0)
        #expect(try store.load() != nil)
    }
}
