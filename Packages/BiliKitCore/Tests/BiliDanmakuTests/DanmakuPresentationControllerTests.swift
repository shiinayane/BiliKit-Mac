import AppKit
import BiliApplication
import BiliModels
import CoreText
import QuartzCore
import Testing

@testable import BiliDanmaku

@MainActor
@Suite
struct DanmakuPresentationControllerTests {
    @Test
    func densityPoliciesMatchProductionSpacingAndOverlapDepths() {
        let policies = DanmakuDensity.allCases.map(
            DanmakuDensityAdmissionPolicy.init
        )

        #expect(policies.map(\.minimumHorizontalGap) == [24, 12, 0])
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
                + min(
                    0.25 * scenario.textWidth / 960,
                    0.45
                )
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
    func lengthBonusIsContinuousAtItsCap() {
        let policy = DanmakuMotionPolicy()
        let surfaceWidth = 1_100.0
        let capWidth = 1_728.0
        let epsilon = 0.001

        func speed(textWidth: Double) -> Double {
            let duration = policy.duration(
                for: .scrolling,
                textWidth: textWidth,
                surfaceWidth: surfaceWidth,
                speedLevel: .three
            )
            return (surfaceWidth + textWidth) / duration
        }

        #expect(abs(speed(textWidth: capWidth) - 188.5) < 0.001)
        #expect(
            abs(
                speed(textWidth: capWidth - epsilon)
                    - speed(textWidth: capWidth)
            ) < 0.001
        )
        #expect(
            abs(
                speed(textWidth: capWidth + epsilon)
                    - speed(textWidth: capWidth)
            ) < 0.001
        )
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
        let events = (0..<1_000).map {
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
        #expect(controller.statistics.droppedCapacity >= 360)
        #expect(backend.renderedEventIDs.count == 1)
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
    func rendererResizeKeepsScrollingAnimationAndRelayoutsFixedModes() throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 300)
        let scrolling = event(id: "resize-scroll", mode: .scrolling)
        let top = event(id: "resize-top", mode: .top)
        let bottom = event(id: "resize-bottom", mode: .bottom)

