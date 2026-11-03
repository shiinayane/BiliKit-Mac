import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定车道准入的契约：三种模式共享显示区域、各占自己的车道；滚动弹幕不追尾，顶部底部独占槽位直到
/// 到期；高文本占连续车道；允许叠放时先用不叠放的车道再逐层叠放；同屏上限按准入顺序拒绝；显示区域按比例
/// 限制车道数；两份占用是否等价只看活动 placement 与滚动槽位的尾巴。
@Suite
struct DanmakuLaneAllocatorTests {
    @Test
    func modesCanOverlapWhileSameModeStillOccupiesItsLane() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(planningHeight: 36)
        )
        let admission = admit(
            &allocator,
            [
                request(id: "top", mode: .top),
                request(id: "scroll", mode: .scrolling),
                request(id: "bottom", mode: .bottom),
                request(id: "top-blocked", mode: .top),
                request(id: "bottom-blocked", mode: .bottom)
            ],
            at: 0
        )

        #expect(
            admission.map(\.request.event.id)
                == ["top", "scroll", "bottom"]
        )
        #expect(admission.map(\.edgeOffset) == [0, 0, 0])
    }

    @Test
    func scrollingReusesFirstSafeLaneBeforeOpeningAnotherVerticalLane() {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        _ = admit(&allocator, [request(id: "first")], at: 0)

        let second = admit(&allocator, [request(id: "second")], at: 4)
        let third = admit(&allocator, [request(id: "third")], at: 4)

        #expect(second.map(\.laneIndex) == [0])
        #expect(third.map(\.laneIndex) == [1])
        #expect(second.map(\.overlapDepth) == [0])
        #expect(third.map(\.overlapDepth) == [0])
    }

    @Test
    func overlappingScrollingUsesSafeVerticalLaneBeforeAnotherDepth() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(
                planningHeight: 72,
                maximumOverlapDepth: 3
            )
        )
        let initial = admit(
            &allocator,
            [
                request(id: "lane-0"),
                request(id: "lane-1"),
                request(id: "slow-overlap", duration: 20)
            ],
            at: 0
        )

        #expect(initial.map(\.laneIndex) == [0, 1, 0])
        #expect(initial.map(\.overlapDepth) == [0, 0, 1])

        let next = admit(&allocator, [request(id: "next")], at: 4)

        #expect(next.map(\.laneIndex) == [1])
        #expect(next.map(\.overlapDepth) == [0])
    }

    @Test
    func overlappingFixedDanmakuFillsEveryLaneBeforeNextDepth() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(maximumOverlapDepth: 3)
        )
        let admission = admit(
            &allocator,
            (0..<7).map {
                request(id: "top-\($0)", mode: .top)
            },
            at: 0
        )

        #expect(admission.map(\.laneIndex) == [0, 1, 2, 0, 1, 2, 0])
        #expect(admission.map(\.overlapDepth) == [0, 0, 0, 1, 1, 1, 2])
    }

    @Test
    func scrollingLaneRejectsUnsafeEntryAndCatchUp() throws {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(planningHeight: 36)
        )
        let first = admit(
            &allocator,
            [request(id: "first", width: 400)],
            at: 0
        )
        #expect(first.count == 1)

        let tooEarly = admit(
            &allocator,
            [request(id: "early", width: 100)],
            at: 1
        )
        #expect(tooEarly.isEmpty)

        allocator = DanmakuLaneAllocator(
            configuration: configuration(planningHeight: 36)
        )
        _ = admit(
            &allocator,
            [request(id: "slow", width: 100)],
            at: 0
        )
        let catchesUp = admit(
            &allocator,
            [request(id: "fast", width: 600)],
            at: 2
        )
        #expect(catchesUp.isEmpty)

        let safe = admit(
            &allocator,
            [request(id: "safe", width: 100)],
            at: 4
        )
        #expect(safe.map(\.request.event.id) == ["safe"])
    }

    @Test
    func fixedLaneRemainsOccupiedUntilExpiration() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(planningHeight: 36)
        )
        _ = admit(
            &allocator,
            [request(id: "first", mode: .top, duration: 4)],
            at: 0
        )

        let occupied = admit(
            &allocator,
            [request(id: "blocked", mode: .top, duration: 4)],
            at: 3.9
        )
        #expect(occupied.isEmpty)

        let afterExpiry = admit(
            &allocator,
            [request(id: "next", mode: .top, duration: 4)],
            at: 4
        )
        #expect(afterExpiry.map(\.request.event.id) == ["next"])
    }

    @Test
    func scrollingLaneCanBeReusedImmediatelyAfterAutomaticExpiration() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(planningHeight: 36)
        )
        _ = admit(
            &allocator,
            [request(id: "first", duration: 2)],
            at: 0
        )

        let next = admit(
            &allocator,
            [request(id: "next", duration: 2)],
            at: 2
        )

        #expect(next.map(\.request.event.id) == ["next"])
    }

    /// 同屏上限：到上限后按准入顺序拒绝、不排队，到期回收之后才有空位。
    @Test
    func capacityRejectsBeforeAdmissionAndNeverQueues() {
        let maximum = DanmakuLaneConfiguration.hardMaximumActiveCount
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(
                planningHeight: DanmakuLaneConfiguration.laneHeight * Double(maximum + 10)
            )
        )
        let admission = admit(
            &allocator,
            (0...maximum).map { request(id: "top-\($0)", time: 3, mode: .top) },
            at: 3
        )
        #expect(admission.count == maximum)
        #expect(admission.last?.request.event.id == "top-\(maximum - 1)")

        let afterExpiry = admit(
            &allocator,
            [request(id: "later", time: 12, mode: .top)],
            at: 12
        )
        #expect(afterExpiry.map(\.request.event.id) == ["later"])
    }

    @Test
    func extremeFiniteHeightCapsLaneCountBeforeIntegerConversion() {
        let maximumActiveCount =
            DanmakuLaneConfiguration.hardMaximumActiveCount
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(planningHeight: .greatestFiniteMagnitude)
        )
        let requests = (0...maximumActiveCount).map {
            request(id: "extreme-\($0)", mode: .top, height: 1)
        }

        let admission = admit(&allocator, requests, at: 0)

        #expect(admission.count == maximumActiveCount)
    }

    @Test
    func extremeFiniteRequestHeightDoesNotOverflowLaneSpanConversion() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(planningHeight: .greatestFiniteMagnitude)
        )

        let admission = admit(
            &allocator,
            [request(id: "extreme-span", height: .greatestFiniteMagnitude)],
            at: 0
        )

        #expect(admission.isEmpty)
    }

    @Test(arguments: [DanmakuPresentationMode.top, .scrolling])
    func tallRequestsOccupyAdjacentLanesWithoutReducingSmallTextDensity(
        mode: DanmakuPresentationMode
    ) {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        let admission = admit(
            &allocator,
            [
                request(id: "large", mode: mode, height: 71),
                request(id: "small", mode: mode, height: 32),
                request(id: "blocked-large", mode: mode, height: 71)
            ],
            at: 0
        )

        #expect(admission.map(\.request.event.id) == ["large", "small"])
        #expect(admission.map(\.laneIndex) == [0, 2])
        #expect(admission.map(\.edgeOffset) == [0, 72])
    }

    @Test(arguments: [DanmakuPresentationMode.top, .scrolling])
    func expiringTallRequestFreesEveryOccupiedLane(mode: DanmakuPresentationMode) {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        _ = admit(
            &allocator,
            [
                request(id: "large", mode: mode, height: 71, duration: 1),
                request(id: "small", mode: mode, height: 32, duration: 10)
            ],
            at: 0
        )
        let reused = admit(
            &allocator,
            [request(id: "large-next", mode: mode, height: 71)],
            at: 1
        )

        #expect(reused.map(\.request.event.id) == ["large-next"])
        #expect(reused.first?.laneIndex == 0)
    }

    @Test
    func tallBottomRequestSitsOnTheBottomEdge() throws {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        let admission = admit(
            &allocator,
            [request(id: "large-bottom", mode: .bottom, height: 71)],
            at: 0
        )

        let placement = try #require(admission.first)
        #expect(placement.laneIndex == 0)
        #expect(placement.laneSpan == 2)
        #expect(placement.edgeOffset == 0)
    }

    /// 顶部弹幕从顶边往下、底部弹幕从底边往上，各自数到显示区域的车道数为止。
    @Test(
        arguments: [
            (0.5, [0, 36]),
            (0.75, [0, 36, 72]),
            (1, [0, 36, 72, 108])
        ] as [(Double, [Double])]
    )
    func displayAreaFractionLimitsLanesFromEachEdge(
        fraction: Double,
        expectedOffsets: [Double]
    ) {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(
                planningHeight: 144,
                displayAreaFraction: fraction
            )
        )
        let top = admit(
            &allocator,
            (0...expectedOffsets.count).map { request(id: "top-\($0)", mode: .top) },
            at: 0
        )
        let bottom = admit(
            &allocator,
            (0...expectedOffsets.count).map {
                request(id: "bottom-\($0)", mode: .bottom)
            },
            at: 0
        )

        #expect(top.map(\.edgeOffset) == expectedOffsets)
        #expect(bottom.map(\.edgeOffset) == expectedOffsets)
    }

    @Test(arguments: DanmakuDisplayArea.allCases)
    func displayAreaLevelLimitsAvailableLaneCount(area: DanmakuDisplayArea) {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(
                planningHeight: 720,
                displayAreaFraction: area.fraction
            )
        )
        let admission = admit(
            &allocator,
            (0..<20).map { request(id: "\(area.rawValue)-\($0)", mode: .top) },
            at: 0
        )

        #expect(admission.count == area.rawValue / 5)
    }

    /// 两份占用等价：同样的活动 placement 与滚动尾巴；任一条到期时间不同就不等价，到期之后又等价。
    @Test
    func sameOccupancyComparesActivePlacementsAndScrollingTails() {
        var first = DanmakuLaneAllocator(configuration: configuration())
        var second = DanmakuLaneAllocator(configuration: configuration())
        _ = admit(&first, [request(id: "a"), request(id: "b", mode: .top)], at: 0)
        _ = admit(&second, [request(id: "a"), request(id: "b", mode: .top)], at: 0)
        #expect(first.hasSameOccupancy(as: second))

        var longer = DanmakuLaneAllocator(configuration: configuration())
        _ = admit(&longer, [request(id: "a", duration: 9), request(id: "b", mode: .top)], at: 0)
        #expect(!first.hasSameOccupancy(as: longer))

        _ = admit(&first, [request(id: "c", mode: .bottom)], at: 10)
        _ = admit(&longer, [request(id: "c", mode: .bottom)], at: 10)
        #expect(first.hasSameOccupancy(as: longer))
    }

    /// 逐条准入，返回被准入的 placement。
    private func admit(
        _ allocator: inout DanmakuLaneAllocator,
        _ requests: [DanmakuLaneRequest],
        at time: Double
    ) -> [DanmakuLanePlacement] {
        requests.compactMap { allocator.admit($0, at: time) }
    }

    /// 1000pt 宽、20pt 间距；默认高 108pt，即三条车道。
    private func configuration(
        planningWidth: Double = 1_000,
        planningHeight: Double = 108,
        displayAreaFraction: Double = 1,
        maximumOverlapDepth: Int = 1
    ) -> DanmakuLaneConfiguration {
        DanmakuLaneConfiguration(
            planningWidth: planningWidth,
            planningHeight: planningHeight,
            minimumHorizontalGap: 20,
            displayAreaFraction: displayAreaFraction,
            maximumOverlapDepth: maximumOverlapDepth
        )
    }

    private func request(
        id: String,
        time: Double = 0,
        mode: DanmakuPresentationMode = .scrolling,
        width: Double = 100,
        height: Double = 36,
        duration: Double = 8
    ) -> DanmakuLaneRequest {
        DanmakuLaneRequest(
            event: DanmakuEvent(
                id: id,
                timeSeconds: time,
                mode: mode,
                text: "fixture",
                fontSize: 24,
                colorRGB: 0xFF_FF_FF,
                colorStyle: .solid,
                weight: 5,
                isHighLike: false,
                isUploader: false
            ),
            width: width,
            height: height,
            durationSeconds: duration,
            countBadge: nil
        )
    }
}
