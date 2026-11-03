import BiliApplication
import BiliModels
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SubtitleUseCaseTests {
    @Test(arguments: [
        (kind: SubtitleTrackKind.standard, name: " 中文 ", expected: "中文"),
        (kind: .standard, name: "English", expected: "English"),
        (kind: .automaticTranscription, name: "中文", expected: "中文（AI）"),
        (kind: .automaticTranslation, name: "English", expected: "English（AI）"),
        (kind: .automaticTranscription, name: "한국어", expected: "한국어（AI）"),
        (kind: .automaticTranscription, name: "中文（AI）", expected: "中文（AI）"),
        (kind: .automaticTranslation, name: "日本語（AI）", expected: "日本語（AI）"),
        (kind: .unknown, name: "Français", expected: "Français")
    ])
    func displayPolicyMarksOnlyAutomaticTracks(
        kind: SubtitleTrackKind,
        name: String,
        expected: String
    ) {
        let track = SubtitleTrack(id: "track", languageCode: "ai-xx", displayName: name, kind: kind)

        #expect(SubtitleDisplayPolicy.options(for: [track]).map(\.label) == [expected])
    }

    @Test
    func displayPolicyKeepsCatalogOrderWithoutInventingOrdinals() {
        let tracks = ["unknown-1", "unknown-2", "automatic-zh"].map {
            SubtitleTrack(
                id: $0,
                languageCode: "und",
                displayName: "Unknown",
                kind: $0.hasPrefix("automatic") ? .automaticTranscription : .unknown
            )
        }

        let options = SubtitleDisplayPolicy.options(for: tracks)

        #expect(options.map(\.trackID) == tracks.map(\.id))
        #expect(options.map(\.label) == ["Unknown", "Unknown", "Unknown（AI）"])
    }

    @Test(
        "Invalid track identities fail before the repository",
        arguments: [
            PlaybackItemIdentity(bvid: "", cid: 1),
            PlaybackItemIdentity(bvid: "BV1SubtitleFixture", cid: 0),
            PlaybackItemIdentity(bvid: "BV1SubtitleFixture", cid: -1)
        ]
    )
    func invalidTrackIdentityFailsBeforeRepository(
        identity: PlaybackItemIdentity
    ) async {
        let repository = ApplicationSubtitleRepository()
        let useCase = SubtitleUseCase(
            repository: repository,
            reportAuthenticationInvalidation: {}
        )

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
            ("track", PlaybackItemIdentity(bvid: "BV1SubtitleFixture", cid: 0))
        ]
    )
    func invalidCueInputFailsBeforeRepository(
        trackID: String,
        identity: PlaybackItemIdentity
    ) async {
        let repository = ApplicationSubtitleRepository()
        let useCase = SubtitleUseCase(
            repository: repository,
            reportAuthenticationInvalidation: {}
        )

        await #expect(throws: SubtitleApplicationError.invalidRequest) {
            try await useCase.cues(for: trackID, identity: identity)
        }
        #expect(await repository.requests().isEmpty)
    }

    /// 字幕目录的凭据失效要在用例里报告：播放侧把目录失败当作没有字幕，不会再往上传。
    @Test(arguments: [
        (SubtitleApplicationError.authenticationInvalid, 1),
        (.authenticationRequired, 0),
        (.authenticationUnavailable, 0),
        (.requestRestricted, 0)
    ])
    func onlyInvalidCredentialsAreReportedFromTheCatalog(
        failure: SubtitleApplicationError,
        expectedReports: Int
    ) async {
        let reports = ReportCounter()
        let useCase = SubtitleUseCase(
            repository: ApplicationSubtitleRepository(tracksFailure: failure),
            reportAuthenticationInvalidation: { reports.increment() }
        )

        await #expect(throws: failure) {
            try await useCase.tracks(for: PlaybackItemIdentity(bvid: "BV1SubtitleFixture", cid: 1))
        }
        #expect(reports.count == expectedReports)
    }
}

private final class ReportCounter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

private actor ApplicationSubtitleRepository: SubtitleRepository {
    private let tracksFailure: SubtitleApplicationError?

    init(tracksFailure: SubtitleApplicationError? = nil) {
        self.tracksFailure = tracksFailure
    }

    enum Request: Sendable, Equatable {
        case tracks(PlaybackItemIdentity)
        case cues(trackID: String, identity: PlaybackItemIdentity)
        case reset(PlaybackItemIdentity)
    }

    private var observedRequests: [Request] = []

    func tracks(
        for identity: PlaybackItemIdentity
    ) throws -> [SubtitleTrack] {
        observedRequests.append(.tracks(identity))
        if let tracksFailure { throw tracksFailure }
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
