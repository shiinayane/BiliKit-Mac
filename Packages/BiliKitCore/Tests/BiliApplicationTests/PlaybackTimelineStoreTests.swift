import Foundation
import Testing
@testable import BiliApplication

@Suite
@MainActor
struct PlaybackTimelineStoreTests {
    @Test
    func virtualTimelineTracksPauseRateAndSeekGeneration() {
        let store = PlaybackTimelineStore()
        let identity = PlaybackItemIdentity(
            bvid: "BV1TimelineFixture",
            cid: 900_001
        )

        let token = store.beginItem(identity: identity)
        let loadGeneration = store.currentSnapshot.discontinuityGeneration
        store.markReady(token: token, durationSeconds: 120)
        store.update(
            token: token,
            positionSeconds: 12.5,
            rate: 2,
            state: .playing
        )

        #expect(store.currentSnapshot.identity == identity)
        #expect(store.currentSnapshot.positionSeconds == 12.5)
        #expect(store.currentSnapshot.durationSeconds == 120)
        #expect(store.currentSnapshot.rate == 2)
        #expect(store.currentSnapshot.state == .playing)

        store.update(token: token, rate: 0, state: .paused)
        #expect(store.currentSnapshot.positionSeconds == 12.5)
        #expect(store.currentSnapshot.rate == 0)
        #expect(store.currentSnapshot.state == .paused)

        store.markDiscontinuity(token: token, positionSeconds: 45)
        #expect(store.currentSnapshot.positionSeconds == 45)
        #expect(
            store.currentSnapshot.discontinuityGeneration
                == loadGeneration + 1
        )

        store.markDiscontinuity(token: token, positionSeconds: 8)
        #expect(store.currentSnapshot.positionSeconds == 8)
        #expect(
            store.currentSnapshot.discontinuityGeneration
                == loadGeneration + 2
        )
    }

    @Test
    func replacementRejectsOldItemUpdatesAndClear() {
        let store = PlaybackTimelineStore()
        let oldIdentity = PlaybackItemIdentity(
            bvid: "BV1OldTimeline",
            cid: 900_001
        )
        let newIdentity = PlaybackItemIdentity(
            bvid: "BV1NewTimeline",
            cid: 900_002
        )
        let oldToken = store.beginItem(identity: oldIdentity)
        let newToken = store.beginItem(identity: newIdentity)
        let replacementGeneration = store.currentSnapshot.discontinuityGeneration

        store.update(
            token: oldToken,
            positionSeconds: 99,
            rate: 1,
            state: .playing
        )
        store.clear(token: oldToken)

        #expect(store.currentSnapshot.identity == newIdentity)
        #expect(store.currentSnapshot.positionSeconds == 0)
        #expect(store.currentSnapshot.state == .loading)
        #expect(
            store.currentSnapshot.discontinuityGeneration
                == replacementGeneration
        )

        store.clear(token: newToken)
        #expect(store.currentSnapshot.identity == nil)
        #expect(store.currentSnapshot.state == .idle)
        #expect(
            store.currentSnapshot.discontinuityGeneration
                == replacementGeneration + 1
        )
    }

    @Test
    func newSubscriberReceivesCurrentSnapshot() async {
        let store = PlaybackTimelineStore()
        let identity = PlaybackItemIdentity(
            bvid: "BV1CurrentTimeline",
            cid: 900_001
        )
        _ = store.beginItem(identity: identity)

        let stream = store.updates()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()

        #expect(first == store.currentSnapshot)
    }

    @Test
    func cancellingSubscriberRemovesContinuation() async {
        let store = PlaybackTimelineStore()
        let stream = store.updates()
        let consumer = Task { @MainActor in
            for await _ in stream {}
        }

        await Task.yield()
        #expect(store.subscriberCount == 1)
        consumer.cancel()
        await consumer.value

        for _ in 0..<20 where store.subscriberCount != 0 {
            await Task.yield()
        }
        #expect(store.subscriberCount == 0)
    }

    @Test
    func snapshotNormalizesInvalidNumericInputAndRedactsIdentity() {
        let identity = PlaybackItemIdentity(
            bvid: "BV1PrivateFixture",
            cid: 900_001
        )
        let snapshot = PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: -Double.infinity,
            durationSeconds: Double.nan,
            rate: -Double.infinity,
            state: .playing,
            discontinuityGeneration: 1
        )

        #expect(snapshot.positionSeconds == 0)
        #expect(snapshot.durationSeconds == nil)
        #expect(snapshot.rate == 0)
        #expect(!String(describing: identity).contains(identity.bvid))
        #expect(!String(reflecting: identity).contains(String(identity.cid)))
    }
}
