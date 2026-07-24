import BiliApplication
import BiliModels
import Foundation
import Testing
@testable import BiliBrowseFeature

@Suite
@MainActor
struct SubtitleViewModelTests {
    private let identity = PlaybackItemIdentity(
        bvid: "BV1SubtitleFixture",
        cid: 900_001
    )
    private let oldIdentity = PlaybackItemIdentity(
        bvid: "BV1OldSubtitle",
        cid: 900_002
    )

    @Test
    func timelineDrivesCueAcrossPauseRateAndBackwardSeek() async throws {
        let repository = SubtitleRepositoryStub()
        let timeline = SubtitleTimelineStub()
        let model = makeModel(repository: repository, timeline: timeline)

        model.selectVideo(identity)
        await model.waitForCurrentTask()

        #expect(model.state == .ready(identity))
        #expect(model.tracks.count == 2)
        #expect(model.selectedTrackID == "track-standard")

        timeline.publish(snapshot(position: 2, state: .playing))
        try await waitForCue("第一条手写字幕", in: model)
        #expect(model.currentCueText == "第一条手写字幕")

        timeline.publish(snapshot(position: 2, rate: 0, state: .paused))
        try await waitForCue("第一条手写字幕", in: model)
        #expect(model.currentCueText == "第一条手写字幕")

        timeline.publish(snapshot(position: 5, rate: 2, state: .playing))
        try await waitForCue("第二条手写字幕", in: model)
        #expect(model.currentCueText == "第二条手写字幕")

        timeline.publish(
            snapshot(
                position: 2,
                state: .paused,
                discontinuityGeneration: 2
            )
        )
        try await waitForCue("第一条手写字幕", in: model)
        #expect(model.currentCueText == "第一条手写字幕")
    }

    @Test
    func turningOffAndSwitchingTrackReplacesPresentedCue() async throws {
        let repository = SubtitleRepositoryStub()
        let timeline = SubtitleTimelineStub()
        let model = makeModel(repository: repository, timeline: timeline)
        model.selectVideo(identity)
        await model.waitForCurrentTask()
        timeline.publish(snapshot(position: 2, state: .playing))
        try await waitForCue("第一条手写字幕", in: model)
        #expect(model.currentCueText == "第一条手写字幕")

        model.selectTrack(nil)
        #expect(model.currentCueText == nil)
        #expect(model.state == .ready(identity))

        model.selectTrack("track-automatic")
        await model.waitForCurrentTask()
        #expect(model.selectedTrackID == "track-automatic")
        #expect(model.currentCueText == "自动生成字幕")
    }

    @Test
    func newerTrackAndIdentityRejectOlderResultsAndTimeline() async throws {
        let repository = SubtitleRepositoryStub(
            cueDelays: ["track-standard": .milliseconds(80)]
        )
        let timeline = SubtitleTimelineStub()
        let model = makeModel(repository: repository, timeline: timeline)

        model.selectVideo(identity)
        try await waitUntil {
            model.state == .loadingTrack(identity)
                && model.selectedTrackID == "track-standard"
                && model.tracks.contains { $0.id == "track-automatic" }
        }
        model.selectTrack("track-automatic")
        await model.waitForCurrentTask()
        timeline.publish(snapshot(position: 2, state: .playing))
        try await waitForCue("自动生成字幕", in: model)
        #expect(model.currentCueText == "自动生成字幕")

        try await Task.sleep(for: .milliseconds(100))
        #expect(model.selectedTrackID == "track-automatic")
        #expect(model.currentCueText == "自动生成字幕")

        model.selectVideo(oldIdentity)
        await model.waitForCurrentTask()
        timeline.publish(
            snapshot(position: 2, identity: oldIdentity, state: .playing)
        )
        try await waitForCue("第一条手写字幕", in: model)
        #expect(model.currentCueText == "第一条手写字幕")

        timeline.publish(snapshot(position: 2, identity: identity, state: .playing))
        try await waitForCue(nil, in: model)
        #expect(model.currentCueText == nil)

        timeline.publish(
            snapshot(position: 2, identity: oldIdentity, state: .playing)
        )
        try await waitForCue("第一条手写字幕", in: model)
        #expect(model.currentCueText == "第一条手写字幕")
    }

