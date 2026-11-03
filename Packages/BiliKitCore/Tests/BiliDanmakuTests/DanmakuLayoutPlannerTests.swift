import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定弹幕布局的契约：同样的事件与设置总得到同样的车道；滚动弹幕不追尾、顶部底部独占槽位；
/// 分段边界接着上一段的占用排，上一段晚到时只有本段开头会变；同屏上限按确定的规则丢弃。
@Suite
struct DanmakuLayoutPlannerTests {
    @Test
    func sameEventsAndSettingsAlwaysGiveTheSameLayout() throws {
        let events = denseEvents(segment: 1, count: 400, seed: 7)
        let first = try #require(layouts([1: events]))
        let second = try #require(layouts([1: events.reversed()]))

        #expect(first[1]?.placements == second[1]?.placements)
        #expect(first[1]?.placements.isEmpty == false)
    }

    @Test
    func scrollingNeverCatchesUpAndFixedDanmakuOwnTheirSlot() throws {
        let result = try #require(layouts([1: denseEvents(segment: 1, count: 600, seed: 3)]))
        let placements = try #require(result[1]?.placements)

        expectNoOverlap(placements, configuration: Self.configuration)
    }

    @Test
    func segmentBoundaryContinuesThePreviousSegmentsLanes() throws {
        let tail = (0..<5).map {
            scrollingEvent(id: "tail-\($0)", time: 359.5, width: 300)
        }
        let head = (0..<8).map {
            scrollingEvent(id: "head-\($0)", time: 360.2, width: 300)
        }
        let result = try #require(layouts([1: tail, 2: head]))
        let placements = (result[1]?.placements ?? []) + (result[2]?.placements ?? [])

        expectNoOverlap(placements, configuration: Self.configuration)
        // 上一段末尾的五条还占着前五条车道，本段开头从第六条车道排起。
        let headLanes = try #require(result[2]?.placements.map(\.laneIndex))
        #expect(headLanes == Array(5..<10))
    }

