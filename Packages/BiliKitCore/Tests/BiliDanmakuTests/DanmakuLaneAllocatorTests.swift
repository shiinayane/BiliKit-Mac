import BiliDanmaku
import BiliModels
import Foundation
import Testing

@Suite
struct DanmakuLaneAllocatorTests {
    @Test
    func threeModesShareDisplayRegionAndPreserveSchedulerOrder() {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        let admission = allocator.admit(
            [
                request(id: "top", time: 1, mode: .top),
                request(id: "bottom", time: 2, mode: .bottom),
                request(id: "scroll", time: 2, mode: .scrolling),
            ],
            at: 3
        )

        #expect(admission.dropCounts.total == 0)
        #expect(
            admission.admitted.map(\.request.event.id)
                == ["top", "bottom", "scroll"]
        )
        #expect(admission.admitted.map(\.originY) == [0, 40, 0])
    }

    @Test
    func modesCanOverlapWhileSameModeStillOccupiesItsLane() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(surfaceHeight: 20)
        )
        let admission = allocator.admit(
            [
                request(id: "top", mode: .top),
                request(id: "scroll", mode: .scrolling),
                request(id: "bottom", mode: .bottom),
                request(id: "top-blocked", mode: .top),
                request(id: "bottom-blocked", mode: .bottom),
            ],
            at: 0
        )

        #expect(
            admission.admitted.map(\.request.event.id)
                == ["top", "scroll", "bottom"]
        )
        #expect(admission.admitted.map(\.originY) == [0, 0, 0])
        #expect(admission.dropCounts.noLane == 2)
    }

    @Test
    func scrollingLaneRejectsUnsafeEntryAndCatchUp() throws {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(surfaceHeight: 20)
        )
        let first = allocator.admit(
            [request(id: "first", width: 400)],
            at: 0
        )
        #expect(first.admitted.count == 1)

        let tooEarly = allocator.admit(
            [request(id: "early", width: 100)],
            at: 1
        )
        #expect(tooEarly.dropCounts.noLane == 1)

        _ = allocator.clear()
        _ = allocator.admit(
            [request(id: "slow", width: 100)],
            at: 0
        )
        let catchesUp = allocator.admit(
            [request(id: "fast", width: 600)],
            at: 2
        )
        #expect(catchesUp.dropCounts.noLane == 1)

        let safe = allocator.admit(
            [request(id: "safe", width: 100)],
            at: 4
        )
        #expect(safe.admitted.map(\.request.event.id) == ["safe"])
    }

    @Test
    func fixedLaneRemainsOccupiedUntilExpiration() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(surfaceHeight: 20)
        )
        _ = allocator.admit(
            [request(id: "first", mode: .top, duration: 4)],
            at: 0
        )

        let occupied = allocator.admit(
            [request(id: "blocked", mode: .top, duration: 4)],
            at: 3.9
        )
        #expect(occupied.dropCounts.noLane == 1)

        let expired = allocator.admit(
            [request(id: "next", mode: .top, duration: 4)],
            at: 4
        )
        #expect(expired.expired.map(\.request.event.id) == ["first"])
        #expect(expired.admitted.map(\.request.event.id) == ["next"])
    }

    @Test
    func scrollingLaneCanBeReusedImmediatelyAfterAutomaticExpiration() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(surfaceHeight: 20)
        )
        _ = allocator.admit(
            [request(id: "first", duration: 2)],
            at: 0
        )

        let next = allocator.admit(
            [request(id: "next", duration: 2)],
            at: 2
        )

        #expect(next.expired.map(\.request.event.id) == ["first"])
        #expect(next.admitted.map(\.request.event.id) == ["next"])
        #expect(next.dropCounts.total == 0)
    }

    @Test
    func capacityRejectsBeforeAdmissionAndNeverQueues() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(maximumActiveCount: 2)
        )
        let admission = allocator.admit(
            [
                request(id: "a", time: 1, mode: .top),
                request(id: "b", time: 2, mode: .scrolling),
                request(id: "c", time: 3, mode: .bottom),
            ],
            at: 3
        )

        #expect(
            admission.admitted.map(\.request.event.id) == ["a", "b"]
        )
        #expect(admission.dropCounts.capacity == 1)
        #expect(admission.dropCounts.total == 1)
        #expect(allocator.activeCount == 2)
        #expect(allocator.peakActiveCount == 2)

        let removed = allocator.remove(eventID: "a")
        #expect(removed?.request.event.id == "a")
        #expect(allocator.activeCount == 1)
        #expect(allocator.peakActiveCount == 2)
        #expect(allocator.remove(eventID: "missing") == nil)
    }

    @Test
    func hardLimitNeverAdmitsMoreThanSixHundredForty() {
        let maximumActiveCount = 640
        let surfaceHeight = Double(maximumActiveCount * 20)
        var allocator = DanmakuLaneAllocator(
            configuration: DanmakuLaneConfiguration(
                surfaceWidth: 1_000,
                surfaceHeight: surfaceHeight,
                laneHeight: 20,
                minimumHorizontalGap: 20,
                maximumActiveCount: maximumActiveCount,
                displayAreaFraction: 1
            )
        )
        let requests = (0...maximumActiveCount).map {
            request(id: String(format: "%04d", $0), mode: .top)
        }

        let admission = allocator.admit(requests, at: 0)

        #expect(admission.admitted.count == maximumActiveCount)
        #expect(admission.dropCounts.capacity == 1)
        #expect(admission.dropCounts.total == 1)
        #expect(allocator.activeCount == maximumActiveCount)
        #expect(allocator.peakActiveCount == maximumActiveCount)
    }

    @Test
    func invalidGeometryHardLimitAndResizeStayBounded() {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        _ = allocator.admit([request(id: "active")], at: 0)
        let tooTall = allocator.admit(
            [request(id: "tall", height: 21)],
            at: 0
        )
        #expect(tooTall.dropCounts.invalidRequest == 1)

        let drained = allocator.updateConfiguration(
            configuration(surfaceWidth: 0)
        )
        #expect(drained.map(\.request.event.id) == ["active"])
        #expect(allocator.activeCount == 0)
        let unavailable = allocator.admit(
            [request(id: "unavailable")],
            at: 1
        )
        #expect(unavailable.dropCounts.invalidRequest == 1)

        _ = allocator.updateConfiguration(
            configuration(
                maximumActiveCount:
                    DanmakuLaneConfiguration.hardMaximumActiveCount + 1
            )
        )
        let overHardLimit = allocator.admit(
            [request(id: "over-limit")],
            at: 2
        )
        #expect(overHardLimit.dropCounts.invalidRequest == 1)
        #expect(allocator.activeCount == 0)

        _ = allocator.updateConfiguration(
            configuration(displayAreaFraction: 1.01)
        )
        let invalidCoverage = allocator.admit(
            [request(id: "invalid-coverage")],
            at: 3
        )
        #expect(invalidCoverage.dropCounts.invalidRequest == 1)
        #expect(allocator.activeCount == 0)
    }

    @Test
    func explicitRemoveReleasesFixedAndScrollingLanes() {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        _ = allocator.admit(
            [
                request(id: "top", mode: .top),
                request(id: "scroll", mode: .scrolling),
            ],
            at: 0
        )

        #expect(allocator.remove(eventID: "top") != nil)
        #expect(allocator.remove(eventID: "scroll") != nil)
        let reused = allocator.admit(
            [
                request(id: "top-next", mode: .top),
                request(id: "scroll-next", mode: .scrolling),
            ],
            at: 0.1
        )

        #expect(reused.dropCounts.total == 0)
        #expect(
            reused.admitted.map(\.request.event.id)
                == ["top-next", "scroll-next"]
        )
    }

    @Test
    func displayAreaFractionMirrorsBottomFromSurfaceEdge() {
        let cases: [(fraction: Double, expectedTop: [Double],
                     expectedBottom: [Double])] = [
            (0.5, [0, 20], [60, 40]),
            (0.75, [0, 20, 40], [60, 40, 20]),
            (1, [0, 20, 40, 60], [60, 40, 20, 0]),
        ]

        for testCase in cases {
            var allocator = DanmakuLaneAllocator(
                configuration: configuration(
                    surfaceHeight: 80,
                    displayAreaFraction: testCase.fraction
                )
            )
            let top = allocator.admit(
                testCase.expectedTop.indices.map {
                    request(id: "top-\($0)", mode: .top)
                },
                at: 0
            )
            let bottom = allocator.admit(
                testCase.expectedBottom.indices.map {
                    request(id: "bottom-\($0)", mode: .bottom)
                },
                at: 0
            )

            #expect(top.admitted.map(\.originY) == testCase.expectedTop)
            #expect(
                bottom.admitted.map(\.originY)
                    == testCase.expectedBottom
            )
            #expect(top.dropCounts.total == 0)
            #expect(bottom.dropCounts.total == 0)
        }
    }

    private func configuration(
        surfaceWidth: Double = 1_000,
        surfaceHeight: Double = 60,
        maximumActiveCount: Int = 640,
        displayAreaFraction: Double = 1
    ) -> DanmakuLaneConfiguration {
        DanmakuLaneConfiguration(
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight,
            laneHeight: 20,
            minimumHorizontalGap: 20,
            maximumActiveCount: maximumActiveCount,
            displayAreaFraction: displayAreaFraction
        )
    }

    private func request(
        id: String,
        time: Double = 0,
        mode: DanmakuPresentationMode = .scrolling,
        width: Double = 100,
        height: Double = 20,
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
                weight: 5
            ),
            width: width,
            height: height,
            durationSeconds: duration
        )
    }
}
