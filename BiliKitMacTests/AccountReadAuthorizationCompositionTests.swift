import BiliAPI
import BiliApplication
import BiliAuthFeature
import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth
@testable import BiliKit

/// 账户读取的组装只给各 API client 恰好需要的 path，每个读 path 都能被真实授权器授权为只带 Cookie 的 GET。
///
/// 只有窗口已确认未登录、没有进行中或失败的复核、进程内也没有窗口登录时，才把 Keychain 不可用当作无凭据。
@Suite(.timeLimit(.minutes(1)))
struct AccountReadAuthorizationCompositionTests {
    /// 窗口状态、复核阶段、进程状态与期望结果。
    static let signedOutConfirmationCases:
        [(AccountSessionScope, AuthenticationResolutionPhase, AccountSessionScope, Bool)] = [
            (.signedOut, .signedOut, .unresolved, true),
            (.signedOut, .signedOut, .signedOut, true),
            (.signedOut, .other, .signedOut, true),
            (.signedOut, .restoring, .signedOut, false),
            (.signedOut, .failed, .signedOut, false),
            (.signedOut, .signedOut, .signedIn(accountID: 42), false),
            (.unresolved, .signedOut, .unresolved, false),
            (.signedIn(accountID: 42), .signedIn, .signedIn(accountID: 42), false)
        ]

    /// 只有窗口已确认未登录、没有进行中或失败的复核、进程内也没有窗口登录时，Keychain 不可用才按无凭据处理。
    @Test(arguments: signedOutConfirmationCases)
    func signedOutIsConfirmedOnlyWhenNothingSuggestsAnAccount(
        windowScope: AccountSessionScope,
        resolutionPhase: AuthenticationResolutionPhase,
        processScope: AccountSessionScope,
        expected: Bool
    ) {
        #expect(
            AccountSignedOutConfirmation.isConfirmed(
                windowScope: windowScope,
                resolutionPhase: resolutionPhase,
                processScope: processScope
            ) == expected
        )
    }

    @Test
    @MainActor
    func productionCapabilitiesStayExactAndMinimal() {
        #expect(
            LiveAPIClients.accountSessionValidationAllowedPaths == [
                "/x/web-interface/nav"
            ]
        )
        #expect(
            LiveAPIClients.mainAccountReadAllowedPaths == [
                "/x/player/wbi/playurl",
                "/x/player/wbi/v2",
                "/x/v2/dm/web/view",
                "/x/v2/dm/wbi/web/seg.so",
                "/x/v2/history/toview/web",
                "/x/v2/reply/dialog/cursor",
                "/x/v2/reply/reply",
                "/x/v2/reply/wbi/main",
                "/x/v3/fav/folder/created/list-all",
                "/x/v3/fav/resource/list",
                "/x/web-interface/archive/related",
                "/x/web-interface/archive/relation",
                "/x/web-interface/card",
                "/x/web-interface/history/cursor",
                "/x/web-interface/popular",
                "/x/web-interface/wbi/search/type",
                "/x/web-interface/wbi/view"
            ]
        )
        #expect(
            LiveAPIClients.cdnBenchmarkAccountReadAllowedPaths == [
                "/x/player/wbi/playurl",
                "/x/web-interface/wbi/view"
            ]
        )
        #expect(LiveAPIClients.watchProgressAccountReadAllowedPaths == nil)
        #expect(
            LiveAPIClients.mainAppReadAllowedPaths == [
                "/x/v2/feed/index", "/x/v2/space/archive/cursor", "/x/v2/space/search"
            ]
        )
    }

    /// allowlist 由 endpoint 导出的常量组成：常量改了 path，上面的字面量集合与这里一起报警。
    @Test
    func exportedPathConstantsKeepTheirLiteralPaths() {
        #expect(BiliAuthenticationService.sessionValidationPath == "/x/web-interface/nav")
        let constants: [(String, String)] = [
            (BiliAccountReadPath.playURL, "/x/player/wbi/playurl"),
            (BiliAccountReadPath.subtitleCatalog, "/x/player/wbi/v2"),
            (BiliAccountReadPath.danmakuSegment, "/x/v2/dm/wbi/web/seg.so"),
            (BiliAccountReadPath.danmakuView, "/x/v2/dm/web/view"),
            (BiliAccountReadPath.rootComments, "/x/v2/reply/wbi/main"),
            (BiliAccountReadPath.commentReplies, "/x/v2/reply/reply"),
            (BiliAccountReadPath.commentDialog, "/x/v2/reply/dialog/cursor"),
            (BiliAccountReadPath.videoDetail, "/x/web-interface/wbi/view"),
            (BiliAccountReadPath.relatedVideos, "/x/web-interface/archive/related"),
            (BiliAccountReadPath.uploaderCard, "/x/web-interface/card"),
            (BiliAccountReadPath.watchHistory, "/x/web-interface/history/cursor"),
            (BiliAccountReadPath.watchLater, "/x/v2/history/toview/web"),
            (BiliAccountReadPath.favoriteFolders, "/x/v3/fav/folder/created/list-all"),
            (BiliAccountReadPath.favoriteFolderContent, "/x/v3/fav/resource/list"),
            (BiliAccountReadPath.videoRelation, "/x/web-interface/archive/relation"),
            (BiliAccountReadPath.popular, "/x/web-interface/popular"),
            (BiliAccountReadPath.videoSearch, "/x/web-interface/wbi/search/type")
        ]
        #expect(BiliAppReadPath.recommendations == "/x/v2/feed/index")
        #expect(BiliAppReadPath.uploaderVideos == "/x/v2/space/archive/cursor")
        #expect(BiliAppReadPath.uploaderVideoSearch == "/x/v2/space/search")
        for (constant, literal) in constants {
            #expect(constant == literal)
        }
    }

    @Test
    @MainActor
    func everyProductionReadPathCanAuthorizeAnExactGet() async throws {
        let credential = try makeCompositionFixtureCredential()
        let configuredCapabilities = [
            LiveAPIClients.accountSessionValidationAllowedPaths,
            LiveAPIClients.mainAccountReadAllowedPaths,
            LiveAPIClients.cdnBenchmarkAccountReadAllowedPaths
        ]

        for allowedPaths in configuredCapabilities {
            let authorizer = BiliCredentialRequestAuthorizer(
                store: CompositionFixtureCredentialStore(credential: credential),
                allowedPaths: allowedPaths,
                transport: AuthenticationHTTP.makeProductionTransport()
            )
            for path in allowedPaths {
                let request = HTTPRequest(
                    url: try #require(
                        URL(string: "https://api.bilibili.com\(path)?fixture=1")
                    )
                )

                let authorized = try await authorizer.authorize(request)

                #expect(authorized.url.path == path)
                #expect(authorized.method == .get)
                #expect(authorized.headers == ["Cookie": credential.cookieHeader])
            }
        }
    }
}

