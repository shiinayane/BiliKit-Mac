import BiliApplication
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
    func scrollingReusesFirstSafeLaneBeforeOpeningAnotherVerticalLane() {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        _ = allocator.admit([request(id: "first")], at: 0)

        let second = allocator.admit([request(id: "second")], at: 4)
        let third = allocator.admit([request(id: "third")], at: 4)

        #expect(second.admitted.map(\.laneIndex) == [0])
        #expect(third.admitted.map(\.laneIndex) == [1])
        #expect(second.admitted.map(\.overlapDepth) == [0])
        #expect(third.admitted.map(\.overlapDepth) == [0])
    }

    @Test
    func overlappingScrollingUsesSafeVerticalLaneBeforeAnotherDepth() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(
                surfaceHeight: 40,
                maximumOverlapDepth: 3
            )
        )
        let initial = allocator.admit(
            [
                request(id: "lane-0"),
                request(id: "lane-1"),
                request(id: "slow-overlap", duration: 20),
            ],
            at: 0
        )

        #expect(initial.admitted.map(\.laneIndex) == [0, 1, 0])
        #expect(initial.admitted.map(\.overlapDepth) == [0, 0, 1])

        let next = allocator.admit([request(id: "next")], at: 4)

        #expect(next.dropCounts.total == 0)
        #expect(next.admitted.map(\.laneIndex) == [1])
        #expect(next.admitted.map(\.overlapDepth) == [0])
    }

    @Test
    func reducingOverlapDepthStillChecksEveryActiveScrollingTail() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(
                surfaceHeight: 20,
                maximumOverlapDepth: 3
            )
        )
        let overlapping = allocator.admit(
            [
                request(id: "fast", duration: 8),
                request(id: "slow", duration: 20),
            ],
            at: 0
        )

        #expect(overlapping.admitted.map(\.overlapDepth) == [0, 1])

        allocator.updateConfiguration(
            configuration(surfaceHeight: 20, maximumOverlapDepth: 1)
        )
        let blockedByOldDepth = allocator.admit(
            [request(id: "blocked", duration: 8)],
            at: 4
        )

        #expect(blockedByOldDepth.admitted.isEmpty)
        #expect(blockedByOldDepth.dropCounts.noLane == 1)

        let recovered = allocator.admit(
            [request(id: "recovered", duration: 8)],
            at: 20
        )

        #expect(
            recovered.expired.map(\.request.event.id).sorted()
                == ["fast", "slow"]
        )
        #expect(recovered.admitted.map(\.request.event.id) == ["recovered"])
        #expect(recovered.admitted.map(\.overlapDepth) == [0])
    }

    @Test
    func overlappingFixedDanmakuFillsEveryLaneBeforeNextDepth() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(maximumOverlapDepth: 3)
        )
        let admission = allocator.admit(
            (0..<7).map {
                request(id: "top-\($0)", mode: .top)
            },
            at: 0
        )

        #expect(admission.dropCounts.total == 0)
        #expect(admission.admitted.map(\.laneIndex) == [0, 1, 2, 0, 1, 2, 0])
        #expect(admission.admitted.map(\.overlapDepth) == [0, 0, 0, 1, 1, 1, 2])
    }

    @Test
    func nonOverlappingDensityRejectsAfterAllFixedLanesAreOccupied() {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        let admission = allocator.admit(
            (0..<4).map {
                request(id: "top-\($0)", mode: .top)
            },
            at: 0
        )

        #expect(admission.admitted.map(\.laneIndex) == [0, 1, 2])
        #expect(admission.admitted.map(\.overlapDepth) == [0, 0, 0])
        #expect(admission.dropCounts.noLane == 1)
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
    func extremeFiniteHeightCapsLaneCountBeforeIntegerConversion() {
        let maximumActiveCount =
            DanmakuLaneConfiguration.hardMaximumActiveCount
        var allocator = DanmakuLaneAllocator(
            configuration: DanmakuLaneConfiguration(
                surfaceWidth: 1_000,
                surfaceHeight: .greatestFiniteMagnitude,
                laneHeight: 1,
                minimumHorizontalGap: 12,
                maximumActiveCount: maximumActiveCount,
                displayAreaFraction: 1
            )
        )
        let requests = (0...maximumActiveCount).map {
            request(id: "extreme-\($0)", mode: .top, height: 1)
        }

        let admission = allocator.admit(requests, at: 0)

        #expect(admission.admitted.count == maximumActiveCount)
        #expect(admission.dropCounts.capacity == 1)
        #expect(allocator.activeCount == maximumActiveCount)
    }

    @Test
    func extremeFiniteRequestHeightDoesNotOverflowLaneSpanConversion() {
        var allocator = DanmakuLaneAllocator(
            configuration: DanmakuLaneConfiguration(
                surfaceWidth: 1_000,
                surfaceHeight: .greatestFiniteMagnitude,
                laneHeight: .leastNonzeroMagnitude,
                minimumHorizontalGap: 12,
                maximumActiveCount: 1,
                displayAreaFraction: 1
            )
        )

        let admission = allocator.admit(
            [request(id: "extreme-span", height: .greatestFiniteMagnitude)],
            at: 0
        )

        #expect(admission.admitted.isEmpty)
        #expect(admission.dropCounts.noLane == 1)
    }

    @Test
    func invalidGeometryHardLimitAndResizeStayBounded() {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        _ = allocator.admit([request(id: "active")], at: 0)
        let tooTall = allocator.admit(
            [request(id: "tall", height: 61)],
            at: 0
        )
        #expect(tooTall.dropCounts.noLane == 1)

        allocator.updateConfiguration(
            configuration(surfaceWidth: 0)
        )
        #expect(allocator.activeCount == 1)
        let unavailable = allocator.admit(
            [request(id: "unavailable")],
            at: 1
        )
        #expect(unavailable.dropCounts.invalidRequest == 1)
        #expect(allocator.activeCount == 1)

        allocator.updateConfiguration(
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
        #expect(allocator.activeCount == 1)

        allocator.updateConfiguration(
            configuration(displayAreaFraction: 1.01)
        )
        let invalidCoverage = allocator.admit(
            [request(id: "invalid-coverage")],
            at: 3
        )
        #expect(invalidCoverage.dropCounts.invalidRequest == 1)
        #expect(allocator.activeCount == 1)

        allocator.updateConfiguration(configuration())
        let recovered = allocator.admit(
            [request(id: "recovered")],
            at: 8
        )
        #expect(recovered.expired.map(\.request.event.id) == ["active"])
        #expect(recovered.admitted.map(\.request.event.id) == ["recovered"])
    }

    @Test
    func tallRequestsOccupyAdjacentLanesWithoutReducingSmallTextDensity() {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        let admission = allocator.admit(
            [
                request(id: "large", mode: .top, height: 39),
                request(id: "small", mode: .top, height: 18),
                request(id: "blocked", mode: .top, height: 18),
            ],
            at: 0
        )

        #expect(admission.admitted.map(\.request.event.id) == ["large", "small"])
        #expect(admission.admitted.map(\.laneIndex) == [0, 2])
        #expect(admission.admitted.map(\.originY) == [0, 40])
        #expect(admission.dropCounts.noLane == 1)
    }

    @Test
    func tallScrollingRequestChecksEveryAdjacentLaneForCollision() {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        let admission = allocator.admit(
            [
                request(id: "large", height: 39),
                request(id: "small", height: 18),
                request(id: "blocked-large", height: 39),
            ],
            at: 0
        )

        #expect(admission.admitted.map(\.request.event.id) == ["large", "small"])
        #expect(admission.admitted.map(\.laneIndex) == [0, 2])
        #expect(admission.dropCounts.noLane == 1)
    }

    @Test
    func removingTallFixedRequestReleasesEveryOccupiedLane() {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        _ = allocator.admit(
            [
                request(id: "large", mode: .top, height: 39),
                request(id: "small", mode: .top, height: 18),
            ],
            at: 0
        )

        #expect(allocator.remove(eventID: "large") != nil)
        let reused = allocator.admit(
            [request(id: "large-next", mode: .top, height: 39)],
            at: 0.1
        )

        #expect(reused.admitted.map(\.request.event.id) == ["large-next"])
        #expect(reused.admitted.first?.laneIndex == 0)
        #expect(reused.dropCounts.total == 0)
    }

    @Test
    func expiringTallScrollingRequestReleasesEveryOccupiedLane() {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        _ = allocator.admit(
            [
                request(id: "large", height: 39, duration: 1),
                request(id: "small", height: 18, duration: 10),
            ],
            at: 0
        )
        let reused = allocator.admit(
            [request(id: "large-next", height: 39)],
            at: 1
        )

        #expect(reused.expired.map(\.request.event.id) == ["large"])
        #expect(reused.admitted.map(\.request.event.id) == ["large-next"])
        #expect(reused.admitted.first?.laneIndex == 0)
        #expect(reused.dropCounts.total == 0)
    }

    @Test
    func tallBottomRequestUsesItsMeasuredHeightFromSurfaceEdge() throws {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        let admission = allocator.admit(
            [request(id: "large-bottom", mode: .bottom, height: 39)],
            at: 0
        )

        let placement = try #require(admission.admitted.first)
        #expect(placement.laneIndex == 0)
        #expect(placement.originY == 21)
        #expect(placement.originY + placement.request.height == 60)
    }

    @Test
    func resizePreservesActiveAndUsesEachAdmissionWidthForCollision() throws {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(
                surfaceWidth: 800,
                surfaceHeight: 20
            )
        )
        let first = allocator.admit(
            [request(id: "old-surface", duration: 10)],
            at: 0
        )
        #expect(first.admitted.count == 1)
        #expect(first.admitted.first?.surfaceWidthAtAdmission == 800)

        allocator.updateConfiguration(
            configuration(
                surfaceWidth: 1_200,
                surfaceHeight: 20
            )
        )
        #expect(allocator.activeCount == 1)

        let following = allocator.admit(
            [request(id: "new-surface", duration: 20)],
            at: 0.2
        )
        let placement = try #require(following.admitted.first)
        #expect(following.dropCounts.total == 0)
        #expect(placement.surfaceWidthAtAdmission == 1_200)
        #expect(placement.laneIndex == first.admitted.first?.laneIndex)
        #expect(allocator.activeCount == 2)
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
        let cases:
            [(
                fraction: Double, expectedTop: [Double],
                expectedBottom: [Double]
            )] = [
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

    @Test
    func fiveDisplayAreaLevelsLimitAvailableLaneCount() {
        for area in DanmakuDisplayArea.allCases {
            var allocator = DanmakuLaneAllocator(
                configuration: configuration(
                    surfaceHeight: 400,
                    displayAreaFraction: area.fraction
                )
            )
            let admission = allocator.admit(
                (0..<20).map {
                    request(id: "\(area.rawValue)-\($0)", mode: .top)
                },
                at: 0
            )

            #expect(admission.admitted.count == area.rawValue / 5)
            #expect(admission.dropCounts.noLane == 20 - area.rawValue / 5)
        }
    }

    private func configuration(
        surfaceWidth: Double = 1_000,
        surfaceHeight: Double = 60,
        maximumActiveCount: Int = 640,
        displayAreaFraction: Double = 1,
        maximumOverlapDepth: Int = 1
    ) -> DanmakuLaneConfiguration {
        DanmakuLaneConfiguration(
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight,
            laneHeight: 20,
            minimumHorizontalGap: 20,
            maximumActiveCount: maximumActiveCount,
            displayAreaFraction: displayAreaFraction,
            maximumOverlapDepth: maximumOverlapDepth
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
