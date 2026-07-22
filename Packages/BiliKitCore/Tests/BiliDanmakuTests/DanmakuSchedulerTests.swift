import BiliApplication
import BiliDanmaku
import BiliModels
import Foundation
import Testing

@Suite
struct DanmakuSchedulerTests {
    private let identity = PlaybackItemIdentity(
        bvid: "BV1DanmakuFixture",
        cid: 700_001
    )

    @Test
    func virtualTimelineHandlesPauseRateAndSegmentBoundary() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        scheduler.store(
            DanmakuSegment(
                index: 1,
                events: [
                    event(id: "a", time: 1.0),
                    event(id: "b", time: 2.0),
                    event(id: "boundary", time: 360.1),
                ]
            ),
            for: identity
        )
        scheduler.store(
            DanmakuSegment(
                index: 2,
                events: [event(id: "boundary", time: 360.1)]
            ),
            for: identity
        )

        let initialValue = scheduler.consume(
            snapshot(position: 0, rate: 1, generation: 1)
        )
        let initial = try #require(initialValue)
        #expect(initial.clearsExisting)

        let firstValue = scheduler.consume(
            snapshot(position: 1.1, rate: 1, generation: 1)
        )
        let first = try #require(firstValue)
        #expect(first.events.map(\.id) == ["a"])

        let paused = scheduler.consume(
            snapshot(position: 1.5, rate: 0, state: .paused, generation: 1)
        )
        #expect(paused == nil)
        let doubledValue = scheduler.consume(
            snapshot(position: 2.1, rate: 2, generation: 1)
        )
        let doubled = try #require(doubledValue)
        #expect(doubled.events.map(\.id) == ["b"])

        let boundaryValue = scheduler.consume(
            snapshot(position: 360.2, rate: 2, generation: 1)
        )
        let boundary = try #require(boundaryValue)
        #expect(boundary.events.map(\.id) == ["boundary"])
        #expect(
            scheduler.desiredSegmentIndices(
                for: snapshot(position: 360.2, rate: 2, generation: 1)
            ) == [2, 3]
        )
    }

    @Test
    func discontinuityClearsWithoutBackfillAndBackwardSeekCanReemit() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        scheduler.store(
            DanmakuSegment(
                index: 1,
                events: [event(id: "repeat", time: 5)]
            ),
            for: identity
        )

        _ = scheduler.consume(snapshot(position: 0, rate: 1, generation: 1))
        let firstValue = scheduler.consume(
            snapshot(position: 6, rate: 1, generation: 1)
        )
        let first = try #require(firstValue)
        #expect(first.events.map(\.id) == ["repeat"])

        let forwardSeekValue = scheduler.consume(
            snapshot(position: 100, rate: 1, generation: 2)
        )
        let forwardSeek = try #require(forwardSeekValue)
        #expect(forwardSeek.clearsExisting)
        #expect(forwardSeek.events.isEmpty)

        let backwardSeekValue = scheduler.consume(
            snapshot(position: 0, rate: 1, generation: 3)
        )
        let backwardSeek = try #require(backwardSeekValue)
        #expect(backwardSeek.clearsExisting)
        let replayValue = scheduler.consume(
            snapshot(position: 6, rate: 1, generation: 3)
        )
        let replay = try #require(replayValue)
        #expect(replay.events.map(\.id) == ["repeat"])
    }

    @Test
    func filterAndDisabledStatePreventEmission() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        scheduler.setFilter(
            DanmakuFilter(
                showsScrolling: true,
                showsTop: false,
                showsBottom: true,
                minimumWeight: 3,
                blockedKeywords: ["BLOCK"]
            )
        )
        scheduler.store(
            DanmakuSegment(
                index: 1,
                events: [
                    event(id: "low", time: 1, weight: 1),
                    event(id: "top", time: 2, mode: .top, weight: 5),
                    event(id: "word", time: 3, text: "block fixture", weight: 5),
                    event(id: "allowed", time: 4, weight: 5),
                ]
            ),
            for: identity
        )
        _ = scheduler.consume(snapshot(position: 0, rate: 1, generation: 1))
        let batchValue = scheduler.consume(
            snapshot(position: 5, rate: 1, generation: 1)
        )
        let batch = try #require(batchValue)
        #expect(batch.events.map(\.id) == ["allowed"])

        scheduler.setEnabled(false)
        let disabled = scheduler.consume(
            snapshot(position: 6, rate: 1, generation: 1)
        )
        #expect(disabled == nil)
    }

    @Test
    func oldIdentityAndCacheGrowthStayBounded() {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        let other = PlaybackItemIdentity(bvid: "BV1OtherFixture", cid: 8)
        scheduler.store(
            DanmakuSegment(index: 1, events: [event(id: "old", time: 1)]),
            for: other
        )
        for index in 1...8 {
            scheduler.store(
                DanmakuSegment(index: index, events: []),
                for: identity
            )
        }

        #expect(scheduler.cachedSegmentCount == DanmakuScheduler.maximumCachedSegments)
        let oldIdentity = scheduler.consume(
            PlaybackTimelineSnapshot(
                identity: other,
                positionSeconds: 2,
                durationSeconds: nil,
                rate: 1,
                state: .playing,
                discontinuityGeneration: 1
            )
        )
        #expect(oldIdentity == nil)
    }

    private func snapshot(
        position: Double,
        rate: Double,
        state: PlaybackTimelineState = .playing,
        generation: UInt64
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 900,
            rate: rate,
            state: state,
            discontinuityGeneration: generation
        )
    }

    private func event(
        id: String,
        time: Double,
        mode: DanmakuPresentationMode = .scrolling,
        text: String = "fixture",
        weight: Int = 5
    ) -> DanmakuEvent {
        DanmakuEvent(
            id: id,
            timeSeconds: time,
            mode: mode,
            text: text,
            fontSize: 25,
            colorRGB: 0xFF_FF_FF,
            weight: weight
        )
    }
}
