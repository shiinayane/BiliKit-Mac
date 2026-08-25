import BiliAPI
import BiliApplication
import BiliNetworking
import Foundation
import Testing

struct BiliWatchProgressRepositoryTests {
    @Test
    func buildsOnlyCurrentWBIHeartbeatContract() async throws {
        let transport = WatchProgressTransport()
        let authorizer = RecordingWriteAuthorizer()
        let client = BiliAPIClient(
            transport: transport,
            historyWriteAuthorizer: authorizer,
            timestampProvider: { 1_777_777_777 }
        )

        try await client.reportWatchProgress(try report(event: .paused))

        let request = try #require(await authorizer.request)
        let components = try #require(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        )
        #expect(components.scheme == "https")
        #expect(components.host == "api.bilibili.com")
        #expect(components.path == "/x/click-interface/web/heartbeat")
        let query = Dictionary(
            uniqueKeysWithValues: try #require(components.queryItems).map {
                ($0.name, $0.value ?? "")
            }
        )
        #expect(
            Set(query.keys) == [
                "w_start_ts", "w_aid", "w_dt", "w_realtime", "w_played_time",
                "w_real_played_time", "w_video_duration",
                "w_last_play_progress_time", "web_location", "wts", "w_rid",
            ]
        )
        #expect(query["w_start_ts"] == "1777777700")
        #expect(query["w_aid"] == "11")
        #expect(query["w_dt"] == "2")
        #expect(query["w_realtime"] == "20")
        #expect(query["w_played_time"] == "18")
        #expect(query["w_real_played_time"] == "17")
        #expect(query["w_video_duration"] == "120")
        #expect(query["w_last_play_progress_time"] == "18")
        #expect(query["web_location"] == "1315873")
        #expect(query["wts"] == "1777777777")
        #expect(query["w_rid"]?.count == 32)
        #expect(request.method == .post)
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(request.headers["Referer"] == "https://www.bilibili.com/video/BV1FIXTURE/")
        #expect(request.headers["Origin"] == nil)
        #expect(request.headers["Cookie"] == nil)
        let body = try #require(request.body.flatMap { String(data: $0, encoding: .utf8) })
        let fields = try #require(Self.decodedFields(body))
        #expect(
            Set(fields.keys) == [
                "start_ts", "aid", "cid", "type", "sub_type", "dt", "play_type",
                "realtime", "played_time", "real_played_time", "refer_url",
                "video_duration", "last_play_progress_time", "max_play_progress_time",
                "outer", "mobi_app", "device", "platform", "session",
            ]
        )
        #expect(fields["play_type"] == "2")
        #expect(fields["max_play_progress_time"] == "33")
        #expect(fields["refer_url"] == request.headers["Referer"])
        #expect(await transport.requestCount == 2)
    }

    @Test
    func naturalCompletionUsesFinishedSentinel() async throws {
        let authorizer = RecordingWriteAuthorizer()
        let client = BiliAPIClient(
            transport: WatchProgressTransport(),
            historyWriteAuthorizer: authorizer,
            timestampProvider: { 1_777_777_777 }
        )

        try await client.reportWatchProgress(
            try report(event: .ended, completed: true)
        )

        let request = try #require(await authorizer.request)
        let body = try #require(request.body.flatMap { String(data: $0, encoding: .utf8) })
        #expect(Self.decodedFields(body)?["played_time"] == "-1")
        let query = try #require(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
        )
        #expect(query.first(where: { $0.name == "w_played_time" })?.value == "-1")
    }

    @Test
    func missingAuthorizerDoesNotFetchWBIOrTouchTransport() async throws {
        let transport = WatchProgressTransport()
        let client = BiliAPIClient(transport: transport)

        await #expect(throws: BiliAPIError.authorizationRequired) {
            try await client.reportWatchProgress(try report(event: .started))
        }
        #expect(await transport.requestCount == 0)
    }

    @Test(arguments: [403, 412])
    func mapsHTTPRiskControlToRequestRestricted(status: Int) async throws {
        let repository = BiliWatchProgressRepository(
            client: BiliAPIClient(
                transport: WatchProgressTransport(heartbeatStatus: status),
                historyWriteAuthorizer: RecordingWriteAuthorizer(),
                timestampProvider: { 1_777_777_777 }
            )
        )

        await #expect(throws: WatchProgressError.requestRestricted) {
            try await repository.report(try report(event: .periodic))
        }
    }

    @Test(arguments: [-101, -111])
    func mapsCredentialBusinessFailureToAuthenticationInvalid(code: Int) async throws {
        let repository = BiliWatchProgressRepository(
            client: BiliAPIClient(
                transport: WatchProgressTransport(heartbeatCode: code),
                historyWriteAuthorizer: RecordingWriteAuthorizer(),
                timestampProvider: { 1_777_777_777 }
            )
        )

        await #expect(throws: WatchProgressError.authenticationInvalid) {
            try await repository.report(try report(event: .periodic))
        }
    }

    private func report(
        event: WatchProgressEvent,
        completed: Bool = false
    ) throws -> WatchProgressReport {
        let identity = PlaybackItemIdentity(bvid: "BV1FIXTURE", cid: 22)
        let target = try #require(
            WatchProgressTarget(
                aid: 11,
                identity: identity,
                loadIntent: PlaybackLoadIntent()
            )
        )
        return try #require(
            WatchProgressReport(
                target: target,
                event: event,
                sessionStartTimestamp: 1_777_777_700,
                sessionID: "0123456789abcdef0123456789abcdef",
                generation: 1,
                sequence: 1,
                positionSeconds: 18,
                maximumPositionSeconds: 33,
                durationSeconds: 120,
                elapsedSeconds: 20,
                playedSeconds: 17,
                completed: completed
            )
        )
    }

    private static func decodedFields(_ value: String) -> [String: String]? {
        var components = URLComponents()
        components.percentEncodedQuery = value
        guard let items = components.queryItems else { return nil }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
}

private actor WatchProgressTransport: HTTPTransport {
    private let heartbeatStatus: Int
    private let heartbeatCode: Int
    private(set) var requestCount = 0

    init(heartbeatStatus: Int = 200, heartbeatCode: Int = 0) {
        self.heartbeatStatus = heartbeatStatus
        self.heartbeatCode = heartbeatCode
    }

    func send(_ request: HTTPRequest) async -> HTTPResponse {
        requestCount += 1
        if request.url.path == "/x/web-interface/nav" {
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    """
                    {"code":0,"data":{"wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/0123456789abcdef0123456789abcdef.png","sub_url":"https://i0.hdslb.com/bfs/wbi/fedcba9876543210fedcba9876543210.png"}}}
                    """.utf8
                )
            )
        }
        return HTTPResponse(
            statusCode: heartbeatStatus,
            headers: ["Content-Type": "application/json"],
            body: Data("{\"code\":\(heartbeatCode),\"message\":\"fixture\"}".utf8)
        )
    }
}

private actor RecordingWriteAuthorizer: HTTPRequestAuthorizing {
    private(set) var request: HTTPRequest?

    func authorize(_ request: HTTPRequest) -> HTTPRequest {
        self.request = request
        return request
    }
}
