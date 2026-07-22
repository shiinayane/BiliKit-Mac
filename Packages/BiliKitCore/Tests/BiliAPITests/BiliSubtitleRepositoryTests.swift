import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing
@testable import BiliAPI

@Suite
struct BiliSubtitleRepositoryTests {
    private let identity = PlaybackItemIdentity(
        bvid: "BV1SubtitleFixture",
        cid: 900_001
    )

    @Test
    func catalogAndBodyDecodeThroughSeparatedAuthorizationBoundary() async throws {
        let catalogTransport = SubtitleRecordingTransport(
            responses: [try catalogResponse()]
        )
        let bodyTransport = SubtitleRecordingTransport(
            responses: [try fixtureResponse("subtitle-body")]
        )
        let authorizer = SubtitleRecordingAuthorizer()
        let client = BiliAPIClient(
            transport: catalogTransport,
            requestAuthorizer: authorizer
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
        #expect(track.kind == .standard)
        #expect(cues.count == 2)
        #expect(cues[0].startSeconds == 1.25)
        #expect(cues[0].endSeconds == 3.5)
        #expect(cues[0].text == "这是手写的字幕测试内容。")

        let catalogRequest = try #require(
            await catalogTransport.capturedRequests().first
        )
        #expect(catalogRequest.url.path == "/x/player/v2")
        #expect(catalogRequest.headers["Cookie"] == "FIXTURE_AUTHORIZED")
        #expect(await authorizer.capturedPaths() == ["/x/player/v2"])

        let bodyRequest = try #require(
            await bodyTransport.capturedRequests().first
        )
        #expect(bodyRequest.url.host == "aisubtitle.hdslb.com")
        #expect(bodyRequest.headers["Cookie"] == nil)
        #expect(bodyRequest.headers["Referer"]?.contains(identity.bvid) == true)
    }

    @Test
    func catalogSkipsEmptyURLPlaceholderBeforeUsableTrack() async throws {
        let repository = BiliSubtitleRepository(
            client: BiliAPIClient(
                transport: SubtitleRecordingTransport(
                    responses: [try catalogResponse(prependingEmptyURLTrack: true)]
                ),
                requestAuthorizer: SubtitleRecordingAuthorizer()
            ),
            bodyTransport: SubtitleRecordingTransport(responses: [])
        )

        let tracks = try await repository.tracks(for: identity)

        #expect(tracks.count == 1)
        #expect(tracks.first?.id == "900001")
    }

    @Test
    func catalogRequiresAuthorizationBeforeTransport() async {
        let catalogTransport = SubtitleRecordingTransport(responses: [])
        let client = BiliAPIClient(transport: catalogTransport)
        let repository = BiliSubtitleRepository(
            client: client,
            bodyTransport: SubtitleRecordingTransport(responses: [])
        )

        await #expect(throws: SubtitleApplicationError.authenticationRequired) {
            try await repository.tracks(for: identity)
        }
        #expect(await catalogTransport.capturedRequests().isEmpty)
    }

    @Test
    func catalogRejectsUntrustedSubtitleOriginBeforeBodyTransport() async throws {
        let catalogTransport = SubtitleRecordingTransport(
            responses: [try fixtureResponse("subtitle-catalog")]
        )
        let bodyTransport = SubtitleRecordingTransport(responses: [])
        let repository = BiliSubtitleRepository(
            client: BiliAPIClient(
                transport: catalogTransport,
                requestAuthorizer: SubtitleRecordingAuthorizer()
            ),
            bodyTransport: bodyTransport
        )

        await #expect(throws: SubtitleApplicationError.invalidResponse) {
            try await repository.tracks(for: identity)
        }
        #expect(await bodyTransport.capturedRequests().isEmpty)
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
            ),
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

    @Test
    func bodyRejectsNonmonotonicAndOutOfBoundsCues() async throws {
        let fixture = try fixtureResponse("subtitle-body")
        let body = String(decoding: fixture.body, as: UTF8.self)
        let invalidBodies = [
            body.replacingOccurrences(of: #""from": 4.0"#, with: #""from": 0.5"#),
            body.replacingOccurrences(of: #""to": 3.5"#, with: #""to": 90000"#),
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
        let bodyTransport = SubtitleRecordingTransport(
            responses: [try fixtureResponse("subtitle-body")]
        )
        let repository = BiliSubtitleRepository(
            client: BiliAPIClient(
                transport: SubtitleRecordingTransport(
                    responses: [try catalogResponse()]
                ),
                requestAuthorizer: SubtitleRecordingAuthorizer()
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
        #expect(await bodyTransport.capturedRequests().isEmpty)
    }

    @Test
    func resetInvalidatesCatalogThatFinishesAfterViewClosed() async throws {
        let catalogTransport = SubtitleDelayedTransport(
            response: try catalogResponse(),
            delay: .milliseconds(80)
        )
        let bodyTransport = SubtitleRecordingTransport(
            responses: [try fixtureResponse("subtitle-body")]
        )
        let repository = BiliSubtitleRepository(
            client: BiliAPIClient(
                transport: catalogTransport,
                requestAuthorizer: SubtitleRecordingAuthorizer()
            ),
            bodyTransport: bodyTransport
        )
        let request = Task {
            try await repository.tracks(for: identity)
        }
        try await Task.sleep(for: .milliseconds(10))

        await repository.reset(for: identity)

        await #expect(throws: CancellationError.self) {
            try await request.value
        }
        await #expect(throws: SubtitleApplicationError.invalidRequest) {
            try await repository.cues(
                for: "900001",
                identity: identity
            )
        }
        #expect(await bodyTransport.capturedRequests().isEmpty)
    }

    @Test(arguments: [
        "http://aisubtitle.hdslb.com/bfs/subtitle/a.json",
        "https://user@aisubtitle.hdslb.com/bfs/subtitle/a.json",
        "https://aisubtitle.hdslb.com:8443/bfs/subtitle/a.json",
        "https://127.0.0.1/bfs/subtitle/a.json",
        "https://aisubtitle.hdslb.com.attacker.invalid/bfs/subtitle/a.json",
        "https://aisubtitle.hdslb.com/other/a.json",
        "https://aisubtitle.hdslb.com/bfs/subtitle/a.json#fragment",
    ])
    func subtitlePolicyRejectsUnsafeOrigins(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(!SubtitleURLPolicy().allows(url))
    }

    private func repository(
        bodyResponse: HTTPResponse
    ) async throws -> (BiliSubtitleRepository, SubtitleTrack) {
        let repository = BiliSubtitleRepository(
            client: BiliAPIClient(
                transport: SubtitleRecordingTransport(
                    responses: [try catalogResponse()]
                ),
                requestAuthorizer: SubtitleRecordingAuthorizer()
            ),
            bodyTransport: SubtitleRecordingTransport(
                responses: [bodyResponse]
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
            guard var envelope = try JSONSerialization.jsonObject(with: body)
                    as? [String: Any],
                  var data = envelope["data"] as? [String: Any],
                  var subtitle = data["subtitle"] as? [String: Any],
                  var tracks = subtitle["subtitles"] as? [[String: Any]],
                  var placeholder = tracks.first
            else {
                throw SubtitleTestTransportError.missingResponse
            }
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

    private func fixtureResponse(
        _ name: String,
        extension fileExtension: String = "json",
        contentType: String = "application/json; charset=utf-8"
    ) throws -> HTTPResponse {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: "Fixtures"
            )
        )
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": contentType],
            body: try Data(contentsOf: url)
        )
    }
}

private actor SubtitleRecordingTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private var requests: [HTTPRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw SubtitleTestTransportError.missingResponse
        }
        return responses.removeFirst()
    }

    func capturedRequests() -> [HTTPRequest] {
        requests
    }
}

private actor SubtitleRecordingAuthorizer: HTTPRequestAuthorizing {
    private var paths: [String] = []

    func authorize(_ request: HTTPRequest) -> HTTPRequest {
        paths.append(request.url.path)
        var headers = request.headers
        headers["Cookie"] = "FIXTURE_AUTHORIZED"
        return HTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: request.body
        )
    }

    func capturedPaths() -> [String] {
        paths
    }
}

private actor SubtitleDelayedTransport: HTTPTransport {
    let response: HTTPResponse
    let delay: Duration

    init(response: HTTPResponse, delay: Duration) {
        self.response = response
        self.delay = delay
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try? await Task.sleep(for: delay)
        return response
    }
}

private enum SubtitleTestTransportError: Error {
    case missingResponse
}
