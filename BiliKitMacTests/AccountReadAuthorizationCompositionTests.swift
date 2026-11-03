import BiliAPI
import BiliApplication
import BiliAuthFeature
import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth
@testable import BiliKit

@Suite(.timeLimit(.minutes(1)))
struct AccountReadAuthorizationCompositionTests {
    /// 窗口状态、复核阶段、进程状态与期望结果。
    static let signedOutConfirmationCases:
        [(AccountSessionScope, AuthenticationResolutionPhase, AccountSessionScope, Bool)] = [
            (.signedOut, .other, .unresolved, true),
            (.signedOut, .other, .signedOut, true),
            (.signedOut, .restoring, .signedOut, false),
            (.signedOut, .failed, .signedOut, false),
            (.signedOut, .other, .signedIn(accountID: 42), false),
            (.unresolved, .other, .unresolved, false),
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
                "/x/space/wbi/arc/search",
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
                "/x/web-interface/wbi/index/top/feed/rcmd",
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
            (BiliAccountReadPath.uploaderVideos, "/x/space/wbi/arc/search"),
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
            (BiliAccountReadPath.recommendations, "/x/web-interface/wbi/index/top/feed/rcmd"),
            (BiliAccountReadPath.videoSearch, "/x/web-interface/wbi/search/type")
        ]
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

/// 窗口主 API 的每个写 path 都能被真实的账户写授权器按它的 schema 授权：BiliAuth 的 schema 表与 BiliAPI 的
/// `BiliAccountWritePath` 各写一份字面量，这里是两边唯一的交叉核对。
@Suite(.timeLimit(.minutes(1)))
struct AccountWriteAuthorizationCompositionTests {
    private static let recommendationFeedbackBody =
        "app_id=100&platform=5&from_spmid=&spmid=333.1007.0.0&goto=av&id=170001&mid=1"
        + "&track_id=web_rcmd.abc&feedback_page=1&reason_id=1"

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
            BiliAccountWritePath.videoLike: ("https://www.bilibili.com/", "aid=170001&like=1"),
            BiliAccountWritePath.videoCoin: (
                "https://www.bilibili.com/", "aid=170001&multiply=1&select_like=1"
            ),
            BiliAccountWritePath.videoTriple: ("https://www.bilibili.com/", "aid=170001"),
            BiliAccountWritePath.relationModify: (
                "https://www.bilibili.com/", "fid=7&act=1&re_src=11"
            ),
            BiliAccountWritePath.recommendationDislike: (
                "https://www.bilibili.com/", Self.recommendationFeedbackBody
            ),
            BiliAccountWritePath.recommendationDislikeCancel: (
                "https://www.bilibili.com/", Self.recommendationFeedbackBody
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
}

private struct CompositionFixtureCredentialStore: WebCredentialStoring {
    let credential: WebCredential

    func load() -> WebCredential? { credential }
    func save(_ credential: WebCredential) {}
    func delete() {}
}

private func makeCompositionFixtureCredential() throws -> WebCredential {
    try WebCredential(
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
        }
    )
}