        for (fixture, originY) in [
            (scrolling, 60.0),
            (top, 0.0),
            (bottom, 240.0),
        ] {
            let metrics = renderer.measure(fixture)
            renderer.render(
                placement(
                    event: fixture,
                    metrics: metrics,
                    originY: originY
                )
            )
        }

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
        let epoch = renderer.renderEpoch
        let scrollingAnimation = try #require(
            scrollingLayer.animation(forKey: "danmaku") as? CABasicAnimation
        )
        let scrollingFrom = try #require(
            scrollingAnimation.fromValue as? NSNumber
        )
        let scrollingTo = try #require(
            scrollingAnimation.toValue as? NSNumber
        )
        let scrollingDuration = scrollingAnimation.duration
        let rootTiming = (
            beginTime: renderer.rootLayer.beginTime,
            timeOffset: renderer.rootLayer.timeOffset,
            speed: renderer.rootLayer.speed
        )

        renderer.updateSurfaceSize(width: 1_200, height: 500)

        #expect(renderer.renderEpoch == epoch)
        #expect(renderer.activeLayerCount == 3)
        #expect(scrollingLayer.position == scrollingPosition)
        let resizedAnimation = try #require(
            scrollingLayer.animation(forKey: "danmaku") as? CABasicAnimation
        )
        #expect((resizedAnimation.fromValue as? NSNumber) == scrollingFrom)
        #expect((resizedAnimation.toValue as? NSNumber) == scrollingTo)
        #expect(resizedAnimation.duration == scrollingDuration)
        #expect(renderer.rootLayer.beginTime == rootTiming.beginTime)
        #expect(renderer.rootLayer.timeOffset == rootTiming.timeOffset)
        #expect(renderer.rootLayer.speed == rootTiming.speed)
        #expect(topLayer.position == CGPoint(x: 600, y: topY))
        #expect(bottomLayer.position == CGPoint(x: 600, y: bottomY + 200))

        renderer.updateSurfaceSize(width: 0, height: 0)
        renderer.updateSurfaceSize(width: 1_200, height: 500)

        #expect(renderer.renderEpoch == epoch)
        #expect(renderer.activeLayerCount == 3)
        #expect(scrollingLayer.position == scrollingPosition)
        #expect(topLayer.position == CGPoint(x: 600, y: topY))
        #expect(bottomLayer.position == CGPoint(x: 600, y: bottomY + 200))
    }

    @Test
    func coreAnimationStyleUsesHeavyInkWithoutCompositorShadow() throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 200)
        let fixture = event(id: "style", mode: .scrolling)
        let metrics = renderer.measure(fixture)
        renderer.render(
            placement(
                event: fixture,
                metrics: metrics,
                originY: 20
            )
        )

        let layer = try #require(renderer.textLayer(forEventID: fixture.id))
        let attributed = try #require(layer.string as? NSAttributedString)
        let shadow = try #require(
            attributed.attribute(
                .shadow,
                at: 0,
                effectiveRange: nil
            ) as? NSShadow
        )

        #expect(layer.shadowOpacity == 0)
        #expect(shadow.shadowBlurRadius == 1.5)
        #expect(shadow.shadowOffset == .zero)
        #expect(renderer.activeLayerCount == 1)
    }

    @Test
    func coreAnimationUsesEventRGBAndAppliesOpacityWithoutReplacingLayers() throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 200)
        let colorful = event(
            id: "colorful",
            mode: .scrolling,
            colorRGB: 0xAB_D0_E0_F0
        )
        let dark = event(id: "dark", mode: .top, colorRGB: 0x000000)

        for (fixture, originY) in [(colorful, 20.0), (dark, 60.0)] {
            let metrics = renderer.measure(fixture)
            renderer.render(
                placement(
                    event: fixture,
                    metrics: metrics,
                    originY: originY
                )
            )
        }

        let colorfulLayer = try #require(
            renderer.textLayer(forEventID: colorful.id)
        )
        let colorfulIdentity = try #require(
            renderer.objectIdentity(forEventID: colorful.id)
        )
        let colorfulText = try #require(
            colorfulLayer.string as? NSAttributedString
        )
        let foreground = try #require(
            colorfulText.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor
        )
        let sRGB = try #require(foreground.usingColorSpace(.sRGB))
        let colorfulShadow = try #require(
            colorfulText.attribute(.shadow, at: 0, effectiveRange: nil)
                as? NSShadow
        )
        let colorfulShadowColor = try #require(
            colorfulShadow.shadowColor?.usingColorSpace(.sRGB)
        )

        #expect(abs(sRGB.redComponent - 0xD0 / 255) < 0.001)
        #expect(abs(sRGB.greenComponent - 0xE0 / 255) < 0.001)
        #expect(abs(sRGB.blueComponent - 0xF0 / 255) < 0.001)
        #expect(colorfulShadowColor.redComponent == 0)

        let darkLayer = try #require(renderer.textLayer(forEventID: dark.id))
        let darkText = try #require(darkLayer.string as? NSAttributedString)
        let darkShadow = try #require(
            darkText.attribute(.shadow, at: 0, effectiveRange: nil) as? NSShadow
        )
        let darkShadowColor = try #require(
            darkShadow.shadowColor?.usingColorSpace(.sRGB)
        )
        #expect(darkShadowColor.redComponent == 1)

        let opacity = try #require(DanmakuOpacity(0.45))
        renderer.setOpacity(opacity)

        #expect(abs(Double(renderer.rootLayer.opacity) - opacity.value) < 0.001)
        #expect(renderer.activeLayerCount == 2)
        #expect(
            renderer.objectIdentity(forEventID: colorful.id)
                == colorfulIdentity
        )
        #expect(renderer.textLayer(forEventID: colorful.id) === colorfulLayer)
    }

    @Test
    func adaptiveHeavyInkUsesFixedRelativeLuminanceThreshold() throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 200)
        let belowThreshold = event(
            id: "ink-below-threshold",
            mode: .scrolling,
            colorRGB: 0x757575
        )
        let aboveThreshold = event(
            id: "ink-above-threshold",
            mode: .top,
            colorRGB: 0x767676
        )

        for (fixture, originY) in [
            (belowThreshold, 20.0),
            (aboveThreshold, 60.0),
        ] {
            renderer.render(
                placement(
                    event: fixture,
                    metrics: renderer.measure(fixture),
                    originY: originY
                )
            )
        }

        func attributes(for eventID: String) throws -> NSAttributedString {
            let layer = try #require(renderer.textLayer(forEventID: eventID))
            return try #require(layer.string as? NSAttributedString)
        }

        func shadowRedComponent(for eventID: String) throws -> CGFloat {
            let text = try attributes(for: eventID)
            let shadow = try #require(
                text.attribute(.shadow, at: 0, effectiveRange: nil) as? NSShadow
            )
            let color = try #require(
                shadow.shadowColor?.usingColorSpace(.sRGB)
            )
            #expect(
                text.attribute(.strokeColor, at: 0, effectiveRange: nil) == nil
            )
            #expect(
                text.attribute(.strokeWidth, at: 0, effectiveRange: nil) == nil
            )
            return color.redComponent
        }

        #expect(try shadowRedComponent(for: belowThreshold.id) == 1)
        #expect(try shadowRedComponent(for: aboveThreshold.id) == 0)
    }

    @Test
    func coreAnimationTextCarriesSimplifiedChineseLanguage() throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 200)
        let fixture = DanmakuEvent(
            id: "simplified-chinese-language",
            timeSeconds: 1,
            mode: .scrolling,
            text: "弹幕字体/视频推荐/门骨直令",
            fontSize: 24,
            colorRGB: 0xFFFFFF,
            weight: 1
        )
        let metrics = renderer.measure(fixture)
        renderer.render(
            placement(
                event: fixture,
                metrics: metrics,
                originY: 20
            )
        )

        let layer = try #require(renderer.textLayer(forEventID: fixture.id))
        let attributed = try #require(layer.string as? NSAttributedString)
        var languageRange = NSRange()
        let language =
            attributed.attribute(
                NSAttributedString.Key(kCTLanguageAttributeName as String),
                at: 0,
                effectiveRange: &languageRange
            ) as? String

        #expect(language == "zh-Hans")
        #expect(
            languageRange
                == NSRange(location: 0, length: attributed.length)
        )
    }

    @Test
    func staleCompletionCannotRemoveReplacementWithSameEventID() throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        let delegate = RecordingRendererDelegate()
        renderer.delegate = delegate
        renderer.updateSurfaceSize(width: 800, height: 200)
        let fixture = event(id: "reused", mode: .top)
        let metrics = renderer.measure(fixture)
        let fixturePlacement = placement(
            event: fixture,
            metrics: metrics,
            originY: 10
        )
        renderer.render(fixturePlacement)
        let oldIdentity = try #require(
            renderer.objectIdentity(forEventID: fixture.id)
        )
        let oldEpoch = renderer.renderEpoch

        renderer.clearAll()
        renderer.render(fixturePlacement)
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
    func concreteRendererCoversThreeModesRateAndLifecycleEpochs() throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 300)
        let scrolling = event(id: "scroll", mode: .scrolling)
        let top = event(id: "top", mode: .top)
        let bottom = event(id: "bottom", mode: .bottom)

        for (fixture, originY) in [
            (scrolling, 60.0),
            (top, 0.0),
            (bottom, 240.0),
        ] {
            let metrics = renderer.measure(fixture)
            renderer.render(
                placement(
                    event: fixture,
                    metrics: metrics,
                    originY: originY
                )
            )
        }

        let scrollingAnimation = try #require(
            renderer.textLayer(forEventID: scrolling.id)?
                .animation(forKey: "danmaku") as? CABasicAnimation
        )
        let topAnimation = try #require(
            renderer.textLayer(forEventID: top.id)?
                .animation(forKey: "danmaku") as? CABasicAnimation
        )
        let bottomAnimation = try #require(
            renderer.textLayer(forEventID: bottom.id)?
                .animation(forKey: "danmaku") as? CABasicAnimation
        )
        #expect(scrollingAnimation.keyPath == "position.x")
        #expect(topAnimation.keyPath == "opacity")
        #expect(bottomAnimation.keyPath == "opacity")

        renderer.setPlaybackRate(0)
        #expect(renderer.rootLayer.speed == 0)
        renderer.setPlaybackRate(0.5)
        #expect(renderer.rootLayer.speed == 0.5)
        renderer.setPlaybackRate(2)
        #expect(renderer.rootLayer.speed == 2)

        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: configuration(maximumActiveCount: 640)
        )
        let surfaceOwner = UUID()
        controller.attachSurface(ownerID: surfaceOwner)
        let beforeDetach = renderer.renderEpoch
        controller.detachSurface(ownerID: surfaceOwner)
        #expect(renderer.renderEpoch == beforeDetach + 1)
        #expect(renderer.activeLayerCount == 0)
        #expect(renderer.rootLayer.sublayers?.isEmpty != false)

        controller.attachSurface(ownerID: surfaceOwner)
        let beforeStop = renderer.renderEpoch
        controller.stopPresentation()
        controller.stopPresentation()
        #expect(renderer.renderEpoch == beforeStop + 2)
        #expect(renderer.activeLayerCount == 0)
        #expect(renderer.rootLayer.speed == 0)
    }

    @Test
    func oversizedTextFailsClosedBeforeLayerCreation() {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 300)
        let oversized = DanmakuEvent(
            id: "oversized",
            timeSeconds: 1,
            mode: .scrolling,
            text: String(repeating: "W", count: 4_096),
            fontSize: 24,
            colorRGB: 0xFFFFFF,
            weight: 1
        )

        let metrics = renderer.measure(oversized)

        #expect(metrics == DanmakuTextMetrics(width: 0, height: 0))
        #expect(renderer.activeLayerCount == 0)
    }

    @Test
    func backendHardCapRejectsObjectSixHundredFortyOne() {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 1)
        renderer.updateSurfaceSize(width: 800, height: 300)
        let metrics = DanmakuTextMetrics(width: 40, height: 24)

        for index in 0...DanmakuLaneConfiguration.hardMaximumActiveCount {
            let fixture = DanmakuEvent(
                id: "direct-\(index)",
                timeSeconds: 1,
                mode: .top,
                text: "A",
                fontSize: 24,
                colorRGB: 0xFFFFFF,
                weight: 1
            )
            renderer.render(
                placement(
                    event: fixture,
                    metrics: metrics,
                    originY: 0
                )
            )
        }

        #expect(
            renderer.activeLayerCount
                == DanmakuLaneConfiguration.hardMaximumActiveCount
        )
        renderer.stop()
        #expect(renderer.activeLayerCount == 0)
    }

    @Test
    func stoppedOwnerAndRendererAreReleased() {
        weak var weakRenderer: CoreAnimationDanmakuRenderer?
        weak var weakController: DanmakuPresentationController?

        do {
            let renderer = CoreAnimationDanmakuRenderer(contentsScale: 1)
            let controller = DanmakuPresentationController(
                backend: renderer,
                configuration: configuration(maximumActiveCount: 4)
            )
            weakRenderer = renderer
            weakController = controller
            let fixture = event(id: "active", mode: .scrolling)
            let metrics = renderer.measure(fixture)
            renderer.render(
                placement(
                    event: fixture,
                    metrics: metrics,
                    originY: 60
                )
            )
            #expect(renderer.activeLayerCount == 1)
            controller.stopPresentation()
            #expect(renderer.activeLayerCount == 0)
        }

        #expect(weakController == nil)
        #expect(weakRenderer == nil)
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
        colorRGB: UInt32 = 0xFFFFFF
    ) -> DanmakuEvent {
        DanmakuEvent(
            id: id,
            timeSeconds: 1,
            mode: mode,
            text: "中文 日本語 한국어 Latin 😀 #",
            fontSize: 24,
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
