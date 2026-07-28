import BiliApplication
import BiliModels
import Testing

@Suite
struct SubtitleUseCaseTests {
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
