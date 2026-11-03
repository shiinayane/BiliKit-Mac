import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定弹幕会话的分段加载契约：并发上限与位置决定请求哪些分段，结果写回缓存，远跳时落点分段只请求一次、
/// 屏上那边的分段在显示时间跟过去之前不被淘汰，失败与认证失效在一次会话内只处理一次。
///
/// 会话本身不可观察，测试只经产品出口判断：repository 收到的请求、presentation sink 收到的更新与
/// 认证失效回调。
///
/// 分段结果写回的确定性信号是「后续分段被请求」：会话同时最多加载两段，分段开头的位置让想要的分段多于两段，
/// 新分段只能在已发出的加载有结果写回（成功入缓存或失败记下）、释放名额之后才被请求。成功结果若没进缓存、
/// 失败若没被记下，释放的名额会先用来重新请求同一段，所以「请求的分段各不相同」同时证明了写回；
/// 名额不释放时不会再有请求，由 timeLimit 判失败。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuSessionTests {
    /// 在第 2 段开头，想要的分段依次是当前第 2 段、上一段第 1 段、下一段第 3 段。
    nonisolated private static let threeSegmentPosition = 365.0
    /// 同样在分段开头，想要第 3、2、4 段；第 1～3 段都已请求后，第 4 段被请求说明其中至多一段仍在加载。
    nonisolated private static let laterThreeSegmentPosition = 725.0

    /// 会话同时最多加载两段，按位置先要当前分段：在分段开头一条弹幕的最长时长之内先要当前与上一分段，
    /// 之后要当前与下一分段。
    @Test(arguments: [
        (0.0, [1, 2]),
        (DanmakuSessionTests.threeSegmentPosition, [1, 2]),
        (450.0, [2, 3])
    ])
    func sessionRequestsWantedSegmentsWithBoundedConcurrency(
        position: Double,
        expectedIndices: [Int]
    ) async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1DanmakuFixture", cid: 1)
        let repository = StubDanmakuRepository(.holdUntilReleased)
        let timeline = SessionTimeline()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            commandUseCase: DanmakuCommandUseCase(repository: repository),
            timeline: timeline
        )

        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: position, generation: 1))
        try await repository.waitForRequestCount(2, identity: identity)

        #expect(await repository.requestedIndices(for: identity).sorted() == expectedIndices)
        #expect(await repository.maximumActiveRequests() == 2)
        session.stop()
        await repository.releaseAll()
    }

    /// 成功的分段写回缓存并释放名额后，会话请求下一个想要的分段，且不重复请求已缓存的分段。
    ///
    /// 删掉写回缓存时第三次请求会是第 1 或第 2 段；名额不释放时不会再有请求，由 timeLimit 判失败。
    @Test
    func loadedSegmentsAreCachedAndFreeSlotsForTheNextWantedSegment() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1WriteBackFixture", cid: 8)
        let repository = StubDanmakuRepository(.holdUntilReleased)
        let (session, timeline, sink) = makeThreeSegmentSession(repository: repository)

        session.start(for: identity)
        try await advanceUntilRequestCount(
            2,
            identity: identity,
            generation: 1,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        #expect(await repository.requestedIndices(for: identity).sorted() == [1, 2])

        await repository.release(identity)
        try await advanceUntilRequestCount(
            3,
            identity: identity,
            generation: 1,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        #expect(await repository.requestedIndices(for: identity).sorted() == [1, 2, 3])
        session.stop()
    }

    @Test
    func replacingIdentityCancelsOldLoadsAndStopEndsTheSession() async throws {
        let first = PlaybackItemIdentity(bvid: "BV1FirstFixture", cid: 1)
        let second = PlaybackItemIdentity(bvid: "BV1SecondFixture", cid: 2)
        let repository = StubDanmakuRepository(.holdUntilReleased)
        let (session, timeline, sink) = makeThreeSegmentSession(repository: repository)

        session.start(for: first)
        try await advanceUntilRequestCount(
            2,
            identity: first,
            generation: 1,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        session.start(for: second)
        try await repository.waitForCancellationCount(2, identity: first)
        await repository.release(first)
        try await advanceUntilRequestCount(
            2,
            identity: second,
            generation: 2,
            timeline: timeline,
            sink: sink,
            repository: repository
        )

        // 新视频的分段照常写回并在名额释放后请求下一段；被取消的旧视频不再发起请求。
        await repository.release(second)
        try await advanceUntilRequestCount(
            3,
            identity: second,
            generation: 2,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        #expect(await repository.requestedIndices(for: second).sorted() == [1, 2, 3])
        #expect(await repository.requestCount(for: first) == 2)

        // stop 结束整个会话：退订时间线，之后的快照既不请求也不再交给呈现端。
        let updatesBeforeStop = sink.updateCount(for: second)
        session.stop()
        await timeline.waitForSubscriberCount(0)
        timeline.publish(
            snapshot(identity: second, position: Self.threeSegmentPosition, generation: 2)
        )
        #expect(await repository.requestCount(for: second) == 3)
        #expect(sink.updateCount(for: second) == updatesBeforeStop)
    }

    /// 失败的分段（含被风控拒绝的）在当前视频内不再请求。
    ///
    /// 412 的一次延迟重试由 API 客户端负责，会话不叠加。第 4 段被请求时，前三段至少两段的失败已写回；
    /// 若失败不被记住，释放的名额会先用来重新请求失败段，请求序列就会出现重复。
    @Test(arguments: [DanmakuApplicationError.unavailable, .requestRestricted])
    func failedSegmentsAreNotRetriedByLaterTimelineUpdates(
        error: DanmakuApplicationError
    ) async throws {
        let identity = PlaybackItemIdentity(
            bvid: "BV1FailingDanmakuFixture",
            cid: 4
        )
        let repository = StubDanmakuRepository(.fail(error))
        let (session, timeline, sink) = makeThreeSegmentSession(repository: repository)

        session.start(for: identity)
        try await advanceUntilRequestCount(
            3,
            identity: identity,
            generation: 1,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        try await advanceUntilRequestCount(
            4,
            identity: identity,
            generation: 1,
            position: Self.laterThreeSegmentPosition,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        #expect(await repository.requestedIndices(for: identity).sorted() == [1, 2, 3, 4])
        session.stop()
    }

    @Test
    func authenticationInvalidationIsReportedOncePerSession() async throws {
        let identity = PlaybackItemIdentity(
            bvid: "BV1AuthDanmakuFixture",
            cid: 40
        )
        let repository = StubDanmakuRepository(.fail(.authenticationInvalid))
        let (session, timeline, sink) = makeThreeSegmentSession(repository: repository)
        let invalidations = InvalidationRecorder()
        session.setAuthenticationInvalidationHandler {
            invalidations.record()
        }

        // 第 4 段被请求时，前三段至少两段的认证失效已处理；同一会话内回调只有一次。
        session.start(for: identity)
        try await advanceUntilRequestCount(
            3,
            identity: identity,
            generation: 1,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        try await advanceUntilRequestCount(
            4,
            identity: identity,
            generation: 1,
            position: Self.laterThreeSegmentPosition,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        #expect(invalidations.count == 1)

        // 新会话重新允许回调一次。
        session.stop()
        session.start(for: identity)
        try await advanceUntilRequestCount(
            6,
            identity: identity,
            generation: 2,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        try await invalidations.wait(until: 2)
        session.stop()
    }

    /// 换视频时清空失败记录：第 3 段被请求说明第一个视频至少有一段失败已记下，再换到第二个视频。
    ///
    /// 若记录未清空，第二个视频永远不会请求那一段，等不到三次请求，由 timeLimit 判失败。
    @Test
    func failedSegmentMemoryIsClearedForReplacement() async throws {
        let first = PlaybackItemIdentity(
            bvid: "BV1FirstFailureFixture",
            cid: 5
        )
        let second = PlaybackItemIdentity(
            bvid: "BV1SecondFailureFixture",
            cid: 6
        )
        let repository = StubDanmakuRepository(.fail(.unavailable))
        let (session, timeline, sink) = makeThreeSegmentSession(repository: repository)

        session.start(for: first)
        try await advanceUntilRequestCount(
            3,
            identity: first,
            generation: 1,
            timeline: timeline,
            sink: sink,
            repository: repository
        )

        session.start(for: second)
        try await advanceUntilRequestCount(
            3,
            identity: second,
            generation: 2,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        #expect(await repository.requestedIndices(for: second).sorted() == [1, 2, 3])
        #expect(await repository.requestCount(for: first) == 3)
        session.stop()
    }

    /// stop 后重新开始同一视频时，上一轮失败的分段重新请求并恢复；失败同步方式同上。
    @Test
    func restartingSessionAllowsFailedSegmentsToRecover() async throws {
        let identity = PlaybackItemIdentity(
            bvid: "BV1RecoveringDanmakuFixture",
            cid: 7
        )
        let repository = StubDanmakuRepository(.failFirstAttemptPerSegment(.unavailable))
        let (session, timeline, sink) = makeThreeSegmentSession(repository: repository)

        session.start(for: identity)
        try await advanceUntilRequestCount(
            3,
            identity: identity,
            generation: 1,
            timeline: timeline,
            sink: sink,
            repository: repository
        )

        // 若失败记录未随 stop 清空，被记下的那段永远不会再请求，等不到六次请求，由 timeLimit 判失败。
        session.stop()
        session.start(for: identity)
        try await advanceUntilRequestCount(
            6,
            identity: identity,
            generation: 2,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        #expect(
            await repository.requestedIndices(for: identity).sorted() == [1, 1, 2, 2, 3, 3]
        )
        session.stop()
    }

    /// 远跳到未缓冲区时落点分段各只请求一次，屏上那边的分段留到显示时间跟过去。
    ///
    /// 快照先到第 7 段，屏上弹幕（显示时间）还在第 2 段：落点的 7、8 两段各只请求一次、存入后不被淘汰，屏上
    /// 那边的 1～3 段也留着；显示时间跟到第 7 段后，下一段存入时淘汰回三段。
    ///
    /// 以显示时间为中心淘汰时，7 段一到就被淘汰、再按快照请求，这里等不到 1、2、3、7、8 同时在缓存，由
    /// timeLimit 判失败。
    @Test
    func farJumpLoadsTheLandingSegmentsOnceAndKeepsTheScreenSide() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1FarJumpFixture", cid: 9)
        let repository = StubDanmakuRepository()
        let timeline = SessionTimeline()
        let sink = SessionPresentationSink()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            commandUseCase: DanmakuCommandUseCase(repository: repository),
            timeline: timeline,
            presentationSink: sink
        )
        func publish(_ position: Double) {
            timeline.publish(
                PlaybackTimelineSnapshot(
                    identity: identity,
                    positionSeconds: position,
                    durationSeconds: 3_600,
                    rate: 1,
                    state: .playing,
                    discontinuityGeneration: 1
                )
            )
        }
        func waitForCachedSegments(_ expected: [Int]) async throws {
            try await sink.waitForUpdates {
                sink.segmentDeliveries.last?.segments.keys.sorted() == expected
            }
        }

        sink.currentDisplayTime = 400
        session.start(for: identity)
        publish(400)
        try await waitForCachedSegments([1, 2, 3])

        publish(2_300)
        try await waitForCachedSegments([1, 2, 3, 7, 8])
        let requested = await repository.requestedIndices(for: identity)
        #expect(requested.filter { $0 == 7 }.count == 1)
        #expect(requested.filter { $0 == 8 }.count == 1)

        sink.currentDisplayTime = 2_300
        publish(2_530)
        try await waitForCachedSegments([7, 8, 9])
        #expect(await repository.requestedIndices(for: identity).sorted() == [1, 2, 3, 7, 8, 9])
        session.stop()
    }

    /// 记录呈现端更新的会话；配合分段开头的位置，想要的分段多于并发上限。
    private func makeThreeSegmentSession(
        repository: StubDanmakuRepository
    ) -> (DanmakuSession, SessionTimeline, SessionPresentationSink) {
        let timeline = SessionTimeline()
        let sink = SessionPresentationSink()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            commandUseCase: DanmakuCommandUseCase(repository: repository),
            timeline: timeline,
            presentationSink: sink
        )
        return (session, timeline, sink)
    }

    /// 逐次发布 `position` 的快照并等呈现端收到，直到 repository 收到 `expected` 次请求。
    ///
    /// 会话只在处理时间线更新时发起请求；每步等的是产品事件，不按时长轮询。
    private func advanceUntilRequestCount(
        _ expected: Int,
        identity: PlaybackItemIdentity,
        generation: UInt64,
        position: Double = DanmakuSessionTests.threeSegmentPosition,
        timeline: SessionTimeline,
        sink: SessionPresentationSink,
        repository: StubDanmakuRepository
    ) async throws {
        while await repository.requestCount(for: identity) < expected {
            let nextUpdate = sink.updateCount(for: identity) + 1
            timeline.publish(
                snapshot(
                    identity: identity,
                    position: position,
                    generation: generation
                )
            )
            try await sink.waitForUpdateCount(nextUpdate, identity: identity)
        }
    }
}
