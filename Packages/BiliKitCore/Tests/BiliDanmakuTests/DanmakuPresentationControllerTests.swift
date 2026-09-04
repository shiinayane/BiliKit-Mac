import AppKit
import BiliApplication
import BiliModels
import CoreText
import QuartzCore
import Testing

@testable import BiliDanmaku

private final class RasterizationStartProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private var count = 0

    func recordStart() {
        lock.withLock { count += 1 }
        started.signal()
    }

    func waitForStart(timeout: DispatchTime) -> DispatchTimeoutResult {
        started.wait(timeout: timeout)
    }

    var startCount: Int {
        lock.withLock { count }
    }
}

@MainActor
@Suite
struct DanmakuPresentationControllerTests {
    @Test
    func productionVisualDefaultsAreSingleSourceAndBounded() {
        #expect(
            CoreAnimationDanmakuStyle.production
                == CoreAnimationDanmakuStyle(
                    fontScale: 1,
                    fontWeight: .semibold,
                    shadowBlurRadius: 1
                )
        )

        let bounded = CoreAnimationDanmakuStyle(
            fontScale: 99,
            fontWeight: .bold,
            shadowBlurRadius: -99
        )
        #expect(bounded.fontScale == CoreAnimationDanmakuStyle.fontScaleRange.upperBound)
        #expect(bounded.fontWeight == .bold)
        #expect(
            bounded.shadowBlurRadius
                == CoreAnimationDanmakuStyle.shadowBlurRadiusRange.lowerBound
        )

        let nonfinite = CoreAnimationDanmakuStyle(
            fontScale: .nan,
            fontWeight: .regular,
            shadowBlurRadius: .infinity
        )
        #expect(nonfinite.fontScale == 1)
        #expect(nonfinite.fontWeight == .regular)
        #expect(nonfinite.shadowBlurRadius == 1)

        let laneConfiguration = DanmakuLaneConfiguration.production(
            surfaceWidth: 1_280,
            surfaceHeight: 720
        )
        #expect(laneConfiguration.laneHeight == 36)
        #expect(laneConfiguration.minimumHorizontalGap == 64)
        #expect(
            laneConfiguration.maximumActiveCount
                == DanmakuLaneConfiguration.hardMaximumActiveCount
        )
        #expect(laneConfiguration.displayAreaFraction == 1)
        #expect(laneConfiguration.maximumOverlapDepth == 1)
    }

    @Test
    func densityPoliciesMatchProductionSpacingAndOverlapDepths() {
        let policies = DanmakuDensity.allCases.map(
            DanmakuDensityAdmissionPolicy.init
        )

        #expect(policies.map(\.minimumHorizontalGap) == [64, 32, 0])
        #expect(policies.map(\.maximumOverlapDepth) == [1, 1, 3])
    }

    @Test
    func displayAreaAndDensityChangesPreserveActiveAndAffectNewAdmissions() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 20)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1DensityFixture", cid: 1)

        controller.setDensity(.overlapping)
        controller.setDisplayArea(.half)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: (0..<11).map {
                    event(id: "half-\($0)", mode: .top)
                }
            )
        )

        #expect(controller.statistics.active == 5)
        #expect(controller.statistics.droppedNoLane == 6)
        #expect(backend.renderedPlacements.map(\.overlapDepth) == [0, 0, 0, 0, 0])

        let clearCount = backend.clearCount
        controller.setDisplayArea(.full)
        #expect(backend.clearCount == clearCount)
        #expect(controller.statistics.active == 5)
        controller.apply(
            update(
                identity: identity,
                position: 2,
                generation: 1,
                events: (0..<6).map {
                    event(id: "full-\($0)", mode: .top)
                }
            )
        )

        #expect(controller.statistics.active == 11)
        #expect(Array(backend.renderedPlacements.suffix(6)).map(\.laneIndex) == [5, 6, 7, 8, 9, 0])
        #expect(
            Array(backend.renderedPlacements.suffix(6)).map(\.overlapDepth)
                == [0, 0, 0, 0, 0, 1]
        )
    }

    @Test
    func disablingOverlapWaitsForEveryOldScrollingDepthToBecomeSafe() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(
                maximumActiveCount: 20,
                surfaceHeight: 30
            )
        )
        let identity = PlaybackItemIdentity(bvid: "BV1DensityTransition", cid: 1)

        controller.setDensity(.overlapping)
        controller.setSpeedLevel(.five)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [event(id: "fast", mode: .scrolling)]
            )
        )
        controller.setSpeedLevel(.one)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [event(id: "slow-overlap", mode: .scrolling)]
            )
        )

        #expect(backend.renderedPlacements.map(\.overlapDepth) == [0, 1])

        controller.setSpeedLevel(.five)
        controller.setDensity(.normal)
        controller.apply(
            update(
                identity: identity,
                position: 3,
                generation: 1,
                events: [event(id: "blocked", mode: .scrolling)]
            )
        )

        #expect(backend.renderedEventIDs == ["fast", "slow-overlap"])
        #expect(controller.statistics.droppedNoLane == 1)
    }

    @Test
    func reducingDisplayAreaChecksOldScrollingOverlapDepths() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(
                maximumActiveCount: 20,
                surfaceHeight: 60
            )
        )
        let identity = PlaybackItemIdentity(bvid: "BV1AreaTransition", cid: 1)

        controller.setDensity(.overlapping)
        controller.setSpeedLevel(.five)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [
                    event(id: "fast-0", mode: .scrolling),
                    event(id: "fast-1", mode: .scrolling),
                ]
            )
        )
        controller.setSpeedLevel(.one)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [event(id: "slow-overlap", mode: .scrolling)]
            )
        )

        #expect(backend.renderedPlacements.map(\.laneIndex) == [0, 1, 0])
        #expect(backend.renderedPlacements.map(\.overlapDepth) == [0, 0, 1])

        controller.setSpeedLevel(.five)
        controller.setDisplayArea(.half)
        controller.apply(
            update(
                identity: identity,
                position: 3,
                generation: 1,
                events: [event(id: "blocked", mode: .scrolling)]
            )
        )

        #expect(backend.renderedEventIDs == ["fast-0", "fast-1", "slow-overlap"])
        #expect(controller.statistics.droppedNoLane == 1)
    }

    @Test
    func lengthWeightedMotionMatchesFivePointSpeedsAcrossRealViewports() {
        let policy = DanmakuMotionPolicy()
        let levelPointSpeeds = zip(
            DanmakuSpeedLevel.allCases,
            [90.0, 110.0, 130.0, 155.0, 185.0]
        )
        let scenarios = [
            (surfaceWidth: 400.0, textWidth: 100.0),
            (surfaceWidth: 1_100.0, textWidth: 429.0),
            (surfaceWidth: 3_440.0, textWidth: 1_479.0),
        ]

        for scenario in scenarios {
            let lengthFactor =
                1
                + 0.3 * scenario.textWidth / 960
            var actualSpeeds: [Double] = []
            for (level, pointSpeed) in levelPointSpeeds {
                let duration = policy.duration(
                    for: .scrolling,
                    textWidth: scenario.textWidth,
                    surfaceWidth: scenario.surfaceWidth,
                    speedLevel: level
                )
                let actualSpeed =
                    (scenario.surfaceWidth + scenario.textWidth) / duration
                actualSpeeds.append(actualSpeed)
                #expect(abs(actualSpeed - pointSpeed * lengthFactor) < 0.001)
            }
            #expect(
                zip(actualSpeeds, actualSpeeds.dropFirst()).allSatisfy {
                    $0 < $1
                }
            )
        }
    }

    @Test
    func lengthBonusGrowsLinearlyWithoutCap() {
        let policy = DanmakuMotionPolicy()
        let surfaceWidth = 1_100.0

        #expect(policy.maximumLengthBonus == .infinity)

        func speed(textWidth: Double) -> Double {
            let duration = policy.duration(
                for: .scrolling,
                textWidth: textWidth,
                surfaceWidth: surfaceWidth,
                speedLevel: .three
            )
            return (surfaceWidth + textWidth) / duration
        }

        #expect(abs(speed(textWidth: 960) - 169) < 0.001)
        #expect(abs(speed(textWidth: 1_728) - 200.2) < 0.001)
        #expect(abs(speed(textWidth: 4_000) - 292.5) < 0.001)
    }

    @Test
    func explicitLengthBonusCapRemainsAvailableForCompatibility() {
        let policy = DanmakuMotionPolicy(maximumLengthBonus: 0.45)
        let surfaceWidth = 1_100.0

        func speed(textWidth: Double) -> Double {
            let duration = policy.duration(
                for: .scrolling,
                textWidth: textWidth,
                surfaceWidth: surfaceWidth,
                speedLevel: .three
            )
            return (surfaceWidth + textWidth) / duration
        }

        #expect(abs(speed(textWidth: 1_728) - 188.5) < 0.001)
        #expect(abs(speed(textWidth: 4_000) - 188.5) < 0.001)
    }

    @Test
    func durationSafetyBoundsOnlyClampExtremeInputs() {
        let policy = DanmakuMotionPolicy()

        #expect(
            policy.duration(
                for: .scrolling,
                textWidth: 1,
                surfaceWidth: 1,
                speedLevel: .five
            ) == 1.5
        )
        #expect(
            policy.duration(
                for: .scrolling,
                textWidth: 4_000,
                surfaceWidth: 10_000,
                speedLevel: .one
            ) == 60
        )
        #expect(
            policy.duration(
                for: .top,
                textWidth: 123,
                surfaceWidth: 1_100,
                speedLevel: .five
            ) == 4
        )
    }

    @Test
    func speedLevelChangeKeepsExistingPlacementAndSupportsMixedLaneSpeeds() throws {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(
                maximumActiveCount: 4,
                surfaceHeight: 30
            )
        )
        let identity = PlaybackItemIdentity(bvid: "BV1SpeedFixture", cid: 1)

        controller.setSpeedLevel(.five)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [event(id: "level-five", mode: .scrolling)]
            )
        )
        let clearCount = backend.clearCount
        controller.setSpeedLevel(.one)
        #expect(backend.clearCount == clearCount)
        controller.apply(
            update(
                identity: identity,
                position: 2,
                generation: 1,
                events: [event(id: "level-one", mode: .scrolling)]
            )
        )

        let first = try #require(backend.renderedPlacements.first)
        let second = try #require(backend.renderedPlacements.last)
        #expect(backend.renderedPlacements.count == 2)
        #expect(first.request.event.id == "level-five")
        #expect(second.request.event.id == "level-one")
        #expect(first.laneIndex == second.laneIndex)
        #expect(first.expiresAtSeconds > second.admittedAtSeconds)
        #expect(first.request.durationSeconds < second.request.durationSeconds)
    }

    @Test
    func controllerRemovesExpiredBeforeRenderingNewAdmission() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 2),
            durations: DanmakuRendererDurations(
                scrollingSeconds: 1,
                fixedSeconds: 1
            )
        )
        let identity = PlaybackItemIdentity(bvid: "BV1OrderFixture", cid: 1)

        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [event(id: "first", mode: .top)]
            )
        )
        backend.operations.removeAll()

        controller.apply(
            update(
                identity: identity,
                position: 3,
                generation: 1,
                events: [event(id: "second", mode: .top)]
            )
        )

        #expect(
            backend.operations == [
                .rate(1),
                .remove("first"),
                .render("second"),
            ]
        )
        #expect(controller.statistics.active == 1)
    }

    @Test
    func capacityDropDoesNotCreateRendererObjectOrQueue() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 1)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1CapacityFixture", cid: 2)

        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [
                    event(id: "first", mode: .scrolling),
                    event(id: "second", mode: .scrolling),
                ]
            )
        )

        #expect(backend.renderedEventIDs == ["first"])
        #expect(controller.statistics.droppedCapacity == 1)
        #expect(controller.statistics.active == 1)
        #expect(controller.statistics.peakActive == 1)
    }

    @Test
    func burstWorkIsBoundedBeforeTextMeasurement() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 1)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1BurstFixture", cid: 20)
        let events = (0...DanmakuLaneConfiguration.hardMaximumActiveCount).map {
            event(id: "event-\($0)", mode: .scrolling)
        }

        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: events
            )
        )

        #expect(
            backend.measureCount
                == DanmakuLaneConfiguration.hardMaximumActiveCount
        )
        #expect(
            controller.statistics.droppedCapacity
                == DanmakuLaneConfiguration.hardMaximumActiveCount
        )
        #expect(backend.renderedEventIDs.count == 1)
    }

    @Test
    func pendingPreparationQueueIsGloballyBoundedAcrossBatches() {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 640)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1PendingBound", cid: 1)
        let maximum = DanmakuLaneConfiguration.hardMaximumActiveCount

        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: (0..<maximum).map {
                    event(id: "first-\($0)", mode: .scrolling)
                }
            )
        )
        controller.apply(
            update(
                identity: identity,
                position: 2,
                generation: 1,
                events: (0...maximum).map {
                    event(id: "blocked-\($0)", mode: .scrolling)
                }
            )
        )

        #expect(backend.preparationIDs.count == maximum)
        #expect(controller.statistics.droppedCapacity == maximum + 1)
        controller.clearPresentation()
        #expect(controller.statistics.active == 0)
    }

    @Test
    func pauseRateGenerationAndStopRemainSingleSequenceCommands() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 4)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1LifecycleFixture", cid: 3)

        let opacity = DanmakuOpacity(0.45) ?? .fullyOpaque
        controller.setOpacity(opacity)

        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 4,
                state: .paused,
                rate: 0
            )
        )
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 4,
                state: .playing,
                rate: 2
            )
        )
        controller.apply(
            update(
                identity: identity,
                position: 8,
                generation: 5,
                state: .playing,
                rate: 1
            )
        )
        controller.stopPresentation()
        controller.stopPresentation()

        #expect(backend.rates == [0, 2, 1])
        #expect(backend.opacities == [opacity])
        #expect(backend.clearCount == 2)
        #expect(backend.stopCount == 2)
        #expect(controller.statistics.active == 0)
    }

    @Test
    func mismatchedClearBatchCannotClearCurrentGeneration() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 4)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1OldClearFixture", cid: 30)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 8,
                events: [event(id: "current", mode: .top)]
            )
        )
        let clearCount = backend.clearCount
        let staleClear = DanmakuBatch(
            identity: identity,
            discontinuityGeneration: 7,
            events: [],
            clearsExisting: true
        )

        controller.apply(
            DanmakuPresentationUpdate(
                snapshot: PlaybackTimelineSnapshot(
                    identity: identity,
                    positionSeconds: 2,
                    durationSeconds: 100,
                    rate: 1,
                    state: .playing,
                    discontinuityGeneration: 8
                ),
                batch: staleClear
            )
        )

        #expect(backend.clearCount == clearCount)
        #expect(controller.statistics.active == 1)
    }

    @Test
    func surfaceResizePreservesActiveUntilOwnerReplacement() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 1)
        )
        let firstOwner = UUID()
        let replacementOwner = UUID()
        #expect(controller.attachSurface(ownerID: firstOwner))
        let identity = PlaybackItemIdentity(bvid: "BV1SurfaceFixture", cid: 31)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [event(id: "before-detach", mode: .top)]
            )
        )
        #expect(controller.statistics.active == 1)
        let clearCount = backend.clearCount

        #expect(
            !controller.updateSurface(
                width: 0,
                height: 0,
                ownerID: replacementOwner
            )
        )
        #expect(
            controller.updateSurface(
                width: 0,
                height: 0,
                ownerID: firstOwner
            )
        )
        #expect(
            backend.surfaceSizes.last
                == DanmakuTextMetrics(width: 0, height: 0)
        )
        #expect(backend.clearCount == clearCount)
        #expect(controller.statistics.active == 1)
        #expect(
            controller.updateSurface(
                width: 800,
                height: 300,
                ownerID: firstOwner
            )
        )
        #expect(backend.clearCount == clearCount)
        #expect(controller.statistics.active == 1)

        #expect(controller.attachSurface(ownerID: replacementOwner))
        #expect(backend.clearCount == clearCount + 1)
        #expect(controller.statistics.active == 0)
        #expect(!controller.detachSurface(ownerID: firstOwner))
        #expect(backend.clearCount == clearCount + 1)

        controller.apply(
            update(
                identity: identity,
                position: 2,
                generation: 1,
                events: [event(id: "after-attach", mode: .top)]
            )
        )
        #expect(backend.renderedEventIDs.last == "after-attach")
        #expect(controller.statistics.active == 1)
    }

    @Test
    func unionOuterRingDoesNotEnterFillAndMapsHalfPointAtOneAndTwoX() {
        let alpha: [UInt8] = [
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 255, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
        ]
        let oneX = DanmakuTextureRasterizer.outerRing(
            alpha: alpha,
            width: 5,
            height: 5,
            radiusPixels: 0.5
        )
        let twoX = DanmakuTextureRasterizer.outerRing(
            alpha: alpha,
            width: 5,
            height: 5,
            radiusPixels: 1
        )

        #expect(oneX[2 * 5 + 2] == 0)
        #expect(twoX[2 * 5 + 2] == 0)
        #expect(oneX[2 * 5 + 1] == 128)
        #expect(twoX[2 * 5 + 1] == 255)
        #expect(oneX[1 * 5 + 1] == 128)
        #expect(twoX[1 * 5 + 1] == 255)

        let adjacent: [UInt8] = [
            0, 0, 0, 0, 0,
            0, 255, 255, 255, 0,
            0, 0, 0, 0, 0,
        ]
        let union = DanmakuTextureRasterizer.outerRing(
            alpha: adjacent,
            width: 5,
            height: 3,
            radiusPixels: 1
        )
        #expect(union[1 * 5 + 1] == 0)
        #expect(union[1 * 5 + 2] == 0)
        #expect(union[1 * 5 + 3] == 0)
    }

    @Test
    func onePointTentShadowIsZeroOffsetAndSymmetricAtOneAndTwoX() {
        let source: [UInt8] = [
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 255, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
        ]
        let oneX = DanmakuTextureRasterizer.tentBlur(
            alpha: source,
            width: 5,
            height: 5,
            radius: 1
        )
        let twoX = DanmakuTextureRasterizer.tentBlur(
            alpha: source,
            width: 5,
            height: 5,
            radius: 2
        )

        #expect(oneX[2 * 5 + 1] == oneX[2 * 5 + 3])
        #expect(oneX[1 * 5 + 2] == oneX[3 * 5 + 2])
        #expect(twoX[2 * 5] == twoX[2 * 5 + 4])
        #expect(twoX[2] == twoX[4 * 5 + 2])
        #expect(twoX[2 * 5 + 2] > twoX[2 * 5 + 1])
        #expect(twoX[2 * 5 + 1] > twoX[2 * 5])
    }

    @Test
    func cacheKeyIncludesEveryVisualInputAndAdaptiveInkThreshold() throws {
        let baseEvent = event(
            id: "key",
            mode: .top,
            colorRGB: 0xFFFFFF,
            fontSize: 25
        )
        let base = try #require(
            DanmakuTextureRasterizer.key(
                event: baseEvent,
                style: .production,
                backingScale: 2
            )
        )
        let changedText = try #require(
            DanmakuTextureRasterizer.key(
                event: DanmakuEvent(
                    id: "key-2",
                    timeSeconds: 1,
                    mode: .top,
                    text: "different",
                    fontSize: 25,
                    colorRGB: 0xFFFFFF,
                    weight: 1
                ),
                style: .production,
                backingScale: 2
            )
        )
        let changedStyle = try #require(
            DanmakuTextureRasterizer.key(
                event: baseEvent,
                style: CoreAnimationDanmakuStyle(
                    fontScale: 1.5,
                    fontWeight: .bold,
                    shadowBlurRadius: 4
                ),
                backingScale: 2
            )
        )
        let changedScale = try #require(
            DanmakuTextureRasterizer.key(
                event: baseEvent,
                style: .production,
                backingScale: 1
            )
        )
        let changedColor = try #require(
            DanmakuTextureRasterizer.key(
                event: event(
                    id: "key-color",
                    mode: .top,
                    colorRGB: 0x204060,
                    fontSize: 25
                ),
                style: .production,
                backingScale: 2
            )
        )
        let changedFontSize = try #require(
            DanmakuTextureRasterizer.key(
                event: event(
                    id: "key-size",
                    mode: .top,
                    colorRGB: 0xFFFFFF,
                    fontSize: 36
                ),
                style: .production,
                backingScale: 2
            )
        )

        #expect(base != changedText)
        #expect(base != changedStyle)
        #expect(base != changedScale)
        #expect(base != changedColor)
        #expect(base != changedFontSize)
        #expect(base.fontDescriptor == "system-semibold")
        #expect(base.fontWeight == .semibold)
        #expect(base.fontScale == 1)
        #expect(base.outlineWidthPoints == 0.5)
        #expect(base.shadowRadiusPoints == 1)
        #expect(base.algorithmVersion == 1)
        #expect(DanmakuTextureRasterizer.decorationIsLight(colorRGB: 0x757575))
        #expect(!DanmakuTextureRasterizer.decorationIsLight(colorRGB: 0x767676))
    }

    @Test
    func rasterizerHandlesSupportedSizesScriptsAndColorGlyphInputs() throws {
        let samples = [
            "中文弹幕",
            "Latin 123",
            "e\u{301}",
            "👨‍👩‍👧‍👦 🌈",
        ]
        for scale in [1.0, 2.0] {
            for size in [18.0, 25.0, 36.0] {
                for (index, text) in samples.enumerated() {
                    let fixture = DanmakuEvent(
                        id: "raster-" + String(index),
                        timeSeconds: 1,
                        mode: .scrolling,
                        text: text,
                        fontSize: size,
                        colorRGB: index.isMultiple(of: 2)
                            ? 0xFFFFFF : 0x204060,
                        weight: 1
                    )
                    let key = try #require(
                        DanmakuTextureRasterizer.key(
                            event: fixture,
                            style: .production,
                            backingScale: scale
                        )
                    )
                    let payload = try #require(
                        DanmakuTextureRasterizer.rasterize(key: key)
                    )
                    #expect(payload.widthPixels > 0)
                    #expect(payload.heightPixels > 0)
                    #expect(payload.byteCost == payload.pixels.count)
                    #expect(
                        stride(
                            from: 3,
                            to: payload.pixels.count,
                            by: 4
                        ).contains { payload.pixels[$0] > 0 }
                    )
                }
            }
        }

        let emojiEvent = DanmakuEvent(
            id: "color-emoji",
            timeSeconds: 1,
            mode: .scrolling,
            text: "🌈",
            fontSize: 36,
            colorRGB: 0xFFFFFF,
            weight: 1
        )
        let emojiKey = try #require(
            DanmakuTextureRasterizer.key(
                event: emojiEvent,
                style: .production,
                backingScale: 2
            )
        )
        let emoji = try #require(
            DanmakuTextureRasterizer.rasterize(key: emojiKey)
        )
        let hasColoredGlyphPixel = stride(
            from: 0,
            to: emoji.pixels.count,
            by: 4
        ).contains { offset in
            let red = emoji.pixels[offset]
            let green = emoji.pixels[offset + 1]
            let blue = emoji.pixels[offset + 2]
            return emoji.pixels[offset + 3] > 0
                && (red != green || green != blue)
        }
        #expect(hasColoredGlyphPixel)
    }

    @Test
    func byteBoundedCacheUsesLRUAndRejectsOversizedItems() throws {
        let limits = DanmakuTextureLRUCache.Limits(
            maximumItemCost: 64,
            maximumTotalCost: 96
        )
        let cache = DanmakuTextureLRUCache(limits: limits)
        let first = textureKey(text: "first")
        let second = textureKey(text: "second")
        let third = textureKey(text: "third")
        let payload = texturePayload(byteCost: 48)

        let insertedFirst = cache.insert(payload, for: first)
        let insertedSecond = cache.insert(payload, for: second)
        let firstHit = cache.value(for: first)
        let insertedThird = cache.insert(payload, for: third)
        let evictedSecond = cache.value(for: second)
        let retainedFirst = cache.value(for: first)
        let retainedThird = cache.value(for: third)
        #expect(insertedFirst)
        #expect(insertedSecond)
        #expect(firstHit == payload)
        #expect(insertedThird)
        #expect(evictedSecond == nil)
        #expect(retainedFirst == payload)
        #expect(retainedThird == payload)
        #expect(cache.totalCost == 96)
        #expect(cache.evictionCount == 1)
        let insertedOversized = cache.insert(
            texturePayload(byteCost: 68),
            for: second
        )
        #expect(!insertedOversized)
        #expect(cache.totalCost == 96)
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.totalCost == 0)
    }

    @Test
    func preparedRendererUsesOneOrdinaryLayerAndRootOpacity() async throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 240)
        let fixture = event(
            id: "one-layer",
            mode: .scrolling,
            colorRGB: 0xD0E0F0
        )
        let metrics = try await prepareAndRender(
            renderer: renderer,
            event: fixture,
            preparationID: 1,
            originY: 20
        )
        let layer = try #require(renderer.textLayer(forEventID: fixture.id))
        let identity = try #require(
            renderer.objectIdentity(forEventID: fixture.id)
        )

        #expect(metrics.width > 0)
        #expect(metrics.height > 0)
        #expect(!(layer is CATextLayer))
        #expect(layer.contents != nil)
        #expect(layer.sublayers == nil)
        #expect(layer.shadowOpacity == 0)
        #expect(renderer.rootLayer.sublayers?.count == 1)

        let opacity = try #require(DanmakuOpacity(0.35))
        renderer.setOpacity(opacity)
        #expect(abs(Double(renderer.rootLayer.opacity) - 0.35) < 0.001)
        #expect(layer.opacity == 1)
        #expect(
            renderer.objectIdentity(forEventID: fixture.id) == identity
        )
        #expect(renderer.activeTextureByteCost > 0)
        #expect(
            renderer.activeTextureByteCost
                <= CoreAnimationDanmakuRenderer.maximumActiveTextureByteCost
        )
        renderer.remove(eventID: fixture.id)
        #expect(renderer.activeTextureByteCost == 0)
    }

    @Test
    func preparedRendererCachesByBytesAndClearsOnMemoryPressure() async throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 240)
        let first = event(id: "cache-first", mode: .top)
        _ = try await prepareAndRender(
            renderer: renderer,
            event: first,
            preparationID: 1,
            originY: 0
        )
        renderer.remove(eventID: first.id)
        let rasterizations = renderer.rasterizationCount
        let repeated = DanmakuEvent(
            id: "cache-second",
            timeSeconds: first.timeSeconds,
            mode: first.mode,
            text: first.text,
            fontSize: first.fontSize,
            colorRGB: first.colorRGB,
            weight: first.weight
        )
        _ = try await prepareAndRender(
            renderer: renderer,
            event: repeated,
            preparationID: 2,
            originY: 0
        )
        #expect(renderer.rasterizationCount == rasterizations)
        #expect(renderer.cacheHitCount >= 1)
        #expect(renderer.cachedTextureCount == 1)
        #expect(renderer.cachedTextureByteCost > 0)

        renderer.remove(eventID: repeated.id)
        renderer.handleMemoryPressureForTesting()
        #expect(renderer.cachedTextureCount == 0)
        #expect(renderer.cachedTextureByteCost == 0)
        _ = try await prepareAndRender(
            renderer: renderer,
            event: repeated,
            preparationID: 3,
            originY: 0
        )
        #expect(renderer.rasterizationCount == rasterizations + 1)

        renderer.remove(eventID: repeated.id)
        let prepared = await prepare(
            renderer: renderer,
            event: repeated,
            preparationID: 4
        )
        guard case .ready(let metrics) = prepared else {
            Issue.record("texture preparation was rejected")
            return
        }
        #expect(renderer.outstandingPreparationCount == 1)
        renderer.handleMemoryPressureForTesting()
        #expect(renderer.outstandingPreparationCount == 0)
        #expect(renderer.cachedTextureByteCost == 0)
        #expect(
            !renderer.renderPrepared(
                placement(event: repeated, metrics: metrics, originY: 0),
                preparationID: 4,
                generation: 0
            )
        )
    }

    @Test
    func rendererResizePreservesMotionAndRelayoutsFixedModes() async throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 300)
        let scrolling = event(id: "resize-scroll", mode: .scrolling)
        let top = event(id: "resize-top", mode: .top)
        let bottom = event(id: "resize-bottom", mode: .bottom)

        _ = try await prepareAndRender(
            renderer: renderer,
            event: scrolling,
            preparationID: 1,
            originY: 60
        )
        _ = try await prepareAndRender(
            renderer: renderer,
            event: top,
            preparationID: 2,
            originY: 0
        )
        let bottomMetrics = try await prepareAndRender(
            renderer: renderer,
            event: bottom,
            preparationID: 3,
            originY: 240
        )
        let scrollingLayer = try #require(
            renderer.textLayer(forEventID: scrolling.id)
        )
        let topLayer = try #require(renderer.textLayer(forEventID: top.id))
        let bottomLayer = try #require(
            renderer.textLayer(forEventID: bottom.id)
        )
        let scrollingPosition = scrollingLayer.position
        let topY = topLayer.position.y
        let bottomY = bottomLayer.position.y
        let animation = try #require(
            scrollingLayer.animation(forKey: "danmaku") as? CABasicAnimation
        )
        let from = animation.fromValue as? NSNumber
        let to = animation.toValue as? NSNumber
        let epoch = renderer.renderEpoch

        renderer.updateSurfaceSize(width: 1_200, height: 500)

        #expect(bottomMetrics.height > 0)
        #expect(renderer.renderEpoch == epoch)
        #expect(renderer.activeLayerCount == 3)
        #expect(scrollingLayer.position == scrollingPosition)
        let resized = try #require(
            scrollingLayer.animation(forKey: "danmaku") as? CABasicAnimation
        )
        #expect((resized.fromValue as? NSNumber) == from)
        #expect((resized.toValue as? NSNumber) == to)
        #expect(topLayer.position == CGPoint(x: 600, y: topY))
        #expect(bottomLayer.position == CGPoint(x: 600, y: bottomY + 200))
    }

    @Test
    func staleAnimationCompletionCannotRemoveReplacement() async throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        let delegate = RecordingRendererDelegate()
        renderer.delegate = delegate
        renderer.updateSurfaceSize(width: 800, height: 200)
        let fixture = event(id: "reused", mode: .top)
        _ = try await prepareAndRender(
            renderer: renderer,
            event: fixture,
            preparationID: 1,
            originY: 10
        )
        let oldIdentity = try #require(
            renderer.objectIdentity(forEventID: fixture.id)
        )
        let oldEpoch = renderer.renderEpoch

        renderer.clearAll()
        _ = try await prepareAndRender(
            renderer: renderer,
            event: fixture,
            preparationID: 2,
            generation: 1,
            originY: 10
        )
        let newIdentity = try #require(
            renderer.objectIdentity(forEventID: fixture.id)
        )
        let newEpoch = renderer.renderEpoch

        renderer.completeAnimation(
            eventID: fixture.id,
            objectIdentity: oldIdentity,
            renderEpoch: oldEpoch
        )
        #expect(renderer.activeLayerCount == 1)
        #expect(delegate.finishedEventIDs.isEmpty)

        renderer.completeAnimation(
            eventID: fixture.id,
            objectIdentity: newIdentity,
            renderEpoch: newEpoch
        )
        #expect(renderer.activeLayerCount == 0)
        #expect(delegate.finishedEventIDs == [fixture.id])
    }

    @Test
    func controllerWaitsForTextureAndPreservesPreparationOrder() {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 4)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1Prepared", cid: 1)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [
                    event(id: "first", mode: .top),
                    event(id: "second", mode: .top),
                ]
            )
        )
        let firstID = backend.preparationIDs[0]
        let secondID = backend.preparationIDs[1]

        #expect(controller.statistics.active == 0)
        #expect(backend.renderedEventIDs.isEmpty)
        backend.completePreparation(secondID)
        #expect(backend.renderedEventIDs.isEmpty)
        backend.completePreparation(firstID)
        #expect(backend.renderedEventIDs == ["first", "second"])
        #expect(controller.statistics.active == 2)
    }

    @Test
    func identityReplacementRejectsLatePreparation() {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 4)
        )
        let oldIdentity = PlaybackItemIdentity(bvid: "BV1OldIdentity", cid: 1)
        let newIdentity = PlaybackItemIdentity(bvid: "BV1NewIdentity", cid: 2)

        controller.apply(
            update(
                identity: oldIdentity,
                position: 1,
                generation: 1,
                events: [event(id: "old-identity", mode: .top)]
            )
        )
        let oldPreparationID = backend.preparationIDs.last!
        controller.apply(
            update(
                identity: newIdentity,
                position: 1,
                generation: 1,
                events: [event(id: "new-identity", mode: .top)]
            )
        )
        let newPreparationID = backend.preparationIDs.last!

        backend.completePreparation(oldPreparationID)
        #expect(backend.renderedEventIDs.isEmpty)
        backend.completePreparation(newPreparationID)
        #expect(backend.renderedEventIDs == ["new-identity"])
        #expect(controller.statistics.active == 1)
    }

    @Test
    func generationStopAndBackingScaleInvalidateLatePreparation() {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 4)
        )
        let owner = UUID()
        controller.attachSurface(ownerID: owner)
        controller.updateSurface(
            width: 800,
            height: 300,
            backingScale: 2,
            ownerID: owner
        )
        let identity = PlaybackItemIdentity(bvid: "BV1Late", cid: 1)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [event(id: "old-generation", mode: .top)]
            )
        )
        let oldGenerationID = backend.preparationIDs.last!
        controller.apply(
            update(
                identity: identity,
                position: 2,
                generation: 2
            )
        )
        backend.completePreparation(oldGenerationID)
        #expect(backend.renderedEventIDs.isEmpty)

        controller.apply(
            update(
                identity: identity,
                position: 3,
                generation: 2,
                events: [event(id: "old-scale", mode: .top)]
            )
        )
        let oldScaleID = backend.preparationIDs.last!
        controller.updateSurface(
            width: 800,
            height: 300,
            backingScale: 1,
            ownerID: owner
        )
        backend.completePreparation(oldScaleID)
        #expect(backend.renderedEventIDs.isEmpty)

        controller.apply(
            update(
                identity: identity,
                position: 3.5,
                generation: 2,
                events: [event(id: "cleared", mode: .top)]
            )
        )
        let clearedID = backend.preparationIDs.last!
        controller.clearPresentation()
        backend.completePreparation(clearedID)
        #expect(backend.renderedEventIDs.isEmpty)

        controller.apply(
            update(
                identity: identity,
                position: 4,
                generation: 2,
                events: [event(id: "stopped", mode: .top)]
            )
        )
        let stoppedID = backend.preparationIDs.last!
        controller.stopPresentation()
        backend.completePreparation(stoppedID)
        #expect(backend.renderedEventIDs.isEmpty)
        #expect(controller.statistics.active == 0)
        #expect(backend.cancelPreparationCount >= 3)
    }

    @Test
    func sameScaleResizeKeepsPendingPreparationAndUsesNewSurface() {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 4)
        )
        let owner = UUID()
        controller.attachSurface(ownerID: owner)
        let identity = PlaybackItemIdentity(bvid: "BV1ResizePending", cid: 1)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [event(id: "pending-resize", mode: .top)]
            )
        )
        let preparationID = backend.preparationIDs.last!
        let cancelCount = backend.cancelPreparationCount
        controller.updateSurface(
            width: 1_200,
            height: 500,
            backingScale: 2,
            ownerID: owner
        )
        #expect(backend.cancelPreparationCount == cancelCount)

        backend.completePreparation(preparationID)
        #expect(backend.renderedEventIDs == ["pending-resize"])
        #expect(
            backend.renderedPlacements.last?.surfaceWidthAtAdmission == 1_200
        )
    }

    @Test
    func rendererThreeModesRateAndLifecycleRemainBounded() async throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 300)
        let fixtures = [
            event(id: "scroll", mode: .scrolling),
            event(id: "top", mode: .top),
            event(id: "bottom", mode: .bottom),
        ]
        for (index, fixture) in fixtures.enumerated() {
            _ = try await prepareAndRender(
                renderer: renderer,
                event: fixture,
                preparationID: UInt64(index + 1),
                originY: Double(index) * 80
            )
        }

        #expect(
            renderer.textLayer(forEventID: "scroll")?
                .animation(forKey: "danmaku") is CABasicAnimation
        )
        #expect(renderer.activeLayerCount == 3)
        #expect(renderer.maximumConcurrentPreparationCount == 2)

        renderer.setPlaybackRate(0)
        #expect(renderer.rootLayer.speed == 0)
        renderer.setPlaybackRate(0.5)
        #expect(renderer.rootLayer.speed == 0.5)
        renderer.setPlaybackRate(2)
        #expect(renderer.rootLayer.speed == 2)

        let beforeStop = renderer.renderEpoch
        renderer.stop()
        #expect(renderer.renderEpoch == beforeStop + 1)
        #expect(renderer.activeLayerCount == 0)
        #expect(renderer.outstandingPreparationCount == 0)
        #expect(renderer.rootLayer.speed == 0)
    }

    @Test
    func preparationOwnerRejectsWorkBeyondItsHardOutstandingLimit() {
        let renderer = CoreAnimationDanmakuRenderer(
            style: .production,
            contentsScale: 2,
            preparationConfiguration: .init(
                maximumConcurrentOperations: 1,
                maximumOutstandingRequests: 1,
                cacheLimits: .production
            )
        )
        renderer.updateSurfaceSize(width: 800, height: 300)
        var secondResult: DanmakuPreparationResult?
        renderer.prepare(
            event(id: "bounded-first", mode: .scrolling),
            preparationID: 1,
            generation: 0,
            backingScale: 2
        ) { _ in }
        renderer.prepare(
            event(id: "bounded-second", mode: .scrolling),
            preparationID: 2,
            generation: 0,
            backingScale: 2
        ) { result in
            secondResult = result
        }

        #expect(secondResult == .rejected(.capacity))
        #expect(renderer.outstandingPreparationCount == 1)
        #expect(renderer.maximumConcurrentPreparationCount == 1)
        renderer.stop()
        #expect(renderer.outstandingPreparationCount == 0)
    }

    @Test
    func completedPayloadHandoffKeepsOperationSlotOccupied() {
        let probe = RasterizationStartProbe()
        let owner = DanmakuTexturePreparationOwner(
            configuration: .init(
                maximumConcurrentOperations: 1,
                maximumOutstandingRequests: 3,
                cacheLimits: .production
            ),
            rasterize: { _ in
                probe.recordStart()
                return DanmakuTexturePayload(
                    pixels: Data(repeating: 1, count: 4),
                    widthPixels: 1,
                    heightPixels: 1,
                    bytesPerRow: 4,
                    backingScale: 1
                )
            }
        )
        for index in 0..<3 {
            owner.prepare(
                event: event(id: "handoff-\(index)", mode: .scrolling),
                style: .production,
                backingScale: 2,
                preparationID: UInt64(index + 1),
                generation: 0
            ) { _ in }
        }

        #expect(probe.waitForStart(timeout: .now() + 1) == .success)
        #expect(
            probe.waitForStart(timeout: .now() + .milliseconds(100))
                == .timedOut
        )
        #expect(probe.startCount == 1)
        owner.cancelAllPreparations()
    }

    @Test
    func rendererRejectsTextureBeyondActiveByteBudget() async {
        let renderer = CoreAnimationDanmakuRenderer(
            style: .production,
            contentsScale: 2,
            preparationConfiguration: .production,
            activeTextureByteLimit: 1
        )
        renderer.updateSurfaceSize(width: 800, height: 300)
        let fixture = event(id: "active-byte-limit", mode: .top)
        let prepared = await prepare(
            renderer: renderer,
            event: fixture,
            preparationID: 1
        )
        guard case .ready(let metrics) = prepared else {
            Issue.record("texture preparation was rejected")
            return
        }

        #expect(
            !renderer.renderPrepared(
                placement(event: fixture, metrics: metrics, originY: 0),
                preparationID: 1,
                generation: 0
            )
        )
        #expect(renderer.activeLayerCount == 0)
        #expect(renderer.activeTextureByteCost == 0)
        #expect(renderer.outstandingPreparationCount == 0)
    }

    @Test
    func failedLayerInstallImmediatelyReleasesAdmittedLane() {
        let backend = RecordingRenderingBackend()
        backend.renderPreparedResult = false
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 1)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1Install", cid: 1)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [event(id: "failed", mode: .top)]
            )
        )
        #expect(controller.statistics.active == 0)
        #expect(controller.statistics.droppedCapacity == 1)

        backend.renderPreparedResult = true
        controller.apply(
            update(
                identity: identity,
                position: 2,
                generation: 1,
                events: [event(id: "replacement", mode: .top)]
            )
        )
        #expect(backend.renderedEventIDs == ["replacement"])
        #expect(controller.statistics.active == 1)
    }

    @Test
    func stoppedPreparationOwnerAndRendererAreReleased() async throws {
        weak var weakRenderer: CoreAnimationDanmakuRenderer?
        do {
            let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
            weakRenderer = renderer
            renderer.updateSurfaceSize(width: 800, height: 300)
            _ = try await prepareAndRender(
                renderer: renderer,
                event: event(id: "release", mode: .scrolling),
                preparationID: 1,
                originY: 20
            )
            renderer.stop()
        }
        #expect(weakRenderer == nil)
    }

    @Test
    func invalidAndOversizedTextFailClosedBeforeLaneAdmission() async {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 300)
        let invalid = DanmakuEvent(
            id: "invalid",
            timeSeconds: 1,
            mode: .scrolling,
            text: "invalid",
            fontSize: .nan,
            colorRGB: 0xFFFFFF,
            weight: 1
        )
        let oversized = DanmakuEvent(
            id: "oversized",
            timeSeconds: 1,
            mode: .scrolling,
            text: String(repeating: "W", count: 512),
            fontSize: 36,
            colorRGB: 0xFFFFFF,
            weight: 1
        )

        #expect(
            await prepare(
                renderer: renderer,
                event: invalid,
                preparationID: 1
            ) == .rejected(.invalidInput)
        )
        #expect(
            await prepare(
                renderer: renderer,
                event: oversized,
                preparationID: 2
            ) == .rejected(.oversized)
        )
        #expect(renderer.activeLayerCount == 0)
        #expect(renderer.outstandingPreparationCount == 0)
    }

    private func prepareAndRender(
        renderer: CoreAnimationDanmakuRenderer,
        event: DanmakuEvent,
        preparationID: UInt64,
        generation: UInt64 = 0,
        originY: Double
    ) async throws -> DanmakuTextMetrics {
        let result = await prepare(
            renderer: renderer,
            event: event,
            preparationID: preparationID,
            generation: generation
        )
        guard case .ready(let metrics) = result else {
            Issue.record("texture preparation was rejected")
            return DanmakuTextMetrics(width: 0, height: 0)
        }
        let didRender = renderer.renderPrepared(
            placement(event: event, metrics: metrics, originY: originY),
            preparationID: preparationID,
            generation: generation
        )
        #expect(didRender)
        return metrics
    }

    private func prepare(
        renderer: CoreAnimationDanmakuRenderer,
        event: DanmakuEvent,
        preparationID: UInt64,
        generation: UInt64 = 0
    ) async -> DanmakuPreparationResult {
        await withCheckedContinuation { continuation in
            renderer.prepare(
                event,
                preparationID: preparationID,
                generation: generation,
                backingScale: 2
            ) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func textureKey(text: String) -> DanmakuTextureCacheKey {
        DanmakuTextureCacheKey(
            text: text,
            fontSize: 25,
            colorRGB: 0xFFFFFF,
            fontDescriptor: "system-semibold",
            fontWeight: .semibold,
            fontScale: 1,
            backingScale: 2,
            outlineWidthPoints: 0.5,
            shadowRadiusPoints: 1,
            algorithmVersion: 1
        )
    }

    private func texturePayload(byteCost: Int) -> DanmakuTexturePayload {
        DanmakuTexturePayload(
            pixels: Data(repeating: 1, count: byteCost),
            widthPixels: byteCost / 4,
            heightPixels: 1,
            bytesPerRow: byteCost,
            backingScale: 1
        )
    }
    private func configuration(
        maximumActiveCount: Int,
        surfaceHeight: Double = 300
    ) -> DanmakuLaneConfiguration {
        DanmakuLaneConfiguration(
            surfaceWidth: 800,
            surfaceHeight: surfaceHeight,
            laneHeight: 30,
            minimumHorizontalGap: 12,
            maximumActiveCount: maximumActiveCount,
            displayAreaFraction: 1
        )
    }

    private func update(
        identity: PlaybackItemIdentity,
        position: Double,
        generation: UInt64,
        state: PlaybackTimelineState = .playing,
        rate: Double = 1,
        events: [DanmakuEvent] = []
    ) -> DanmakuPresentationUpdate {
        let snapshot = PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 100,
            rate: rate,
            state: state,
            discontinuityGeneration: generation
        )
        let batch =
            events.isEmpty
            ? nil
            : DanmakuBatch(
                identity: identity,
                discontinuityGeneration: generation,
                events: events,
                clearsExisting: false
            )
        return DanmakuPresentationUpdate(snapshot: snapshot, batch: batch)
    }

    private func event(
        id: String,
        mode: DanmakuPresentationMode,
        colorRGB: UInt32 = 0xFFFFFF,
        fontSize: Double = 24
    ) -> DanmakuEvent {
        DanmakuEvent(
            id: id,
            timeSeconds: 1,
            mode: mode,
            text: "中文 日本語 한국어 Latin 😀 #",
            fontSize: fontSize,
            colorRGB: colorRGB,
            weight: 1
        )
    }

    private func placement(
        event: DanmakuEvent,
        metrics: DanmakuTextMetrics,
        originY: Double
    ) -> DanmakuLanePlacement {
        DanmakuLanePlacement(
            request: DanmakuLaneRequest(
                event: event,
                width: metrics.width,
                height: metrics.height,
                durationSeconds: 4
            ),
            laneIndex: 0,
            originY: originY,
            surfaceWidthAtAdmission: 800,
            admittedAtSeconds: 1,
            expiresAtSeconds: 5
        )
    }
}

