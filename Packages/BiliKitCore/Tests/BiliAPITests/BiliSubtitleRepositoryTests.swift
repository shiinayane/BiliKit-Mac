import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

@Suite(.timeLimit(.minutes(1)))
struct BiliSubtitleRepositoryTests {
    private let identity = PlaybackItemIdentity(
        bvid: "BV1SubtitleFixture",
        cid: 900_001
    )

    @Test
    func catalogClassifiesAutomaticMetadataWithoutLanguageAllowlist() throws {
        let payload = try JSONDecoder().decode(
            SubtitleCatalogPayload.self,
            from: Data(
                #"""
                {
                  "need_login_subtitle": false,
                  "subtitle": {
                    "subtitles": [
                      {"id": 1, "lan": "zh", "lan_doc": "中文", "subtitle_url": "https://aisubtitle.hdslb.com/bfs/subtitle/1.json", "ai_type": 0, "ai_status": 0},
                      {"id": 2, "lan": "ai-zh", "lan_doc": "中文", "subtitle_url": "https://aisubtitle.hdslb.com/bfs/subtitle/2.json", "ai_type": 0, "ai_status": 2},
                      {"id": 3, "lan": "ai-en", "lan_doc": "English", "subtitle_url": "https://aisubtitle.hdslb.com/bfs/subtitle/3.json", "ai_type": 1, "ai_status": 2},
                      {"id": 4, "lan": "ai-ja", "lan_doc": "日本語", "subtitle_url": "https://aisubtitle.hdslb.com/bfs/subtitle/4.json", "ai_type": 1, "ai_status": 2},
                      {"id": 5, "lan": "ai-fr", "lan_doc": "Français", "subtitle_url": "https://aisubtitle.hdslb.com/bfs/subtitle/5.json", "ai_type": 9, "ai_status": 7},
                      {"id": 6, "lan": "ai-fr", "lan_doc": "Français", "subtitle_url": "https://aisubtitle.hdslb.com/bfs/subtitle/6.json", "ai_type": 1, "ai_status": 2},
                      {"id": 7, "lan": "ai-ZH", "lan_doc": "中文", "subtitle_url": "https://aisubtitle.hdslb.com/bfs/subtitle/7.json", "ai_type": 0, "ai_status": 2},
                      {"id": 8, "lan": "zh-Hans", "lan_doc": "中文", "subtitle_url": "https://aisubtitle.hdslb.com/bfs/subtitle/8.json", "ai_type": 0, "ai_status": 0},
                      {"id": 9, "lan": "en", "lan_doc": "English", "subtitle_url": "https://aisubtitle.hdslb.com/bfs/subtitle/9.json"}
                    ]
                  }
                }
                """#.utf8
            )
        )

        let tracks = try payload.resources().map(\.track)

        #expect(
            tracks.map(\.languageCode) == [
                "zh", "ai-zh", "ai-en", "ai-ja", "ai-fr", "ai-fr", "ai-ZH",
                "zh-Hans", "en"
            ]
        )
        #expect(
            tracks.map(\.kind) == [
                .standard, .automatic, .automatic, .automatic, .unknown,
                .automatic, .automatic, .unknown, .unknown
            ]
        )
    }

    @Test
    func catalogAndBodyDecodeThroughSeparatedAuthorizationBoundary() async throws {
        let catalogTransport = StubTransport(
            responses: [
                try fixtureResponse("nav"),
                try catalogResponse()
            ]
        )
        let bodyTransport = StubTransport(
            responses: [try fixtureResponse("subtitle-body")]
        )
        let authorizer = StubAuthorizer()
        let client = BiliAPIClient(
            transport: catalogTransport,
            requestAuthorizer: authorizer,
            timestampProvider: { 1_700_000_000 }
        )
        let repository = BiliSubtitleRepository(
            client: client,
            bodyTransport: bodyTransport
        )

        let tracks = try await repository.tracks(for: identity)
        let track = try #require(tracks.first)
        let cues = try await repository.cues(
            for: track.id,
            identity: identity
        )

        #expect(tracks.count == 1)
        #expect(track.languageCode == "zh-CN")
        #expect(track.displayName == "中文（简体）")
        #expect(track.kind == .unknown)
        #expect(cues.count == 2)
        #expect(cues[0].startSeconds == 1.25)
        #expect(cues[0].endSeconds == 3.5)
        #expect(cues[0].text == "这是手写的字幕测试内容。")

        let catalogRequests = catalogTransport.capturedRequests()
        #expect(
            catalogRequests.map(\.url.path) == [
                "/x/web-interface/nav",
                "/x/player/wbi/v2"
            ]
        )
        #expect(catalogRequests[0].headers["Cookie"] == nil)
        let catalogRequest = catalogRequests[1]
        #expect(catalogRequest.headers["Cookie"] == StubAuthorizer.cookie)
        let catalogQuery = URLComponents(
            url: catalogRequest.url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(catalogQuery?.first(where: { $0.name == "bvid" })?.value == identity.bvid)
        #expect(catalogQuery?.first(where: { $0.name == "cid" })?.value == "900001")
        #expect(catalogQuery?.first(where: { $0.name == "wts" })?.value == "1700000000")
        #expect(catalogQuery?.first(where: { $0.name == "w_rid" })?.value?.count == 32)
        #expect(await authorizer.capturedPaths() == ["/x/player/wbi/v2"])

        let bodyRequest = try #require(
            bodyTransport.capturedRequests().first
        )
        #expect(bodyRequest.url.host == "aisubtitle.hdslb.com")
        #expect(bodyRequest.headers["Cookie"] == nil)
        #expect(bodyRequest.headers["Referer"]?.contains(identity.bvid) == true)
    }

    @Test
    func catalogSkipsEmptyURLPlaceholderBeforeUsableTrack() async throws {
        let repository = BiliSubtitleRepository(
            client: BiliAPIClient(
                transport: StubTransport(
                    responses: [
                        try fixtureResponse("nav"),
                        try catalogResponse(prependingEmptyURLTrack: true)
                    ]
                ),
                requestAuthorizer: StubAuthorizer(),
                timestampProvider: { 1_700_000_000 }
            ),
            bodyTransport: StubTransport(responses: [])
        )

        let tracks = try await repository.tracks(for: identity)

        #expect(tracks.count == 1)
        #expect(tracks.first?.id == "900001")
    }

    @Test
    func catalogRequiresAuthorizationBeforeTransport() async {
        let catalogTransport = StubTransport(responses: [])
        let client = BiliAPIClient(transport: catalogTransport)
        let repository = BiliSubtitleRepository(
            client: client,
            bodyTransport: StubTransport(responses: [])
        )

        await #expect(throws: SubtitleApplicationError.authenticationRequired) {
            try await repository.tracks(for: identity)
        }
        #expect(catalogTransport.capturedRequests().isEmpty)
    }

    @Test
    func catalogRejectsUntrustedSubtitleOriginBeforeBodyTransport() async throws {
        let catalogTransport = StubTransport(
            responses: [
                try fixtureResponse("nav"),
                try fixtureResponse("subtitle-catalog")
            ]
        )
        let bodyTransport = StubTransport(responses: [])
        let repository = BiliSubtitleRepository(
            client: BiliAPIClient(
                transport: catalogTransport,
                requestAuthorizer: StubAuthorizer(),
                timestampProvider: { 1_700_000_000 }
            ),
            bodyTransport: bodyTransport
        )

        await #expect(throws: SubtitleApplicationError.invalidResponse) {
            try await repository.tracks(for: identity)
        }
        #expect(bodyTransport.capturedRequests().isEmpty)
    }

    @Test
    func bodyRejectsHTMLAndJSONErrorFixtures() async throws {
        for (response, expected) in [
            (
                try fixtureResponse(
                    "m4-error",
                    extension: "html",
                    contentType: "text/html"
                ),
                SubtitleApplicationError.requestRestricted
            ),
            (
                try fixtureResponse("m4-error"),
                SubtitleApplicationError.invalidResponse
            )
        ] {
            let (repository, track) = try await repository(bodyResponse: response)
            await #expect(throws: expected) {
                try await repository.cues(
                    for: track.id,
                    identity: identity
                )
            }
        }
    }

    enum Stage: Sendable {
        case catalog
        case body
    }

    /// 目录与正文使用同一映射；`nil` 表示 transport 没有响应（抛出非 API 错误）。
    static let failureCases: [(Stage, HTTPResponse?, SubtitleApplicationError)] = [
        (.catalog, jsonResponse("", statusCode: 412), .requestRestricted),
        (.catalog, jsonResponse(#"{"code":-352,"message":"fixture"}"#), .requestRestricted),
        (.catalog, nil, .transportFailure),
        (.body, jsonResponse("", statusCode: 412), .requestRestricted),
        (.body, jsonResponse("", statusCode: 500), .unavailable),
        (.body, nil, .transportFailure)
    ]

    @Test(arguments: failureCases)
    func failuresMapToSubtitleApplicationError(
        stage: Stage,
        response: HTTPResponse?,
        expected: SubtitleApplicationError
    ) async throws {
        switch stage {
        case .catalog:
            let repository = BiliSubtitleRepository(
                client: BiliAPIClient(
                    transport: StubTransport(
                        responses: [try fixtureResponse("nav")] + [response].compactMap { $0 }
                    ),
                    requestAuthorizer: StubAuthorizer(),
                    timestampProvider: { 1_700_000_000 }
                ),
                bodyTransport: StubTransport(responses: [])
            )
            await #expect(throws: expected) {
                try await repository.tracks(for: identity)
            }
        case .body:
            let (repository, track) = try await repository(bodyResponse: response)
            await #expect(throws: expected) {
                try await repository.cues(for: track.id, identity: identity)
            }
        }
    }

    @Test
    func bodyRejectsNonmonotonicAndOutOfBoundsCues() async throws {
        let fixture = try fixtureResponse("subtitle-body")
        let body = String(decoding: fixture.body, as: UTF8.self)
        let invalidBodies = [
            body.replacingOccurrences(of: #""from": 4.0"#, with: #""from": 0.5"#),
            body.replacingOccurrences(of: #""to": 3.5"#, with: #""to": 90000"#)
        ]

        for invalidBody in invalidBodies {
            let response = HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(invalidBody.utf8)
            )
            let (repository, track) = try await repository(bodyResponse: response)
            await #expect(throws: SubtitleApplicationError.invalidResponse) {
                try await repository.cues(
                    for: track.id,
                    identity: identity
                )
            }
        }
    }

    @Test
    func bodyRejectsOversizedResponse() async throws {
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(repeating: 0x20, count: 2 * 1_024 * 1_024 + 1)
        )
        let (repository, track) = try await repository(bodyResponse: response)

        await #expect(throws: SubtitleApplicationError.invalidResponse) {
            try await repository.cues(for: track.id, identity: identity)
        }
    }

    @Test
    func resetRemovesInMemoryResourceMapping() async throws {
        let bodyTransport = StubTransport(
            responses: [try fixtureResponse("subtitle-body")]
        )
        let repository = BiliSubtitleRepository(
            client: BiliAPIClient(
                transport: StubTransport(
                    responses: [
                        try fixtureResponse("nav"),
                        try catalogResponse()
                    ]
                ),
                requestAuthorizer: StubAuthorizer(),
                timestampProvider: { 1_700_000_000 }
            ),
            bodyTransport: bodyTransport
        )
        let track = try #require(
            try await repository.tracks(for: identity).first
        )

        await repository.reset(for: identity)

        await #expect(throws: SubtitleApplicationError.invalidRequest) {
            try await repository.cues(for: track.id, identity: identity)
        }
        #expect(bodyTransport.capturedRequests().isEmpty)
    }

    @Test
    func resetInvalidatesCatalogThatFinishesAfterViewClosed() async throws {
        let catalogTransport = StubTransport([
            .response(try fixtureResponse("nav")),
            .suspended(try catalogResponse())
        ])
        let bodyTransport = StubTransport(
            responses: [try fixtureResponse("subtitle-body")]
        )
        let repository = BiliSubtitleRepository(
            client: BiliAPIClient(
                transport: catalogTransport,
                requestAuthorizer: StubAuthorizer(),
                timestampProvider: { 1_700_000_000 }
            ),
            bodyTransport: bodyTransport
        )
        let request = Task {
            try await repository.tracks(for: identity)
        }
        await catalogTransport.waitForRequests(2)

        await repository.reset(for: identity)
        catalogTransport.resumeSuspendedRequest()

        await #expect(throws: CancellationError.self) {
            try await request.value
        }
        await #expect(throws: SubtitleApplicationError.invalidRequest) {
            try await repository.cues(
                for: "900001",
                identity: identity
            )
        }
        #expect(bodyTransport.capturedRequests().isEmpty)
    }

    @Test(arguments: [
        "http://aisubtitle.hdslb.com/bfs/subtitle/a.json",
        "https://user@aisubtitle.hdslb.com/bfs/subtitle/a.json",
        "https://aisubtitle.hdslb.com:8443/bfs/subtitle/a.json",
        "https://127.0.0.1/bfs/subtitle/a.json",
        "https://aisubtitle.hdslb.com.attacker.invalid/bfs/subtitle/a.json",
        "https://aisubtitle.hdslb.com/other/a.json",
        "https://aisubtitle.hdslb.com/bfs/subtitle/a.json#fragment"
    ])
    func subtitlePolicyRejectsUnsafeOrigins(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(!SubtitleURLPolicy().allows(url))
    }

    private func repository(
        bodyResponse: HTTPResponse?
    ) async throws -> (BiliSubtitleRepository, SubtitleTrack) {
        let repository = BiliSubtitleRepository(
            client: BiliAPIClient(
                transport: StubTransport(
                    responses: [
                        try fixtureResponse("nav"),
                        try catalogResponse()
                    ]
                ),
                requestAuthorizer: StubAuthorizer(),
                timestampProvider: { 1_700_000_000 }
            ),
            bodyTransport: StubTransport(
                responses: [bodyResponse].compactMap { $0 }
            )
        )
        let track = try #require(
            try await repository.tracks(for: identity).first
        )
        return (repository, track)
    }

    private func catalogResponse(
        prependingEmptyURLTrack: Bool = false
    ) throws -> HTTPResponse {
        let fixture = try fixtureResponse("subtitle-catalog")
        let source = String(decoding: fixture.body, as: UTF8.self)
            .replacingOccurrences(
                of: "subtitle.example.invalid",
                with: "aisubtitle.hdslb.com"
            )
        var body = Data(source.utf8)
        if prependingEmptyURLTrack {
            var envelope = try #require(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            var data = try #require(envelope["data"] as? [String: Any])
            var subtitle = try #require(data["subtitle"] as? [String: Any])
            var tracks = try #require(subtitle["subtitles"] as? [[String: Any]])
            var placeholder = try #require(tracks.first)
            placeholder["id"] = 900_000
            placeholder["id_str"] = "900000"
            placeholder["subtitle_url"] = ""
            tracks.insert(placeholder, at: 0)
            subtitle["subtitles"] = tracks
            data["subtitle"] = subtitle
            envelope["data"] = data
            body = try JSONSerialization.data(withJSONObject: envelope)
        }
        return HTTPResponse(
            statusCode: fixture.statusCode,
            headers: fixture.headers,
            body: body
        )
    }
}