/// 网页与 App 的账户写能力只给窗口主 API，且恰好是这些 path；每个写 path 都能被真实的写授权器按它的 schema 授权：
/// BiliAuth 的 schema 表与 BiliAPI 的 `BiliAccountWritePath`、`BiliAppWritePath` 各写一份字面量，这里是两边唯一的
/// 交叉核对。
@Suite(.timeLimit(.minutes(1)))
struct AccountWriteAuthorizationCompositionTests {
    @Test
    @MainActor
    func onlyTheWindowAPIGetsTheExactWriteCapability() async throws {
        #expect(
            LiveAPIClients.mainAccountWriteAllowedPaths == [
                "/x/v2/history/toview/add",
                "/x/v2/history/toview/del",
                "/x/v3/fav/resource/deal",
                "/x/v3/fav/resource/batch-del",
                "/x/relation/modify"
            ]
        )
        #expect(
            LiveAPIClients.mainAppWriteAllowedPaths == [
                "/x/feed/dislike",
                "/x/feed/dislike/cancel",
                "/x/v2/view/like",
                "/x/v2/view/coin/add",
                "/x/v2/view/like/triple"
            ]
        )
        // 测速与观看进度 writer 没有账户写授权器：在发请求前就失败。
        for client in [LiveAPIClients.cdnBenchmark(), LiveAPIClients.watchProgressWriter()] {
            await #expect(throws: BiliAPIError.authorizationRequired) {
                try await client.addToWatchLater(bvid: "BV17x411w7KC", accountID: 7)
            }
        }
    }

    @Test
    @MainActor
    func everyProductionWritePathCanAuthorizeTheRequestTheClientBuilds() async throws {
        let authorizer = BiliAccountWriteRequestAuthorizer(
            store: CompositionFixtureCredentialStore(
                credential: try makeCompositionFixtureCredential()
            ),
            allowedPaths: LiveAPIClients.mainAccountWriteAllowedPaths
        )
        let requests = [
            BiliAccountWritePath.watchLaterAdd: ("https://www.bilibili.com/", "aid=170001"),
            BiliAccountWritePath.watchLaterRemove: (
                "https://www.bilibili.com/watchlater/", "aid=170001"
            ),
            BiliAccountWritePath.favoriteMembershipUpdate: (
                "https://www.bilibili.com/",
                "rid=170001&type=2&add_media_ids=11,12&del_media_ids=&platform=web"
            ),
            BiliAccountWritePath.favoriteFolderEntryRemove: (
                "https://www.bilibili.com/", "resources=170001:2&media_id=11&platform=web"
            ),
            BiliAccountWritePath.relationModify: (
                "https://www.bilibili.com/", "fid=7&act=1&re_src=11"
            )
        ]
        #expect(Set(requests.keys) == LiveAPIClients.mainAccountWriteAllowedPaths)

        for (path, (referer, body)) in requests {
            let request = HTTPRequest(
                url: try #require(URL(string: "https://api.bilibili.com\(path)")),
                method: .post,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Origin": "https://www.bilibili.com",
                    "Referer": referer,
                    "User-Agent": HTTPUserAgent.browserCompatible
                ],
                body: Data(body.utf8)
            )

            let authorized = try await authorizer.authorize(request, boundTo: "42")

            #expect(authorized.headers["Cookie"] == "SESSDATA=FIXTURE_SESSDATA_VALUE")
            #expect(authorized.body == Data("\(body)&csrf=FIXTURE_bili_jct_VALUE".utf8))
        }
    }

    @Test
    @MainActor
    func everyProductionAppWritePathCanAuthorizeTheRequestTheClientBuilds() async throws {
        let authorizer = BiliAppWriteRequestAuthorizer(
            store: CompositionFixtureCredentialStore(
                credential: try makeCompositionFixtureCredential()
            ),
            allowedPaths: LiveAPIClients.mainAppWriteAllowedPaths
        )
        let dislikeQuery = "goto=av&id=170001&reason_id=12&mobi_app=iphone&device=pad&build=1"
        let requests: [String: HTTPRequest] = [
            BiliAppWritePath.recommendationDislike: try Self.appGET(
                BiliAppWritePath.recommendationDislike,
                query: dislikeQuery
            ),
            BiliAppWritePath.recommendationDislikeCancel: try Self.appGET(
                BiliAppWritePath.recommendationDislikeCancel,
                query: dislikeQuery
            ),
            BiliAppWritePath.videoLike: try Self.appForm(
                BiliAppWritePath.videoLike,
                body: "aid=170001&like=0"
            ),
            BiliAppWritePath.videoCoin: try Self.appForm(
                BiliAppWritePath.videoCoin,
                body: "aid=170001&multiply=2&select_like=1"
            ),
            BiliAppWritePath.videoTriple: try Self.appForm(
                BiliAppWritePath.videoTriple,
                body: "aid=170001"
            )
        ]
        #expect(Set(requests.keys) == LiveAPIClients.mainAppWriteAllowedPaths)

        for (path, request) in requests {
            let authorized = try await authorizer.authorize(request, boundTo: "42")

            #expect(authorized.url.path == path)
            let signed =
                request.method == .get
                ? authorized.url.query
                : authorized.body.flatMap { String(data: $0, encoding: .utf8) }
            #expect(signed?.contains("access_key=") == true)
            #expect(signed?.contains("&sign=") == true)
        }
    }

    private static func appGET(_ path: String, query: String) throws -> HTTPRequest {
        HTTPRequest(
            url: try #require(URL(string: "https://app.bilibili.com\(path)?\(query)")),
            headers: [
                "Accept": "application/json",
                "User-Agent": HTTPUserAgent.browserCompatible
            ]
        )
    }

    private static func appForm(_ path: String, body: String) throws -> HTTPRequest {
        HTTPRequest(
            url: try #require(URL(string: "https://app.bilibili.com\(path)")),
            method: .post,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": HTTPUserAgent.browserCompatible
            ],
            body: Data(body.utf8)
        )
    }
}

private struct CompositionFixtureCredentialStore: AccountCredentialStoring {
    let credential: AccountCredential

    func load() -> AccountCredential? { credential }
    func save(_ credential: AccountCredential) {}
    func delete() {}
}

private func makeCompositionFixtureCredential() throws -> AccountCredential {
    try AccountCredential(
        cookies: WebCredentialCookieName.allCases.map { name in
            WebCredentialCookie(
                name: name,
                value: name == .userID ? "42" : "FIXTURE_\(name.rawValue)_VALUE",
                domain: ".bilibili.com",
                path: "/",
                isSecure: true,
                isHTTPOnly: name == .session,
                expiresAt: Date(timeIntervalSince1970: 4_102_444_800)
            )
        },
        appAccessToken: AppAccessToken(
            value: String(repeating: "f", count: 32),
            refreshToken: String(repeating: "0", count: 32),
            expiresAt: Date(timeIntervalSince1970: 4_102_444_800)
        )
    )
}
