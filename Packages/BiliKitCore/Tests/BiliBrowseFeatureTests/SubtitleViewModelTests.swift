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
    func catalogExposesVerifiedUserLabelsWithoutSelectingATrack() async {
        let repository = SubtitleRepositoryStub(
            tracks: .success([
                SubtitleTrack(
                    id: "standard-zh",
                    languageCode: "zh",
                    displayName: "中文",
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
            ])
        )
        let model = makeModel(
            repository: repository,
            timeline: SubtitleTimelineStub()
        )

        model.selectVideo(identity)
        await model.waitForCurrentTask()

        #expect(
            model.displayOptions.map(\.label) == [
                "中文", "中文（AI）", "English",
            ]
        )
        #expect(model.selectedTrackID == nil)
        #expect(await repository.cueRequestCount() == 0)
    }

    @Test
    func catalogDefaultsToOffAndSelectedTrackFollowsTimeline() async throws {
        let repository = SubtitleRepositoryStub()
        let timeline = SubtitleTimelineStub()
        let model = makeModel(repository: repository, timeline: timeline)

        model.selectVideo(identity)
        await model.waitForCurrentTask()

        #expect(model.state == .ready(identity))
        #expect(model.tracks.count == 2)
        #expect(model.selectedTrackID == nil)
        #expect(await repository.cueRequestCount() == 0)

        model.selectTrack("track-standard")
        await model.waitForCurrentTask()
        #expect(model.selectedTrackID == "track-standard")
        #expect(await repository.cueRequestCount() == 1)

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
    func retryAfterTrackFailureRetriesTheSelectedTrack() async {
        let repository = SubtitleRepositoryStub(cueFailuresRemaining: 1)
        let model = makeModel(
            repository: repository,
            timeline: SubtitleTimelineStub()
        )

        model.selectVideo(identity)
        await model.waitForCurrentTask()
        model.selectTrack("track-standard")
        await model.waitForCurrentTask()

        #expect(model.state == .failed(identity, .unavailable))
        #expect(model.selectedTrackID == "track-standard")
        #expect(await repository.cueRequestCount() == 1)

        model.retry()
        await model.waitForCurrentTask()

        #expect(model.state == .ready(identity))
        #expect(model.selectedTrackID == "track-standard")
        #expect(await repository.cueRequestCount() == 2)
    }

    @Test
    func turningOffAndSwitchingTrackReplacesPresentedCue() async throws {
        let repository = SubtitleRepositoryStub()
        let timeline = SubtitleTimelineStub()
        let model = makeModel(repository: repository, timeline: timeline)
        model.selectVideo(identity)
        await model.waitForCurrentTask()
        model.selectTrack("track-standard")
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
        await model.waitForCurrentTask()
        model.selectTrack("track-standard")
        try await waitUntil {
            model.state == .loadingTrack(identity)
                && model.selectedTrackID == "track-standard"
                && model.tracks.contains { $0.id == "track-automatic" }
        }
        try await waitUntilAsync {
            await repository.hasStartedCueRequest("track-standard")
        }
        model.selectTrack("track-automatic")
        await model.waitForCurrentTask()
        try await waitUntilAsync {
            await repository.hasCompletedCueRequest("track-standard")
        }
        timeline.publish(snapshot(position: 2, state: .playing))
        try await waitForCue("自动生成字幕", in: model)
        #expect(model.currentCueText == "自动生成字幕")

        #expect(model.selectedTrackID == "track-automatic")
        #expect(model.currentCueText == "自动生成字幕")

        model.selectVideo(oldIdentity)
        await model.waitForCurrentTask()
        model.selectTrack("track-standard")
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
    func lateOldVideoCuesNeverReplaceCurrentPresentation() async throws {
        let repository = LateCueSubtitleRepository(
            oldIdentity: identity,
            currentIdentity: oldIdentity
        )
        let timeline = SubtitleTimelineStub()
        let model = makeModel(repository: repository, timeline: timeline)

        model.selectVideo(identity)
        await model.waitForCurrentTask()
        model.selectTrack("track-\(identity.cid)")
        do {
            try await waitUntilAsync {
                await repository.oldCueRequestStarted()
            }
            #expect(model.state == .loadingTrack(identity))
            #expect(model.currentCueText == nil)

            model.selectVideo(oldIdentity)
            #expect(model.currentCueText == nil)
            await model.waitForCurrentTask()
            model.selectTrack("track-\(oldIdentity.cid)")
            await model.waitForCurrentTask()
            timeline.publish(
                snapshot(
                    position: 2,
                    identity: oldIdentity,
                    state: .playing
                )
            )
            try await waitForCue("当前视频字幕", in: model)
            #expect(model.state == .ready(oldIdentity))
            #expect(model.currentCueText == "当前视频字幕")

            await repository.releaseOldCueRequest()
            try await waitUntilAsync {
                await repository.oldCueRequestReturned()
            }
            #expect(model.currentCueText == "当前视频字幕")

            timeline.publish(
                snapshot(
                    position: 2,
                    identity: oldIdentity,
                    state: .playing,
                    discontinuityGeneration: 2
                )
            )
            try await waitForCue("当前视频字幕", in: model)
            #expect(model.state == .ready(oldIdentity))
        } catch {
            await repository.releaseOldCueRequest()
            throw error
        }
    }

    @Test
    func staleResetCannotInvalidateNewSessionForSameIdentity() async throws {
        let repository = ABAResetSubtitleRepository(
            repeatedIdentity: identity,
            otherIdentity: oldIdentity
        )
        let timeline = SubtitleTimelineStub()
        let model = makeModel(repository: repository, timeline: timeline)

        model.selectVideo(identity)
        await model.waitForCurrentTask()
        model.selectTrack("track-\(identity.cid)")
        await model.waitForCurrentTask()
        #expect(model.state == .ready(identity))

        do {
            model.selectVideo(oldIdentity)
            try await waitUntilAsync {
                await repository.staleResetStarted()
            }

            model.selectVideo(identity)
            await repository.releaseStaleReset()
            try await waitUntilAsync {
                await repository.staleResetCompleted()
            }
            try await waitUntil {
                model.state == .ready(identity)
                    && model.tracks.contains {
                        $0.id == "track-\(identity.cid)"
                    }
            }
            model.selectTrack("track-\(identity.cid)")
            try await waitUntilAsync {
                await repository.repeatedCueRequestStarted()
            }
            #expect(model.state == .loadingTrack(identity))
            await repository.releaseRepeatedCueRequest()
            await model.waitForCurrentTask()

            #expect(model.state == .ready(identity))
            #expect(
                await repository
                    .repeatedReloadBeganBeforeStaleResetCompleted() == false
            )
            #expect(
                await repository.trackRequestCount(for: identity) == 2
            )
            #expect(
                await repository.trackRequestCount(for: oldIdentity) == 0
            )
            timeline.publish(snapshot(position: 2, state: .playing))
            try await waitForCue("新会话字幕", in: model)
            #expect(model.currentCueText == "新会话字幕")
        } catch {
            await repository.releaseAll()
            await model.waitForCurrentTask()
            throw error
        }
    }

    @Test
    func authenticationSuspensionResumesCurrentVideoAfterResetCompletes() async throws {
        let repository = ABAResetSubtitleRepository(
            repeatedIdentity: identity,
            otherIdentity: oldIdentity
        )
        let timeline = SubtitleTimelineStub()
        let model = makeModel(repository: repository, timeline: timeline)

        model.selectVideo(identity)
        await model.waitForCurrentTask()
        model.selectTrack("track-\(identity.cid)")
        await model.waitForCurrentTask()
        #expect(model.state == .ready(identity))

        do {
            model.suspendForAuthentication()
            #expect(model.state == .idle)
            #expect(model.currentCueText == nil)
            try await waitUntilAsync {
                await repository.staleResetStarted()
            }

            model.retry()
            await repository.releaseStaleReset()
            try await waitUntilAsync {
                await repository.staleResetCompleted()
            }
            try await waitUntil {
                model.state == .ready(identity)
                    && model.tracks.contains {
                        $0.id == "track-\(identity.cid)"
                    }
            }
            model.selectTrack("track-\(identity.cid)")
            try await waitUntilAsync {
                await repository.repeatedCueRequestStarted()
            }
            await repository.releaseRepeatedCueRequest()
            await model.waitForCurrentTask()

            #expect(model.state == .ready(identity))
            timeline.publish(snapshot(position: 2, state: .playing))
            try await waitForCue("新会话字幕", in: model)
        } catch {
            await repository.releaseAll()
            await model.waitForCurrentTask()
            throw error
        }
    }

    @Test
    func closingAfterAuthenticationSuspensionDoesNotResumeVideo() async throws {
        let repository = ABAResetSubtitleRepository(
            repeatedIdentity: identity,
            otherIdentity: oldIdentity
        )
        let model = makeModel(
            repository: repository,
            timeline: SubtitleTimelineStub()
        )

        model.selectVideo(identity)
        await model.waitForCurrentTask()
        model.selectTrack("track-\(identity.cid)")
        await model.waitForCurrentTask()
        #expect(model.state == .ready(identity))

        do {
            model.suspendForAuthentication()
            try await waitUntilAsync {
                await repository.staleResetStarted()
            }

            model.reset()
            model.retry()
            await repository.releaseStaleReset()
            try await waitUntilAsync {
                await repository.staleResetCompleted()
            }

            #expect(model.state == .idle)
            #expect(
                await repository.trackRequestCount(for: identity) == 1
            )
        } catch {
            await repository.releaseAll()
            throw error
        }
    }

    @Test
    func closingDuringQueuedTransitionStillResetsLoadedSession() async throws {
        let repository = ABAResetSubtitleRepository(
            repeatedIdentity: identity,
            otherIdentity: oldIdentity
        )
        let model = makeModel(
            repository: repository,
            timeline: SubtitleTimelineStub()
        )

        model.selectVideo(identity)
        await model.waitForCurrentTask()
        model.selectTrack("track-\(identity.cid)")
        await model.waitForCurrentTask()
        #expect(model.state == .ready(identity))

        do {
            model.selectVideo(oldIdentity)
            model.reset()
            #expect(model.state == .idle)

            try await waitUntilAsync {
                await repository.staleResetStarted()
            }
            await repository.releaseStaleReset()
            try await waitUntilAsync {
                await repository.staleResetCompleted()
            }

            #expect(await repository.activeIdentity() == nil)
            #expect(
                await repository.trackRequestCount(for: oldIdentity) == 0
            )
            #expect(model.state == .idle)
            model.retry()
            #expect(model.state == .idle)
        } catch {
            await repository.releaseAll()
            throw error
        }
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
            authModel.state
                == .failed(
                    identity,
                    .authenticationRequired
                )
        )

        authModel.reset()
        #expect(authModel.state == .idle)
        #expect(authModel.tracks.isEmpty)
        #expect(authModel.selectedTrackID == nil)
        #expect(authModel.currentCueText == nil)
        authModel.retry()
        #expect(authModel.state == .idle)
    }

    private func makeModel(
        repository: any SubtitleRepository,
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

    private func waitUntilAsync(
        _ condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !(await condition()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await condition())
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
    private var cueRequests = 0
    private var cueFailuresRemaining: Int
    private var startedCueTracks: Set<String> = []
    private var completedCueTracks: Set<String> = []

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
        cueDelays: [String: Duration] = [:],
        cueFailuresRemaining: Int = 0
    ) {
        tracksResult = tracks
        self.cueDelays = cueDelays
        self.cueFailuresRemaining = cueFailuresRemaining
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
        cueRequests += 1
        markCueRequestStarted(trackID)
        defer { markCueRequestCompleted(trackID) }
        if cueFailuresRemaining > 0 {
            cueFailuresRemaining -= 1
            throw SubtitleApplicationError.unavailable
        }
        if let delay = cueDelays[trackID] {
            try await Task.sleep(for: delay)
        }
        if trackID == "track-automatic" {
            return [
                SubtitleCue(
                    startSeconds: 1,
                    endSeconds: 3.5,
                    text: "自动生成字幕"
                )
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

    func cueRequestCount() -> Int {
        cueRequests
    }

    func hasStartedCueRequest(_ trackID: String) -> Bool {
        startedCueTracks.contains(trackID)
    }

    func hasCompletedCueRequest(_ trackID: String) -> Bool {
        completedCueTracks.contains(trackID)
    }

    private func markCueRequestStarted(_ trackID: String) {
        startedCueTracks.insert(trackID)
    }

    private func markCueRequestCompleted(_ trackID: String) {
        completedCueTracks.insert(trackID)
    }
}

private actor LateCueSubtitleRepository: SubtitleRepository {
    private let oldIdentity: PlaybackItemIdentity
    private let currentIdentity: PlaybackItemIdentity
    private var oldCueStarted = false
    private var oldCueReturned = false
    private var oldCueReleased = false
    private var oldCueContinuation: CheckedContinuation<Void, Never>?

    init(
        oldIdentity: PlaybackItemIdentity,
        currentIdentity: PlaybackItemIdentity
    ) {
        self.oldIdentity = oldIdentity
        self.currentIdentity = currentIdentity
    }

    func tracks(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleTrack] {
        [track(for: identity)]
    }

    func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) async throws -> [SubtitleCue] {
        if identity == oldIdentity {
            oldCueStarted = true
            await withCheckedContinuation { continuation in
                if oldCueReleased {
                    continuation.resume()
                } else {
                    oldCueContinuation = continuation
                }
            }
            oldCueReturned = true
            return [cue(text: "旧视频字幕")]
        }
        guard identity == currentIdentity else {
            throw SubtitleApplicationError.invalidRequest
        }
        return [cue(text: "当前视频字幕")]
    }

    func reset(for identity: PlaybackItemIdentity) async {}

    func oldCueRequestStarted() -> Bool { oldCueStarted }

    func oldCueRequestReturned() -> Bool { oldCueReturned }

    func releaseOldCueRequest() {
        oldCueReleased = true
        oldCueContinuation?.resume()
        oldCueContinuation = nil
    }

    private func track(
        for identity: PlaybackItemIdentity
    ) -> SubtitleTrack {
        SubtitleTrack(
            id: "track-\(identity.cid)",
            languageCode: "zh-CN",
            displayName: "测试字幕",
            kind: .standard
        )
    }

    private func cue(text: String) -> SubtitleCue {
        SubtitleCue(
            startSeconds: 1,
            endSeconds: 3,
            text: text
        )
    }
}

private actor ABAResetSubtitleRepository: SubtitleRepository {
    private let repeatedIdentity: PlaybackItemIdentity
    private let otherIdentity: PlaybackItemIdentity
    private var generation: UInt64 = 0
    private var currentIdentity: PlaybackItemIdentity?
    private var trackRequestCounts: [PlaybackItemIdentity: Int] = [:]
    private var repeatedCueRequestCount = 0
    private var staleResetHasStarted = false
    private var staleResetHasCompleted = false
    private var staleResetReleased = false
    private var repeatedCueHasStarted = false
    private var repeatedReloadBeganBeforeResetCompleted = false
    private var repeatedCueReleased = false
    private var staleResetContinuation: CheckedContinuation<Void, Never>?
    private var repeatedCueContinuation: CheckedContinuation<Void, Never>?

    init(
        repeatedIdentity: PlaybackItemIdentity,
        otherIdentity: PlaybackItemIdentity
    ) {
        self.repeatedIdentity = repeatedIdentity
        self.otherIdentity = otherIdentity
    }

    func tracks(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleTrack] {
        trackRequestCounts[identity, default: 0] += 1
        if identity == repeatedIdentity,
            trackRequestCounts[identity] == 2
        {
            repeatedReloadBeganBeforeResetCompleted =
                !staleResetHasCompleted
        }
        generation &+= 1
        currentIdentity = identity
        return [track(for: identity)]
    }

    func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) async throws -> [SubtitleCue] {
        guard currentIdentity == identity else {
            throw SubtitleApplicationError.invalidRequest
        }
        let requestGeneration = generation

        if identity == repeatedIdentity {
            repeatedCueRequestCount += 1
            if repeatedCueRequestCount == 2 {
                repeatedCueHasStarted = true
                await withCheckedContinuation { continuation in
                    if repeatedCueReleased {
                        continuation.resume()
                    } else {
                        repeatedCueContinuation = continuation
                    }
                }
            }
        }

        guard currentIdentity == identity,
            generation == requestGeneration
        else {
            throw CancellationError()
        }
        return [
            SubtitleCue(
                startSeconds: 1,
                endSeconds: 3,
                text: identity == repeatedIdentity
                    ? (repeatedCueRequestCount == 1
                        ? "初始会话字幕"
                        : "新会话字幕")
                    : "其他视频字幕"
            )
        ]
    }

    func reset(for identity: PlaybackItemIdentity) async {
        if identity == repeatedIdentity, !staleResetHasStarted {
            staleResetHasStarted = true
            await withCheckedContinuation { continuation in
                if staleResetReleased {
                    continuation.resume()
                } else {
                    staleResetContinuation = continuation
                }
            }
        }

        if currentIdentity == identity {
            generation &+= 1
            currentIdentity = nil
        }
        if identity == repeatedIdentity {
            staleResetHasCompleted = true
        }
    }

    func staleResetStarted() -> Bool { staleResetHasStarted }

    func staleResetCompleted() -> Bool { staleResetHasCompleted }

    func repeatedCueRequestStarted() -> Bool { repeatedCueHasStarted }

    func repeatedReloadBeganBeforeStaleResetCompleted() -> Bool {
        repeatedReloadBeganBeforeResetCompleted
    }

    func activeIdentity() -> PlaybackItemIdentity? { currentIdentity }

    func trackRequestCount(
        for identity: PlaybackItemIdentity
    ) -> Int {
        trackRequestCounts[identity, default: 0]
    }

    func releaseStaleReset() {
        staleResetReleased = true
        staleResetContinuation?.resume()
        staleResetContinuation = nil
    }

    func releaseRepeatedCueRequest() {
        repeatedCueReleased = true
        repeatedCueContinuation?.resume()
        repeatedCueContinuation = nil
    }

    func releaseAll() {
        releaseStaleReset()
        releaseRepeatedCueRequest()
    }

    private func track(
        for identity: PlaybackItemIdentity
    ) -> SubtitleTrack {
        SubtitleTrack(
            id: "track-\(identity.cid)",
            languageCode: "zh-CN",
            displayName: identity == otherIdentity
                ? "其他视频字幕"
                : "重复视频字幕",
            kind: .standard
        )
    }
}

@MainActor
private final class SubtitleTimelineStub: PlaybackTimelineProviding {
    private(set) var currentTimelineSnapshot = PlaybackTimelineSnapshot.idle
    private var continuations: [UUID: AsyncStream<PlaybackTimelineSnapshot>.Continuation] = [:]

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
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }
}
