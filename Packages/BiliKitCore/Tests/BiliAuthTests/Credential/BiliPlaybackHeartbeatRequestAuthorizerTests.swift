import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth

struct BiliPlaybackHeartbeatRequestAuthorizerTests {
    @Test
    func authorizesExactContractAndInjectsOnlySessionAndCSRF() async throws {
        let authorizer = BiliPlaybackHeartbeatRequestAuthorizer(
            store: MemoryWebCredentialStore(credential: try makeFixtureCredential())
        )

        let authorized = try await authorizer.authorize(try heartbeatRequest())

        #expect(authorized.headers["Cookie"] == "SESSDATA=FIXTURE_SESSDATA_VALUE")
        #expect(authorized.headers["Origin"] == nil)
        #expect(authorized.headers["DedeUserID"] == nil)
        let body = try #require(authorized.body.flatMap { String(data: $0, encoding: .utf8) })
        let fields = try #require(decodedFields(body))
        #expect(fields["csrf"] == "FIXTURE_bili_jct_VALUE")
        #expect(fields.count == 20)
    }

    @Test
    func rejectsEveryOriginMethodPathAndHeaderExpansion() async throws {
        let authorizer = BiliPlaybackHeartbeatRequestAuthorizer(
            store: MemoryWebCredentialStore(credential: try makeFixtureCredential())
        )
        let cases: [(String, HTTPMethod)] = [
            ("http://api.bilibili.com/x/click-interface/web/heartbeat?\(validQuery)", .post),
            (
                "https://api.bilibili.com.evil.invalid/x/click-interface/web/heartbeat?\(validQuery)",
                .post
            ),
            ("https://api.bilibili.com:444/x/click-interface/web/heartbeat?\(validQuery)", .post),
            ("https://user@api.bilibili.com/x/click-interface/web/heartbeat?\(validQuery)", .post),
            ("https://api.bilibili.com/x/click-interface/web/heartbeat", .post),
            (
                "https://api.bilibili.com/x/click-interface/web/heartbeat?\(validQuery)#fragment",
                .post
            ),
            ("https://api.bilibili.com/x/v2/history/report?\(validQuery)", .post),
            ("https://api.bilibili.com/x/click-interface/web/heartbeat?\(validQuery)", .get),
        ]
        for (urlString, method) in cases {
            let request = HTTPRequest(
                url: try #require(URL(string: urlString)),
                method: method,
                headers: validHeaders,
                body: Data(validBody.utf8)
            )
            await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
                try await authorizer.authorize(request)
            }
        }