@MainActor
private final class RecordingRenderingBackend: DanmakuRenderingBackend {
    enum Operation: Equatable {
        case rate(Double)
        case remove(String)
        case render(String)
    }

    weak var delegate: (any DanmakuRenderingBackendDelegate)?
    var operations: [Operation] = []
    private(set) var renderedEventIDs: [String] = []
    private(set) var renderedPlacements: [DanmakuLanePlacement] = []
    private(set) var rates: [Double] = []
    private(set) var opacities: [DanmakuOpacity] = []
    private(set) var clearCount = 0
    private(set) var stopCount = 0
    private(set) var measureCount = 0
    private(set) var surfaceSizes: [DanmakuTextMetrics] = []
    var delaysPreparation = false
    var renderPreparedResult = true
    private(set) var preparationIDs: [UInt64] = []
    private(set) var cancelPreparationCount = 0
    private var preparationCompletions:
        [UInt64: @MainActor @Sendable (DanmakuPreparationResult) -> Void] = [:]

    func measure(_ event: DanmakuEvent) -> DanmakuTextMetrics {
        measureCount += 1
        return DanmakuTextMetrics(width: 120, height: 24)
    }

    func render(_ placement: DanmakuLanePlacement) {
        let eventID = placement.request.event.id
        operations.append(.render(eventID))
        renderedEventIDs.append(eventID)
        renderedPlacements.append(placement)
    }

