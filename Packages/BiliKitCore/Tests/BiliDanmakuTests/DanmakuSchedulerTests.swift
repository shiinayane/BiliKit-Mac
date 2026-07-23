import BiliApplication
@testable import BiliDanmaku
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
        #expect(scheduler.retainedDeliveredIDCount == 1)

        let forwardSeekValue = scheduler.consume(
            snapshot(position: 100, rate: 1, generation: 2)
        )
        let forwardSeek = try #require(forwardSeekValue)
        #expect(forwardSeek.clearsExisting)
        #expect(forwardSeek.events.isEmpty)
        #expect(scheduler.retainedDeliveredIDCount == 0)

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
        #expect(scheduler.retainedDeliveredIDCount == 1)
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
        #expect(scheduler.retainedDeliveredIDCount == 0)
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

    @Test
    func identityReplacementReemitsSameIDAndReenableDoesNotBackfill() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        scheduler.store(
            DanmakuSegment(
                index: 1,
                events: [event(id: "same-id", time: 1)]
            ),
            for: identity
        )
        _ = scheduler.consume(snapshot(position: 0, rate: 1, generation: 1))
        let firstValue = scheduler.consume(
            snapshot(position: 2, rate: 1, generation: 1)
        )
        let first = try #require(firstValue)
        #expect(first.events.map(\.id) == ["same-id"])

        let other = PlaybackItemIdentity(bvid: "BV1OtherFixture", cid: 8)
        scheduler.begin(for: other)
        scheduler.store(
            DanmakuSegment(
                index: 1,
                events: [
                    event(id: "same-id", time: 1),
                    event(id: "while-disabled", time: 3),
                    event(id: "after-enabled", time: 5),
                ]
            ),
            for: other
        )
        _ = scheduler.consume(
            snapshot(
                position: 0,
                rate: 1,
                generation: 1,
                identity: other
            )
        )
        let replacementValue = scheduler.consume(
            snapshot(
                position: 2,
                rate: 1,
                generation: 1,
                identity: other
            )
        )
        let replacement = try #require(replacementValue)
        #expect(replacement.events.map(\.id) == ["same-id"])

        scheduler.setEnabled(false)
        let disabled = scheduler.consume(
            snapshot(
                position: 4,
                rate: 1,
                generation: 1,
                identity: other
            )
        )
        #expect(disabled == nil)
        scheduler.setEnabled(true)
        let resumedAnchor = scheduler.consume(
            snapshot(
                position: 4.5,
                rate: 1,
                generation: 1,
                identity: other
            )
        )
        #expect(resumedAnchor == nil)
        let resumedValue = scheduler.consume(
            snapshot(
                position: 6,
                rate: 1,
                generation: 1,
                identity: other
            )
        )
        let resumed = try #require(resumedValue)
        #expect(resumed.events.map(\.id) == ["after-enabled"])
    }

    @Test
    func forwardPlaybackBoundsDeliveredIDsAndDeduplicatesAdjacentSegments() throws {
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)
        _ = scheduler.consume(snapshot(position: 0, rate: 1, generation: 1))

        for index in 1...8 {
            let start = Double(index - 1)
                * DanmakuScheduler.segmentDurationSeconds
            var events = [
                event(id: "unique-\(index)", time: start + 1),
                event(id: "rolling-duplicate", time: start + 2),
                event(
                    id: "boundary-\(index)",
                    time: start
                        + DanmakuScheduler.segmentDurationSeconds
                        - 0.1
                ),
            ]
            if index > 1 {
                events.append(
                    event(id: "boundary-\(index - 1)", time: start + 0.1)
                )
            }
            scheduler.store(
                DanmakuSegment(index: index, events: events),
                for: identity
            )

            let value = scheduler.consume(
                snapshot(
                    position: start
                        + DanmakuScheduler.segmentDurationSeconds
                        - 0.05,
                    rate: 1,
                    generation: 1
                )
            )
            let batch = try #require(value)
            #expect(
                batch.events.map(\.id)
                    == (
                        index == 1
                            ? [
                                "unique-1",
                                "rolling-duplicate",
                                "boundary-1",
                            ]
                            : [
                                "unique-\(index)",
                                "boundary-\(index)",
                            ]
                    )
            )
            #expect(
                scheduler.retainedDeliveredSegmentCount
                    <= DanmakuScheduler.maximumCachedSegments
            )
            #expect(
                scheduler.retainedDeliveredIDCount
                    <= DanmakuScheduler.maximumCachedSegments * 4
            )
        }

        #expect(
            scheduler.retainedDeliveredSegmentCount
                == DanmakuScheduler.maximumCachedSegments
        )
        #expect(
            scheduler.retainedDeliveredIDCount
                == DanmakuScheduler.maximumCachedSegments * 4
        )
        scheduler.reset()
        #expect(scheduler.retainedDeliveredSegmentCount == 0)
        #expect(scheduler.retainedDeliveredIDCount == 0)
    }

    private func snapshot(
        position: Double,
        rate: Double,
        state: PlaybackTimelineState = .playing,
        generation: UInt64,
        identity: PlaybackItemIdentity? = nil
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity ?? self.identity,
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