    @Test
    func lateEarlierSegmentOnlyChangesTheStartOfTheNextSegment() throws {
        let previous = denseEvents(segment: 1, count: 900, seed: 11)
        let current = denseEvents(segment: 2, count: 900, seed: 12)
        let alone = try #require(layouts([2: current]))
        let late = try #require(layouts([1: previous, 2: current], reusing: alone))
        let continuous = try #require(layouts([1: previous, 2: current]))

        // 晚到之后与从头连续排的结果完全一致。
        #expect(late[2]?.placements == continuous[2]?.placements)
        let before = try #require(alone[2]?.placements)
        let after = try #require(late[2]?.placements)
        expectNoOverlap((late[1]?.placements ?? []) + after, configuration: Self.configuration)

        // 只有开头不同：两份占用收敛之后完全一致，本段后半段与晚到之前的布局相同。
        let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.request.event.id, $0) })
        let afterByID = Dictionary(uniqueKeysWithValues: after.map { ($0.request.event.id, $0) })
        let changedTimes = current.filter { beforeByID[$0.id] != afterByID[$0.id] }.map(
            \.timeSeconds
        )
        #expect(changedTimes.contains { $0 < 360 + (late[1]?.maximumDurationSeconds ?? 0) })
        #expect(changedTimes.allSatisfy { $0 < 540 })
    }

    @Test
    func reusedLayoutsStayUntilThePreviousSegmentsEndChanges() throws {
        let first = denseEvents(segment: 1, count: 300, seed: 21)
        let second = denseEvents(segment: 2, count: 300, seed: 22)
        let existing = try #require(layouts([1: first, 2: second]))
        let unchanged = try #require(layouts([1: first, 2: second], reusing: existing))

        #expect(unchanged[1]?.placements == existing[1]?.placements)
        #expect(unchanged[2]?.placements == existing[2]?.placements)
    }

    /// 相邻分段重复给出的弹幕只在前一段显示，同一段里重复的 ID 只显示一次；前一段晚到时也一样。
    @Test
    func repeatedIDsAppearOnce() throws {
        let first = [
            scrollingEvent(id: "repeated", time: 100, width: 200),
            scrollingEvent(id: "boundary", time: 359.9, width: 200)
        ]
        let second = [
            scrollingEvent(id: "repeated", time: 400, width: 200),
            scrollingEvent(id: "boundary", time: 360.1, width: 200),
            scrollingEvent(id: "twice", time: 370, width: 200),
            scrollingEvent(id: "twice", time: 380, width: 200)
        ]
        let alone = try #require(layouts([2: second]))
        let both = try #require(layouts([1: first, 2: second], reusing: alone))
        let ids = ((both[1]?.placements ?? []) + (both[2]?.placements ?? [])).map {
            "\($0.request.event.id)@\($0.admittedAtSeconds)"
        }

        #expect(ids.sorted() == ["boundary@359.9", "repeated@100.0", "twice@370.0"])
        #expect(both[2]?.placements == layouts([1: first, 2: second])?[2]?.placements)
    }

    /// 同屏上限按 (时间, ID) 顺序丢弃：同一时刻比上限多一条时，ID 最大的那条不显示，输入顺序无关。
    @Test
    func capacityDropsTheSameLaterEventsEveryTime() throws {
        let lanes = DanmakuLaneConfiguration(
            planningWidth: 800,
            planningHeight: DanmakuLaneConfiguration.laneHeight * 1_000,
            minimumHorizontalGap: 12,
            displayAreaFraction: 1
        )
        let count = DanmakuLaneConfiguration.hardMaximumActiveCount + 1
        let ids = (0..<count).map { String(format: "event-%04d", $0) }
        let events = ids.map { danmakuEvent(id: $0, time: 10, mode: .top, text: "x") }
        let result = try #require(layouts([1: events.reversed()], configuration: lanes))

        #expect(result[1]?.placements.map(\.request.event.id) == Array(ids.dropLast()))
    }

    @Test
    func filterAndSpeedChangeTheLayout() throws {
        let events = denseEvents(segment: 1, count: 200, seed: 5)
        let normal = try #require(layouts([1: events]))
        let fast = try #require(layouts([1: events], speedLevel: .five))
        let scrollingOnly = try #require(
            layouts([1: events], filter: DanmakuFilter(showsTop: false, showsBottom: false))
        )

        #expect(
            fast[1]?.placements.first { $0.request.event.mode == .scrolling }?.request
                .durationSeconds
                ?? 0
                < normal[1]?.placements.first { $0.request.event.mode == .scrolling }?.request
                .durationSeconds ?? 0
        )
        #expect(
            scrollingOnly[1]?.placements.allSatisfy { $0.request.event.mode == .scrolling } == true
        )
    }

    @Test
    func placementsAtATimeAreThoseOnScreenPlusTheLookahead() throws {
        let result = try #require(layouts([1: denseEvents(segment: 1, count: 500, seed: 9)]))
        let layout = try #require(result[1])

        for position in stride(from: 0.0, through: 360, by: 7.5) {
            let expected = layout.placements.filter {
                $0.admittedAtSeconds <= position + 2 && $0.expiresAtSeconds > position
            }
            let queried = layout.placements(at: position, lookahead: 2).filter {
                $0.expiresAtSeconds > position
            }
            #expect(queried == expected)
        }
    }

    /// 前缀稳定（取景框模型的前提）：规划车道更多的表裁到前 N 条车道，与只有 N 条车道的表完全一致。
    ///
    /// 只覆盖不叠放的密度档、单车道高度的弹幕且不触及同屏上限：叠放时 N 条车道的表把溢出的弹幕叠进前 N
    /// 条车道，而车道更多的表把它们放进隐藏车道；多车道弹幕可能跨过可见边界、在隐藏中占住边界车道。
    @Test(arguments: [(360.0, 180.0), (720.0, 200.0), (720.0, 36.0)])
    func moreLanesAgreeWithFewerLanesOnTheSharedPrefix(
        planningHeight: Double,
        windowHeight: Double
    ) throws {
        let events = denseEvents(segment: 1, count: 1_200, seed: 13)
        let planned = try #require(
            layouts(
                [1: events],
                configuration: BiliDanmakuTests.configuration(planningHeight: planningHeight)
            )?[1]?.placements
        )
        let direct = try #require(
            layouts(
                [1: events],
                configuration: BiliDanmakuTests.configuration(planningHeight: windowHeight)
            )?[1]?.placements
        )
        let viewport = BiliDanmakuTests.viewport(height: windowHeight)

        #expect(planned.count > direct.count)
        #expect(planned.filter(viewport.showsLanes(of:)) == direct)
    }

    static let configuration = BiliDanmakuTests.configuration()

    private func layouts(
        _ segments: [Int: [DanmakuEvent]],
        reusing existing: [Int: DanmakuSegmentLayout] = [:],
        configuration: DanmakuLaneConfiguration = Self.configuration,
        speedLevel: DanmakuSpeedLevel = .default,
        filter: DanmakuFilter = DanmakuFilter()
    ) -> [Int: DanmakuSegmentLayout]? {
        DanmakuLayoutPlanner.layouts(
            for: segments,
            reusing: existing,
            parameters: DanmakuLayoutParameters(
                configuration: configuration,
                speedLevel: speedLevel,
                backingScale: 2,
                filter: filter
            ),
            measure: fixtureMetrics
        )
    }
}
