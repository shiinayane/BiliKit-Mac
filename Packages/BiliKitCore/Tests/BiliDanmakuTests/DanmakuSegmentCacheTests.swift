import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定分段缓存的契约：当前分段先要，分段开头一并要上一段，未到结尾才要下一段；缓存超过三段时，快照
/// 位置与显示时间两边需要的分段都不淘汰，其余按离显示时间最远的先淘汰；快照跳远而显示时间没动时刚存入的
/// 落点分段与屏上那边的分段都留着，显示时间跟过去之后再存入一段就回到三段；读不到显示时间时与只按最近
/// 观察到的快照位置（含拖动中的位置）保留最近三段完全相同；其他 identity 的分段不进缓存。
@Suite
struct DanmakuSegmentCacheTests {
    private let identity = PlaybackItemIdentity(bvid: "BV1SegmentCache", cid: 1)

    @Test(
        arguments: [
            (5.0, nil, [1, 2]),
            (365.0, nil, [2, 1, 3]),
            (450.0, nil, [2, 3]),
            (725.0, 800.0, [3, 2]),
            (500.0, 700.0, [2])
        ] as [(Double, Double?, [Int])]
    )
    func desiredSegmentsFollowThePosition(
        position: Double,
        duration: Double?,
        expected: [Int]
    ) {
        var cache = DanmakuSegmentCache()
        cache.begin(for: identity)

        let snapshot = PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: duration,
            rate: 1,
            state: .playing,
            discontinuityGeneration: 1
        )
        #expect(cache.desiredSegmentIndices(for: snapshot) == expected)
    }

    @Test
    func cacheKeepsTheThreeSegmentsNearestTheObservedPosition() {
        var cache = DanmakuSegmentCache()
        cache.begin(for: identity)
        for index in 1...3 {
            store(index, in: &cache, displayTime: nil)
        }

        // 拖动到第 6 段附近：落点分段到达时不因离起拖位置远而被淘汰。
        cache.observe(
            snapshot(identity: identity, position: 1_900, generation: 2)
        )
        cache.store(
            DanmakuSegment(index: 6, events: [danmakuEvent(id: "far", time: 1_900)]),
            for: identity,
            displayTime: nil
        )

        #expect(cache.contains(index: 6))
        #expect(cache.segments.keys.sorted() == [2, 3, 6])
        #expect(cache.segments[6]?.map(\.id) == ["far"])
    }

    /// 远跳到未缓冲区时两边的分段都留着，显示时间跟过去之后再存入一段才回到三段。
    ///
    /// 快照已在第 7 段，显示时间还停在第 2 段：落点的 7、8 两段存入后都留着，屏上那边的 1～3 段也留着；显示
    /// 时间跟到第 7 段后，要再存入一段才淘汰回三段（淘汰只在存入时发生）。
    @Test
    func farJumpKeepsBothSidesUntilTheDisplayTimeFollowsAndAnotherSegmentArrives() {
        var cache = DanmakuSegmentCache()
        cache.begin(for: identity)
        cache.observe(longSnapshot(position: 400))
        for index in 1...3 {
            store(index, in: &cache, displayTime: 400)
        }

        cache.observe(longSnapshot(position: 2_300))
        for index in [7, 8] {
            store(index, in: &cache, displayTime: 400)
        }
        #expect(cache.segments.keys.sorted() == [1, 2, 3, 7, 8])

        cache.observe(longSnapshot(position: 2_530))
        #expect(cache.segments.keys.sorted() == [1, 2, 3, 7, 8])
        store(9, in: &cache, displayTime: 2_300)
        #expect(cache.segments.keys.sorted() == [7, 8, 9])
    }

    /// 读不到显示时间时，任意的观察与存入序列都与「保留离最近快照位置最近的三段（距离相同取分段号小的）」
    /// 逐步相同。
    @Test
    func withoutADisplayTimeTrimmingKeepsTheThreeNearestTheSnapshot() {
        var sequence = SeededSequence(seed: 77)
        var cache = DanmakuSegmentCache()
        cache.begin(for: identity)
        var reference: Set<Int> = []
        var observed = 0.0
        for _ in 0..<500 {
            if sequence.next() % 3 == 0 {
                observed = sequence.unit() * 12 * DanmakuSegmentCache.segmentDurationSeconds
                cache.observe(longSnapshot(position: observed))
            }
            let index = 1 + Int(sequence.next() % 12)
            store(index, in: &cache, displayTime: nil)
            reference.insert(index)
            let current = DanmakuSegmentCache.segmentIndex(at: observed)
            reference = Set(
                reference.sorted {
                    (abs($0 - current), $0) < (abs($1 - current), $1)
                }
                .prefix(DanmakuSegmentCache.maximumCachedSegments)
            )
            #expect(Set(cache.segments.keys) == reference)
        }
    }

    @Test
    func otherIdentitiesAndInvalidIndicesAreNotCached() {
        var cache = DanmakuSegmentCache()
        cache.begin(for: identity)

        let otherIdentity = PlaybackItemIdentity(bvid: "BV1Other", cid: 2)
        let storedOther = cache.store(
            DanmakuSegment(index: 1, events: []),
            for: otherIdentity,
            displayTime: nil
        )
        let storedInvalid = cache.store(
            DanmakuSegment(index: 0, events: []),
            for: identity,
            displayTime: nil
        )

        #expect(!storedOther)
        #expect(!storedInvalid)
        #expect(cache.segments.isEmpty)
    }

    /// 把一个空分段存进当前 identity 的缓存。
    private func store(
        _ index: Int,
        in cache: inout DanmakuSegmentCache,
        displayTime: Double?
    ) {
        cache.store(
            DanmakuSegment(index: index, events: []),
            for: identity,
            displayTime: displayTime
        )
    }

    /// 时长一小时的快照：本 Suite 的位置会越过会话测试默认的 30 分钟时长，下一段不能因结尾被省掉。
    private func longSnapshot(position: Double) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 3_600,
            rate: 1,
            state: .playing,
            discontinuityGeneration: 1
        )
    }
}
