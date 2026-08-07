import BiliApplication
import BiliModels
import Testing

@Suite
struct SubtitleUseCaseTests {
    @Test
    func displayPolicyMatchesVerifiedCatalogLabels() {
        let tracks = [
            SubtitleTrack(
                id: "standard-zh",
                languageCode: "zh",
                displayName: " 中文 ",
                kind: .standard
            ),
            SubtitleTrack(
                id: "automatic-zh",
                languageCode: "ai-zh",
                displayName: "中文",
                kind: .automatic
            ),
            SubtitleTrack(
                id: "automatic-en",
                languageCode: "ai-en",
                displayName: "English",
                kind: .automatic
            ),
            SubtitleTrack(
                id: "automatic-ja",
                languageCode: "ai-ja",
                displayName: "日本語",
                kind: .automatic
            ),
        ]

        let options = SubtitleDisplayPolicy.options(for: tracks)

        #expect(options.map(\.trackID) == tracks.map(\.id))
        #expect(
            options.map(\.label) == [
                "中文", "中文（AI）", "English", "日本語",
            ]
        )
    }

    @Test
    func displayPolicyDoesNotInventOrdinalLabelsForUnknownTracks() {
        let options = SubtitleDisplayPolicy.options(for: [
            SubtitleTrack(
                id: "unknown-1",
                languageCode: "und-1",
                displayName: "Unknown",
                kind: .unknown
            ),
            SubtitleTrack(
                id: "unknown-2",
                languageCode: "und-2",
                displayName: "Unknown",
                kind: .unknown
            ),
        ])

        #expect(options.map(\.label) == ["Unknown", "Unknown"])
    }

    @Test
    func displayPolicyKeepsLabelsStableAcrossCatalogCombinations() {
        let automaticChinese = SubtitleTrack(
            id: "automatic-zh",
            languageCode: "ai-zh",
            displayName: "中文",
            kind: .automatic
        )
        let automaticEnglish = SubtitleTrack(
            id: "automatic-en",
            languageCode: "ai-en",
            displayName: "English",
            kind: .automatic
        )

        #expect(
            SubtitleDisplayPolicy.options(for: [automaticChinese])
                .map(\.label) == ["中文（AI）"]
        )
        #expect(
            SubtitleDisplayPolicy.options(for: [
                SubtitleTrack(
                    id: "standard-zh",
                    languageCode: "zh",
                    displayName: "中文",
                    kind: .standard
                ),
                automaticChinese,
            ]).map(\.label) == ["中文", "中文（AI）"]
        )
        #expect(
            SubtitleDisplayPolicy.options(for: [
                SubtitleTrack(
                    id: "standard-en",
                    languageCode: "en",
                    displayName: "English",
                    kind: .standard
                ),
                automaticEnglish,
            ]).map(\.label) == ["English", "English"]
        )
        #expect(
            SubtitleDisplayPolicy.options(for: [
                SubtitleTrack(
                    id: "source-labeled-ai-zh",
                    languageCode: "ai-zh",
                    displayName: "中文（AI）",
                    kind: .automatic
                )
            ]).map(\.label) == ["中文（AI）"]
        )
    }

    @Test(
        "Invalid track identities fail before the repository",
        arguments: [
            PlaybackItemIdentity(bvid: "", cid: 1),
            PlaybackItemIdentity(bvid: "BV1SubtitleFixture", cid: 0),
            PlaybackItemIdentity(bvid: "BV1SubtitleFixture", cid: -1),
        ]
    )
    func invalidTrackIdentityFailsBeforeRepository(
        identity: PlaybackItemIdentity
    ) async {
        let repository = ApplicationSubtitleRepository()
        let useCase = SubtitleUseCase(repository: repository)

        await #expect(throws: SubtitleApplicationError.invalidRequest) {
            try await useCase.tracks(for: identity)
        }
        #expect(await repository.requests().isEmpty)
    }

    @Test(
        "Invalid cue inputs fail before the repository",
        arguments: [
            ("", PlaybackItemIdentity(bvid: "BV1SubtitleFixture", cid: 1)),
            ("track", PlaybackItemIdentity(bvid: "", cid: 1)),
            ("track", PlaybackItemIdentity(bvid: "BV1SubtitleFixture", cid: 0)),
        ]
    )
    func invalidCueInputFailsBeforeRepository(
        trackID: String,
        identity: PlaybackItemIdentity
    ) async {
        let repository = ApplicationSubtitleRepository()
        let useCase = SubtitleUseCase(repository: repository)

        await #expect(throws: SubtitleApplicationError.invalidRequest) {
            try await useCase.cues(for: trackID, identity: identity)
        }
        #expect(await repository.requests().isEmpty)
    }
}

private actor ApplicationSubtitleRepository: SubtitleRepository {
    enum Request: Sendable, Equatable {
        case tracks(PlaybackItemIdentity)
        case cues(trackID: String, identity: PlaybackItemIdentity)
        case reset(PlaybackItemIdentity)
    }

    private var observedRequests: [Request] = []

    func tracks(
        for identity: PlaybackItemIdentity
    ) -> [SubtitleTrack] {
        observedRequests.append(.tracks(identity))
        return []
    }

    func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) -> [SubtitleCue] {
        observedRequests.append(.cues(trackID: trackID, identity: identity))
        return []
    }

    func reset(for identity: PlaybackItemIdentity) {
        observedRequests.append(.reset(identity))
    }

    func requests() -> [Request] {
        observedRequests
    }
}