    @Test
    func emptyAuthenticationFailureAndResetHaveSafeStates() async {
        let timeline = SubtitleTimelineStub()
        let emptyModel = makeModel(
            repository: SubtitleRepositoryStub(tracks: .success([])),
            timeline: timeline
        )
        emptyModel.selectVideo(identity)
        await emptyModel.waitForCurrentTask()
        #expect(emptyModel.state == .unavailable(identity))

        let authModel = makeModel(
            repository: SubtitleRepositoryStub(
                tracks: .failure(.authenticationRequired)
            ),
            timeline: SubtitleTimelineStub()
        )
        authModel.selectVideo(identity)
        await authModel.waitForCurrentTask()
        #expect(
            authModel.state == .failed(
                identity,
                .authenticationRequired
            )
        )

        authModel.reset()
        #expect(authModel.state == .idle)
        #expect(authModel.tracks.isEmpty)
        #expect(authModel.selectedTrackID == nil)
        #expect(authModel.currentCueText == nil)
    }

    private func makeModel(
        repository: SubtitleRepositoryStub,
        timeline: SubtitleTimelineStub
    ) -> SubtitleViewModel {
        SubtitleViewModel(
            useCase: SubtitleUseCase(repository: repository),
            timeline: timeline
        )
    }

    private func waitForCue(
        _ expected: String?,
        in model: SubtitleViewModel
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while model.currentCueText != expected, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.currentCueText == expected)
    }

    private func waitUntil(
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition())
    }

    private func snapshot(
        position: Double,
        identity: PlaybackItemIdentity? = nil,
        rate: Double = 1,
        state: PlaybackTimelineState,
        discontinuityGeneration: UInt64 = 1
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity ?? self.identity,
            positionSeconds: position,
            durationSeconds: 120,
            rate: rate,
            state: state,
            discontinuityGeneration: discontinuityGeneration
        )
    }
}

private actor SubtitleRepositoryStub: SubtitleRepository {
    private let tracksResult: Result<[SubtitleTrack], SubtitleApplicationError>
    private let cueDelays: [String: Duration]

    init(
        tracks: Result<[SubtitleTrack], SubtitleApplicationError> = .success([
            SubtitleTrack(
                id: "track-standard",
                languageCode: "zh-CN",
                displayName: "中文（简体）",
                kind: .standard
            ),
            SubtitleTrack(
                id: "track-automatic",
                languageCode: "zh-CN",
                displayName: "中文（自动）",
                kind: .automatic
            ),
        ]),
        cueDelays: [String: Duration] = [:]
    ) {
        tracksResult = tracks
        self.cueDelays = cueDelays
    }

    func tracks(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleTrack] {
        try tracksResult.get()
    }

    func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) async throws -> [SubtitleCue] {
        if let delay = cueDelays[trackID] {
            try await Task.sleep(for: delay)
        }
        if trackID == "track-automatic" {
            return [
                SubtitleCue(
                    startSeconds: 1,
                    endSeconds: 3.5,
                    text: "自动生成字幕"
                ),
            ]
        }
        return [
            SubtitleCue(
                startSeconds: 1.25,
                endSeconds: 3.5,
                text: "第一条手写字幕"
            ),
            SubtitleCue(
                startSeconds: 4,
                endSeconds: 6.25,
                text: "第二条手写字幕"
            ),
        ]
    }

    func reset(for identity: PlaybackItemIdentity) async {}
}

@MainActor
private final class SubtitleTimelineStub: PlaybackTimelineProviding {
    private(set) var currentTimelineSnapshot = PlaybackTimelineSnapshot.idle
    private var continuations: [
        UUID: AsyncStream<PlaybackTimelineSnapshot>.Continuation
    ] = [:]

    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        let id = UUID()
        let stream = AsyncStream<PlaybackTimelineSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[id] = stream.continuation
        stream.continuation.yield(currentTimelineSnapshot)
        stream.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.continuations.removeValue(forKey: id)
            }
        }
        return stream.stream
    }

    func publish(_ snapshot: PlaybackTimelineSnapshot) {
        currentTimelineSnapshot = snapshot
        continuations.values.forEach { $0.yield(snapshot) }
    }
}