    func prepare(
        _ event: DanmakuEvent,
        preparationID: UInt64,
        generation: UInt64,
        backingScale: Double,
        completion:
            @escaping @MainActor @Sendable (
                DanmakuPreparationResult
            ) -> Void
    ) {
        preparationIDs.append(preparationID)
        if delaysPreparation {
            preparationCompletions[preparationID] = completion
        } else {
            completion(.ready(measure(event)))
        }
    }

    @discardableResult
    func renderPrepared(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        generation: UInt64
    ) -> Bool {
        guard renderPreparedResult else { return false }
        render(placement)
        return true
    }

    func completePreparation(
        _ preparationID: UInt64,
        result: DanmakuPreparationResult = .ready(
            DanmakuTextMetrics(width: 120, height: 24)
        )
    ) {
        preparationCompletions[preparationID]?(result)
    }

    func cancelPendingPreparations() {
        cancelPreparationCount += 1
    }

    func remove(eventID: String) {
        operations.append(.remove(eventID))
    }

    func clearAll() {
        clearCount += 1
    }

    func setPlaybackRate(_ rate: Double) {
        operations.append(.rate(rate))
        rates.append(rate)
    }

    func setOpacity(_ opacity: DanmakuOpacity) {
        opacities.append(opacity)
    }

    func updateSurfaceSize(width: Double, height: Double) {
        surfaceSizes.append(
            DanmakuTextMetrics(width: width, height: height)
        )
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class RecordingRendererDelegate:
    DanmakuRenderingBackendDelegate
{
    private(set) var finishedEventIDs: [String] = []

    func rendererDidFinish(eventID: String) {
        finishedEventIDs.append(eventID)
    }
}
