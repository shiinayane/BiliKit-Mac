import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth
@testable import BiliKit

struct AccountReadAuthorizationCompositionTests {
    @Test
    @MainActor
    func productionCapabilitiesStayExactAndMinimal() {
        #expect(
            AppEnvironment.accountSessionValidationAllowedPaths == [
                "/x/web-interface/nav"
            ]
        )
        #expect(
            AppEnvironment.mainAccountReadAllowedPaths == [
                "/x/player/pagelist",
                "/x/player/playurl",
                "/x/player/wbi/v2",
                "/x/v2/dm/wbi/web/seg.so",
                "/x/v2/reply/reply",
                "/x/v2/reply/wbi/main",
                "/x/web-interface/archive/related",
                "/x/web-interface/card",
                "/x/web-interface/history/cursor",
                "/x/web-interface/popular",
                "/x/web-interface/view",
                "/x/web-interface/wbi/index/top/feed/rcmd",
                "/x/web-interface/wbi/search/type",
            ]
        )
        #expect(
            AppEnvironment.cdnBenchmarkAccountReadAllowedPaths == [
                "/x/player/playurl"
            ]
        )
        #expect(AppEnvironment.watchProgressAccountReadAllowedPaths == nil)
    }

    @Test
    @MainActor
    func everyProductionReadPathCanAuthorizeAnExactGet() async throws {
        let credential = try makeCompositionFixtureCredential()
        let configuredCapabilities = [
            AppEnvironment.accountSessionValidationAllowedPaths,
            AppEnvironment.mainAccountReadAllowedPaths,
            AppEnvironment.cdnBenchmarkAccountReadAllowedPaths,
        ]

        for allowedPaths in configuredCapabilities {
            let authorizer = BiliCredentialRequestAuthorizer(
                store: CompositionFixtureCredentialStore(credential: credential),
                allowedPaths: allowedPaths
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
                value: "FIXTURE_\(name.rawValue)_VALUE",
                domain: ".bilibili.com",
                path: "/",
                isSecure: true,
                isHTTPOnly: name == .session,
                expiresAt: Date(timeIntervalSince1970: 4_102_444_800)
            )
        }
    )
}
