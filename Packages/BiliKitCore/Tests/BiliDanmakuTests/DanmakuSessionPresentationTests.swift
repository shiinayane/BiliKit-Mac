import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定弹幕会话与呈现端的契约：当前 identity 的每个快照原样交给呈现端；分段到达时交出整份缓存；
/// 开关、模式与停止同步转给呈现端；暂停时一个分段加载完就继续请求还缺的分段，不等下一个快照。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuSessionPresentationTests {
    @Test
    func presentationSinkReceivesEveryAcceptedSnapshot() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1PresentationFixture", cid: 3)
        let (session, timeline, sink) = makeDanmakuSession(repository: StubDanmakuRepository())

        session.start(for: identity)
        let paused = snapshot(
            identity: identity,
            position: 1,
            generation: 7,
            rate: 0,
            state: .paused
        )
        let playing = snapshot(identity: identity, position: 1, generation: 7, rate: 2)
        timeline.publish(paused)
        try await sink.waitForUpdateCount(1, identity: identity)
        timeline.publish(
            snapshot(
                identity: PlaybackItemIdentity(bvid: "BV1Other", cid: 1),
                position: 3,
                generation: 1
            )
        )
        timeline.publish(playing)
        try await sink.waitForUpdateCount(2, identity: identity)

        #expect(sink.snapshots.filter { $0.identity == identity } == [paused, playing])
        #expect(sink.snapshots.allSatisfy { $0.identity == identity })
        session.stop()
    }

    @Test
    func controlsReachThePresentationSynchronously() throws {
        let (session, _, sink) = makeDanmakuSession(repository: StubDanmakuRepository())

        session.setEnabled(false)
        session.setEnabled(false)
        #expect(sink.enabledChanges == [false])

        session.setModeVisibility(scrolling: false, top: true, bottom: true)
        session.setMergesDuplicates(true)
        session.setMergesDuplicates(true)
        session.setModeVisibility(scrolling: true, top: true, bottom: true)
        #expect(
            sink.filters == [
                DanmakuFilter(showsScrolling: false),
                DanmakuFilter(showsScrolling: false, mergesDuplicates: true),
                DanmakuFilter(mergesDuplicates: true)
            ]
        )

        session.stop()
        #expect(sink.stopCount == 1)
    }

    /// 暂停中只来一个快照：分段到达后整份缓存交给呈现端，腾出的名额立即用来请求还缺的分段。
    @Test
    func pausedSessionDeliversSegmentsAndKeepsLoadingWithoutAnotherSnapshot() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1PausedSegments", cid: 5)
        let events: [Int: [DanmakuEvent]] = [
            1: [danmakuEvent(id: "previous", time: 350)],
            2: [danmakuEvent(id: "current", time: 370)],
            3: [danmakuEvent(id: "next", time: 730)]
        ]
        let repository = StubDanmakuRepository(eventsBySegment: events)
        let (session, timeline, sink) = makeDanmakuSession(repository: repository)

        session.start(for: identity)
        timeline.publish(
            snapshot(identity: identity, position: 365, generation: 1, rate: 0, state: .paused)
        )
        try await sink.waitForUpdates { [unowned sink] in
            sink.segmentDeliveries.last?.segments.count == 3
        }

        #expect(sink.snapshots.count == 1)
        #expect(sink.segmentDeliveries.allSatisfy { $0.identity == identity })
        let delivered = try #require(sink.segmentDeliveries.last?.segments)
        #expect(delivered.mapValues { $0.map(\.id) } == events.mapValues { $0.map(\.id) })
        session.stop()
    }

    /// 互动弹幕在 `start` 时读一次：卡片交给呈现端，UP 主弹幕并入时间所在的分段。
    @Test
    func commandsDeliverCardsAndFoldUploaderDanmakuIntoItsSegment() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1CommandSession", cid: 6)
        let uploader = danmakuEvent(
            id: "command:up",
            time: 370,
            text: "UP 主说",
            isUploader: true
        )
        let card = DanmakuCommandCard(
            id: "command:grade",
            timeSeconds: 10,
            durationSeconds: 5,
            position: DanmakuCardPosition(x: 0.5, y: 0.65),
            content: .grade(
                DanmakuGradeCard(title: "评分", averageScore: 9, participantCount: 1, myScore: nil)
            )
        )
        let repository = StubDanmakuRepository(
            eventsBySegment: [2: [danmakuEvent(id: "current", time: 380)]],
            commands: .success(DanmakuCommands(uploaderEvents: [uploader], cards: [card]))
        )
        let (session, timeline, sink) = makeDanmakuSession(repository: repository)

        session.start(for: identity)
        timeline.publish(
            snapshot(identity: identity, position: 365, generation: 1, rate: 0, state: .paused)
        )
        try await sink.waitForUpdates { [unowned sink] in
            let segment = sink.segmentDeliveries.last?.segments[2] ?? []
            return !sink.commandCardDeliveries.isEmpty && segment.contains { $0.id == uploader.id }
        }

        #expect(sink.commandCardDeliveries.map(\.cards) == [[card]])
        #expect(sink.commandCardDeliveries.allSatisfy { $0.identity == identity })
        let delivered = try #require(sink.segmentDeliveries.last?.segments)
        #expect(delivered[2]?.map(\.id).sorted() == ["command:up", "current"])
        #expect(delivered[1]?.contains { $0.isUploader } == false)
        session.stop()
    }

    /// 互动弹幕读取失败只让它缺席：分段照常交出，凭据失效时报告一次账户复核。
    @Test
    func failedCommandsLeaveSegmentsAndReportRevalidationOnce() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1CommandFailure", cid: 7)
        let repository = StubDanmakuRepository(
            eventsBySegment: [1: [danmakuEvent(id: "segment", time: 10)]],
            commands: .failure(.authenticationInvalid)
        )
        let (session, timeline, sink) = makeDanmakuSession(repository: repository)
        var revalidationCount = 0
        session.setAuthenticationInvalidationHandler { revalidationCount += 1 }

        session.start(for: identity)
        timeline.publish(
            snapshot(identity: identity, position: 10, generation: 1, rate: 0, state: .paused)
        )
        try await sink.waitForUpdates { [unowned sink] in
            sink.segmentDeliveries.last?.segments[1]?.isEmpty == false && revalidationCount == 1
        }

        #expect(sink.commandCardDeliveries.isEmpty)
        #expect(revalidationCount == 1)
        session.stop()
    }
}
