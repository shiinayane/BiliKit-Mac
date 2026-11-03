import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定 playurl 音轨契约：AI 配音只在带凭据且响应确认制作类型时作为语义音轨加入，
/// 配音失败保留原声并停止后续配音请求，响度元数据按音轨各自绑定且必须是完整有界的一组。
struct BiliAPIClientPlaybackAudioTests {
    @Test
    func playURLBindsLoudnessMetadataToEachSemanticTrackResponse() async throws {
        let originalVolume = loudnessVolume(measuredI: -20, measuredTP: -4)
        let aiVolume = loudnessVolume(measuredI: -11, measuredTP: -0.5)
        let transport = StubTransport(
            responses: [
                try semanticAudioResponse(
                    audioPath: "original-audio.m4s",
                    languageCatalog: machineGeneratedEnglishAndJapaneseCatalog,
                    volume: originalVolume
                ),
                try semanticAudioResponse(
                    audioPath: "ai-en-audio.m4s",
                    currentLanguage: "en",
                    currentProductionType: 2,
                    volume: aiVolume
                ),
                try semanticAudioResponse(
                    audioPath: "ai-ja-audio.m4s",
                    currentLanguage: "ja",
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
        #expect(manifest.audioTracks.count == 3)
        let original = manifest.audioTracks[0]
        let englishAI = manifest.audioTracks[1]
        let japaneseAI = manifest.audioTracks[2]
        #expect(original.loudnessMetadata?.measuredIntegratedLUFS == -20)
        #expect(englishAI.loudnessMetadata?.measuredIntegratedLUFS == -11)
        #expect(japaneseAI.loudnessMetadata == nil)
        #expect(original.loudnessMetadata != englishAI.loudnessMetadata)
        let requests = playURLRequests(transport)
        #expect(requests.count == 3)
        #expect(
            requests.allSatisfy { request in
                URLComponents(
                    url: request.url,
                    resolvingAgainstBaseURL: false
                )?.queryItems?.contains(
                    URLQueryItem(name: "voice_balance", value: "1")
                ) == true
            }
        )
    }

    @Test(
        arguments: [
            (
                #"{"measured_i":-20,"measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14,"target_tp":-1}"#,
                -20.0
            ),
            (
                #"{"measured_i":-20,"measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14}"#,
                nil
            ),
            (
                #"{"measured_i":null,"measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14,"target_tp":-1}"#,
                nil
            ),
            (
                #"{"measured_i":"bad","measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14,"target_tp":-1}"#,
                nil
            ),
            (
                #"{"measured_i":-200,"measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14,"target_tp":-1}"#,
                nil
            ),
            (
                #"{"measured_i":1e400,"measured_lra":3,"measured_tp":-4,"measured_threshold":-30,"target_i":-14,"target_tp":-1}"#,
                nil
            ),
            // B 站未测量响度的视频：四个测量值都是 0.001 占位。
            (
                #"{"measured_i":0.001,"measured_lra":0.001,"measured_tp":0.001,"measured_threshold":0.001,"target_offset":0.001,"target_i":-14,"target_tp":-1}"#,
                nil
            )
        ] as [(String, Double?)]
    )
    func loudnessPayloadRequiresACompleteFiniteBoundedGroup(
        _ source: String,
        expectedIntegratedLUFS: Double?
    ) {
        let payload = try? JSONDecoder().decode(
            PlaybackVolumePayload.self,
            from: Data(source.utf8)
        )

        #expect(payload?.model?.measuredIntegratedLUFS == expectedIntegratedLUFS)
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

    private func loudnessVolume(
        measuredI: Double,
        measuredTP: Double
    ) -> [String: Any] {
        [
            "measured_i": measuredI,
            "measured_lra": 3,
            "measured_tp": measuredTP,
            "measured_threshold": measuredI - 10,
            "target_i": -14,
            "target_tp": -1,
            "target_offset": 99,
            "multi_scene_args": "ignored"
        ]
    }
}