        for header in ["Origin", "X-Unapproved", "Cookie", "Authorization", "X-CSRF-Token"] {
            let request = try heartbeatRequest(additionalHeader: header)
            await #expect(throws: (any Error).self) {
                try await authorizer.authorize(request)
            }
        }
    }

    @Test
    func rejectsExtraDuplicateOrMismatchedQueryAndBodyFacts() async throws {
        let authorizer = BiliPlaybackHeartbeatRequestAuthorizer(
            store: MemoryWebCredentialStore(credential: try makeFixtureCredential())
        )
        let invalidRequests = [
            try heartbeatRequest(body: validBody + "&quality=80"),
            try heartbeatRequest(body: validBody + "&csrf=PRESET"),
            try heartbeatRequest(body: validBody + "&aid=11"),
            try heartbeatRequest(
                body: validBody.replacingOccurrences(of: "aid=11", with: "aid=12")
            ),
            try heartbeatRequest(
                body: validBody.replacingOccurrences(of: "realtime=20", with: "realtime=16")
            ),
            try heartbeatRequest(
                body: validBody.replacingOccurrences(
                    of: "max_play_progress_time=33",
                    with: "max_play_progress_time=17"
                )
            ),
            try heartbeatRequest(query: validQuery + "&extra=1"),
            try heartbeatRequest(
                query: validQuery.replacingOccurrences(
                    of: "w_played_time=18",
                    with: "w_played_time=19"
                )
            ),
            try heartbeatRequest(
                query: validQuery.replacingOccurrences(
                    of: "w_video_duration=120",
                    with: "w_video_duration=121"
                )
            ),
        ]
        for request in invalidRequests {
            await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
                try await authorizer.authorize(request)
            }
        }
    }

    @Test
    func missingOrExpiredCredentialCannotAuthorizeWrite() async throws {
        let missing = BiliPlaybackHeartbeatRequestAuthorizer(
            store: MemoryWebCredentialStore()
        )
        await #expect(throws: BiliRequestAuthorizationError.missingCredential) {
            try await missing.authorize(try heartbeatRequest())
        }

        let store = MemoryWebCredentialStore(
            credential: try makeFixtureCredential(expiresAt: .distantPast)
        )
        let expired = BiliPlaybackHeartbeatRequestAuthorizer(store: store)
        await #expect(throws: BiliRequestAuthorizationError.expiredCredential) {
            try await expired.authorize(try heartbeatRequest())
        }
        #expect(store.deleteCount == 1)
    }

    @Test
    func endedAllowsEitherNaturalSentinelOrCurrentExitPosition() async throws {
        let authorizer = BiliPlaybackHeartbeatRequestAuthorizer(
            store: MemoryWebCredentialStore(credential: try makeFixtureCredential())
        )
        let exitBody = validBody.replacingOccurrences(
            of: "play_type=2",
            with: "play_type=4"
        )
        _ = try await authorizer.authorize(try heartbeatRequest(body: exitBody))

        let naturalBody = exitBody.replacingOccurrences(
            of: "&played_time=18&",
            with: "&played_time=-1&"
        )
        let naturalQuery = validQuery.replacingOccurrences(
            of: "&w_played_time=18&",
            with: "&w_played_time=-1&"
        )
        _ = try await authorizer.authorize(
            try heartbeatRequest(query: naturalQuery, body: naturalBody)
        )
    }

    private var validHeaders: [String: String] {
        [
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
            "Referer": "https://www.bilibili.com/video/BV1FIXTURE/",
            "User-Agent":
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 BiliKitMac/0.1",
        ]
    }

    private var validBody: String {
        [
            "start_ts=1777777700", "aid=11", "cid=22", "type=3", "sub_type=0",
            "dt=2", "play_type=2", "realtime=20", "played_time=18",
            "real_played_time=17",
            "refer_url=https://www.bilibili.com/video/BV1FIXTURE/",
            "video_duration=120", "last_play_progress_time=18",
            "max_play_progress_time=33", "outer=0", "mobi_app=web", "device=web",
            "platform=web", "session=0123456789abcdef0123456789abcdef",
        ].joined(separator: "&")
    }

    private var validQuery: String {
        [
            "w_aid=11", "w_dt=2", "w_last_play_progress_time=18",
            "w_played_time=18", "w_real_played_time=17", "w_realtime=20",
            "w_start_ts=1777777700", "w_video_duration=120",
            "web_location=1315873", "wts=1777777777",
            "w_rid=0123456789abcdef0123456789abcdef",
        ].joined(separator: "&")
    }

    private func heartbeatRequest(
        query: String? = nil,
        body: String? = nil,
        additionalHeader: String? = nil
    ) throws -> HTTPRequest {
        var headers = validHeaders
        if let additionalHeader {
            headers[additionalHeader] = "FIXTURE_PREEXISTING_VALUE"
        }
        return HTTPRequest(
            url: try #require(
                URL(
                    string:
                        "https://api.bilibili.com/x/click-interface/web/heartbeat?\(query ?? validQuery)"
                )
            ),
            method: .post,
            headers: headers,
            body: Data((body ?? validBody).utf8)
        )
    }

    private func decodedFields(_ value: String) -> [String: String]? {
        var components = URLComponents()
        components.percentEncodedQuery = value
        guard let items = components.queryItems else { return nil }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
}
