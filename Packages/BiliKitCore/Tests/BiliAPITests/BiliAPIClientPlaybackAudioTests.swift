import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定 playurl 音轨契约：AI 配音只在带凭据且响应确认制作类型时作为语义音轨加入，
/// 配音失败保留原声并停止后续配音请求；没有音轨的稿件映射为只有视频的清单；`dash.dolby`、`dash.flac`
/// 映射为原声的杜比与无损版本（`dash.dolby.type` 为 2 时标为全景声），形状不对时只是没有这个版本。
struct BiliAPIClientPlaybackAudioTests {
    /// 录屏之类没有声音的稿件 `dash.audio` 是 `null`：照常映射视频、没有音轨，即使目录里列着配音也不去请求。
    @Test
    func playURLWithoutAudioMapsVideoOnlyManifest() async throws {
        let transport = StubTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: nil,
                    languageCatalog: machineGeneratedEnglishCatalog
                )
            ],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        let manifest = try #require(playback.dashManifest)
        #expect(manifest.videoRepresentations.map(\.id) == [32])
        #expect(manifest.audioTracks.isEmpty)
        #expect(playURLRequests(transport).count == 1)
    }

    enum AdditionalAudioShape: CaseIterable, Sendable {
        case present
        case nullAudio
        case malformed

        var dash: [String: Any] {
            switch self {
            case .present:
                [
                    "dolby": [
                        "type": 2,
                        "audio": [
                            audioRepresentationPayload(
                                id: 30_250,
                                codecs: "ec-3",
                                path: "dolby.m4s"
                            )
                        ]
                    ],
                    "flac": [
                        "display": true,
                        "audio": audioRepresentationPayload(
                            id: 30_251,
                            codecs: "fLaC",
                            path: "flac.m4s"
                        )
                    ]
                ]
            case .nullAudio:
                [
                    "dolby": ["type": 0, "audio": NSNull()],
                    "flac": ["display": false, "audio": NSNull()]
                ]
            case .malformed:
                [
                    "dolby": [
                        "audio": [
                            audioRepresentationPayload(
                                id: 30_250,
                                codecs: "mp4a.40.2",
                                path: "aac.m4s"
                            )
                        ]
                    ],
                    "flac": "unexpected"
                ]
            }
        }
    }

    @Test(arguments: AdditionalAudioShape.allCases)
    func dolbyAndFLACMapToOriginalVersionsOnlyWhenWellFormed(
        _ shape: AdditionalAudioShape
    ) async throws {
        let transport = StubTransport(
            responses: [
                try semanticAudioResponse(audioPath: "audio.m4s", additionalDash: shape.dash)
            ],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        let playback = try await client.playback(for: "BV1FixtureA1", cid: 900_001)

        let original = try #require(playback.dashManifest?.audioTracks.first)
        #expect(original.representations.map(\.id) == [30_280])
        #expect(original.dolbyRepresentation?.id == (shape == .present ? 30_250 : nil))
        // `dash.dolby.type == 2` 是杜比全景声，bridge 据此给这一组补 JOC 标记。
        #expect(original.dolbyIsAtmos == (shape == .present))
        #expect(original.losslessRepresentation?.id == (shape == .present ? 30_251 : nil))
    }

    @Test
    func authenticatedPlayURLMapsVerifiedAIAudioAsSemanticTrack() async throws {
        let transport = StubTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: machineGeneratedEnglishCatalog
                ),
                try semanticAudioResponse(
                    audioPath: "ai-en-audio.m4s",
                    currentLanguage: "en",
                    currentProductionType: 2
                )
            ],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        let manifest = try #require(playback.dashManifest)
        #expect(manifest.audioTracks.count == 2)
        let original = manifest.audioTracks[0]
        let ai = manifest.audioTracks[1]
        #expect(original.role == .original)
        #expect(original.isDefault)
        #expect(ai.id == "machine-generated:en")
        #expect(ai.displayName == "English（AI）")
        #expect(ai.languageTag == "en")
        #expect(ai.role == .machineGenerated)
        #expect(!ai.isDefault)
        #expect(!ai.isAutoselect)
        #expect(ai.representations.map(\.id) == [30_280])
        let requests = playURLRequests(transport)
        #expect(requests.count == 2)
        #expect(
            URLComponents(
                url: requests[1].url,
                resolvingAgainstBaseURL: false
            )?.queryItems?.contains(
                URLQueryItem(name: "cur_language", value: "en")
            ) == true
        )
        #expect(playback.mediaHeaders["Cookie"] == nil)
    }

    @Test(arguments: [Int?.none, Int?.some(1)])
    func authenticatedPlayURLOmitsAIAudioWithoutMatchingResponseProductionType(
        currentProductionType: Int?
    ) async throws {
        let transport = StubTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: machineGeneratedEnglishCatalog
                ),
                try semanticAudioResponse(
                    audioPath: "ai-en-audio.m4s",
                    currentLanguage: "en",
                    currentProductionType: currentProductionType
                )
            ],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(playback.dashManifest?.audioTracks.map(\.role) == [.original])
        #expect(playURLRequests(transport).count == 2)
    }

    @Test
    func anonymousFallbackProvenanceCannotAuthorizeAdvertisedAIAudio()
        async throws
    {
        let authorizer = StubAuthorizer(.fail(.missingCredential), .authorize)
        let transport = StubTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: machineGeneratedEnglishCatalog
                )
            ],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(playback.dashManifest?.audioTracks.map(\.role) == [.original])
        #expect(await authorizer.authorizationCount == 1)
        let request = try #require(playURLRequests(transport).first)
        #expect(playURLRequests(transport).count == 1)
        #expect(request.headers["Cookie"] == nil)
        let queryItems = URLComponents(
            url: request.url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(queryItems?.contains(URLQueryItem(name: "gaia_source", value: "pre-load")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "isGaiaAvoided", value: "true")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "try_look", value: "1")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "dm_img_list", value: "[]")) == true)
        #expect(queryItems?.first(where: { $0.name == "w_rid" })?.value?.count == 32)
    }

    /// 配音是附加内容：某个语言请求失败时保留原声继续播放，并停止后续语言的配音请求。
    @Test(
        arguments: [
            HTTPResponse(statusCode: 403, body: Data()),
            HTTPResponse(statusCode: 412, body: Data()),
            jsonResponse(#"{"code":-404,"message":"fixture"}"#),
            HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/html"],
                body: Data("fixture".utf8)
            ),
            nil
        ] as [HTTPResponse?]
    )
    func aiAudioFailureKeepsOriginalAndStopsFurtherDubRequests(
        aiResponse: HTTPResponse?
    ) async throws {
        let base = try semanticAudioResponse(
            audioPath: "original-audio.m4s",
            languageCatalog: machineGeneratedEnglishAndJapaneseCatalog
        )
        let transport = StubTransport(
            responses: [base] + [aiResponse].compactMap { $0 },
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        let playback = try await client.playback(for: "BV1FixtureA1", cid: 900_001)

        let manifest = try #require(playback.dashManifest)
        #expect(manifest.audioTracks.map(\.role) == [.original])
        #expect(playURLRequests(transport).count == 2)
    }

    /// 停止之前已经拿到的配音音轨保留在结果里。
    @Test
    func aiAudioFailureKeepsDubsFetchedBeforeIt() async throws {
        let transport = StubTransport(
            responses: [
                try fixtureResponse("nav"),
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: machineGeneratedEnglishAndJapaneseCatalog
                ),
                try semanticAudioResponse(
                    audioPath: "ai-en-audio.m4s",
                    currentLanguage: "en",
                    currentProductionType: 2
                ),
                HTTPResponse(statusCode: 412, body: Data())
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        let playback = try await client.playback(for: "BV1FixtureA1", cid: 900_001)

        let manifest = try #require(playback.dashManifest)
        #expect(manifest.audioTracks.map(\.id).last == "machine-generated:en")
        #expect(manifest.audioTracks.map(\.role) == [.original, .machineGenerated])
        #expect(playURLRequests(transport).count == 3)
    }

    /// 凭据失效不属于配音自身的失败：仍让播放失败并交给账户复核。
    @Test
    func aiAudioAuthenticationInvalidationStillFailsPlayback() async throws {
        let base = try semanticAudioResponse(
            audioPath: "original-audio.m4s",
            languageCatalog: machineGeneratedEnglishCatalog
        )
        let transport = StubTransport(
            responses: [
                try fixtureResponse("nav"),
                base,
                jsonResponse(#"{"code":-101,"message":"fixture"}"#)
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        await #expect(throws: BiliAPIError.authenticationInvalid) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
    }

    @Test
    func unsafeAIAudioTitleIsOmittedBeforeSecondRequest() async throws {
        let transport = StubTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: [
                        "support": true,
                        "items": [
                            [
                                "lang": "en",
                                "title": "English \"AI\"",
                                "production_type": 2
                            ]
                        ]
                    ]
                )
            ],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(playback.dashManifest?.audioTracks.count == 1)
        #expect(playURLRequests(transport).count == 1)
    }

    private var machineGeneratedEnglishAndJapaneseCatalog: [String: Any] {
        [
            "support": true,
            "items": [
                ["lang": "en", "title": "English（AI）", "production_type": 2],
                ["lang": "ja", "title": "日本語（AI）", "production_type": 2]
            ]
        ]
    }
}
