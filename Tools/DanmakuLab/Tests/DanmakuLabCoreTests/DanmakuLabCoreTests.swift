import BiliApplication
import BiliDanmaku
import BiliModels
import DanmakuLabCore
import Foundation
import QuartzCore
import Testing

@Suite("Danmaku Lab deterministic contracts")
struct DanmakuLabCoreTests {
    @Test("same seed and plan replay the same event sequence and timing")
    func deterministicReplay() {
        let first = LabScenarioPlan(
            scenario: .mixed,
            seed: 44,
            eventRate: 30,
            burstSize: 80
        )
        let second = LabScenarioPlan(
            scenario: .mixed,
            seed: 44,
            eventRate: 30,
            burstSize: 80
        )

        #expect((0..<200).map(first.event(at:)) == (0..<200).map(second.event(at:)))
        #expect(first.scheduledCount(at: 3) == 91)
    }

    @Test("scenario contracts cover production modes, legal sizes, text classes, and colors")
    func scenarioContracts() {
        let mixed = events(for: .mixed, count: 120)
        #expect(Set(mixed.map(\.mode)).count == 3)

        let typography = events(for: .typography, count: 12)
        #expect(Set(typography.map(\.fontSize)) == [18, 25, 36])

        let content = events(for: .contentEdges, count: 80)
        #expect(
            content.contains {
                $0.text.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            }
        )
        #expect(content.contains { $0.text.count > 30 })
        #expect(content.contains { $0.text.rangeOfCharacter(from: .decimalDigits) != nil })

        let palette = events(for: .palette, count: 80)
        #expect(Set(palette.map(\.colorRGB)).count >= 6)
    }

    @Test("pause, seek, reset, and replay advance only the intended state")
    func playbackGeneration() {
        var state = LabPlaybackState()
        state.play()
        state.advance(by: 2)
        #expect(state.positionSeconds == 2)
        state.advance(to: 3)
        #expect(state.positionSeconds == 3)

        state.pause()
        state.advance(by: 5)
        state.advance(to: 8)
        #expect(state.positionSeconds == 3)

        let beforeSeek = state.discontinuityGeneration
        state.seekForward(by: 10)
        #expect(state.positionSeconds == 13)
        #expect(state.scenarioStartSeconds == 13)
        #expect(state.discontinuityGeneration == beforeSeek + 1)

        state.reset(play: true)
        #expect(state.positionSeconds == 0)
        #expect(state.scenarioStartSeconds == 0)
        #expect(state.isPlaying)
        #expect(state.discontinuityGeneration == beforeSeek + 2)
    }

    @Test("manifest versions input and event identity without external schema")
    func manifestContract() {
        let descriptor = LabScenarioDescriptor(
            id: "mixed-fixture",
            version: 3,
            durationSeconds: 30
        )
        let rendererStyle = CoreAnimationDanmakuStyle(
            fontScale: 1.2,
            fontWeight: .medium,
            shadowBlurRadius: 2.5
        )
        let first = LabRunManifest(
            scenario: .mixed,
            seed: 44,
            eventRate: 9_999,
            burstSize: 9_999,
            filter: LabEventFilter(),
            speedLevel: .three,
            opacity: 0.9,
            displayArea: .full,
            density: .normal,
            rendererStyle: rendererStyle,
            startsPlaying: true,
            descriptor: descriptor
        )
        let second = LabRunManifest(
            scenario: .mixed,
            seed: 44,
            eventRate: 120,
            burstSize: 640,
            filter: LabEventFilter(),
            speedLevel: .three,
            opacity: 0.9,
            displayArea: .full,
            density: .normal,
            rendererStyle: rendererStyle,
            startsPlaying: true,
            descriptor: descriptor
        )

        #expect(first == second)
        #expect(first.inputSummary == second.inputSummary)
        #expect(first.rendererStyle == rendererStyle)
        #expect(first.rendererID == .productionCoreAnimation)
        #expect(first.inputSummary.contains("fontScale=1.2"))
        #expect(first.inputSummary.contains("fontWeight=medium"))
        #expect(first.inputSummary.contains("shadowBlur=2.5"))
        #expect(first.inputSummary.contains("renderer=production-core-animation"))
        #expect(first.plan.event(at: 7) == second.plan.event(at: 7))
        #expect(first.plan.event(at: 7).id == "lab/mixed-fixture/v3/44/7")
        #expect(
            Set(LabScenario.allCases.map { LabScenarioCatalog.descriptor(for: $0).id }).count
                == LabScenario.allCases.count
        )
    }

    @Test("pause and resume discard wall remainder without backfill")
    func logicalClockPauseResume() {
        var clock = LabLogicalClock(
            ticksPerSecond: 60,
            maximumTicksPerWallAdvance: 60,
            durationSeconds: 10,
            isPlaying: true
        )

        #expect(
            clock.advance(wallNanoseconds: 8_000_000).tickOrdinals.isEmpty
        )
        clock.setPlaying(false)
        #expect(
            clock.advance(wallNanoseconds: 1_000_000_000).tickOrdinals.isEmpty
        )
        clock.setPlaying(true)
        #expect(
            clock.advance(wallNanoseconds: 8_000_000).tickOrdinals.isEmpty
        )
        let resumed = clock.advance(wallNanoseconds: 8_666_666)

        #expect(Array(resumed.tickOrdinals) == [0])
        #expect(clock.tickOrdinal == 1)
    }

    @Test("logical ticks are invariant to wall callback grouping")
    func logicalClockGrouping() {
        var grouped = LabLogicalClock(
            ticksPerSecond: 60,
            maximumTicksPerWallAdvance: 60,
            durationSeconds: 10,
            isPlaying: true
        )
        var split = grouped

        let groupedAdvance = grouped.advance(wallNanoseconds: 100_000_002)
        let splitAdvances = [
            split.advance(wallNanoseconds: 10_000_000),
            split.advance(wallNanoseconds: 23_333_334),
            split.advance(wallNanoseconds: 66_666_668),
        ]

        #expect(Array(groupedAdvance.tickOrdinals) == Array(0..<6))
        #expect(
            splitAdvances.flatMap { Array($0.tickOrdinals) }
                == Array(groupedAdvance.tickOrdinals)
        )
        #expect(split.tickOrdinal == grouped.tickOrdinal)
        #expect(split.positionSeconds == grouped.positionSeconds)
    }

    @Test("logical clock stops polluted backlog and completes at fixed duration")
    func logicalClockBoundsAndDuration() {
        var polluted = LabLogicalClock(
            ticksPerSecond: 60,
            maximumTicksPerWallAdvance: 60,
            durationSeconds: 10,
            isPlaying: true
        )
        let pollutedAdvance = polluted.advance(
            wallNanoseconds: 61 * 16_666_666
        )
        #expect(
            pollutedAdvance.state
                == .polluted(
                    .backlogExceeded(
                        pendingTicks: 61,
                        maximumTicks: 60
                    )
                )
        )
        #expect(pollutedAdvance.tickOrdinals.isEmpty)
        #expect(!polluted.isPlaying)

        var completed = LabLogicalClock(
            ticksPerSecond: 60,
            maximumTicksPerWallAdvance: 60,
            durationSeconds: 0.05,
            isPlaying: true
        )
        let completion = completed.advance(
            wallNanoseconds: 3 * 16_666_666
        )
        #expect(Array(completion.tickOrdinals) == Array(0..<3))
        #expect(completion.state == .completed)
        #expect(completed.positionSeconds == 0.05)
        #expect(!completed.isPlaying)
    }

    @Test("generator and statistics retain explicit hard bounds and per-run totals")
    func hardBoundsAndStatistics() {
        let plan = LabScenarioPlan(
            scenario: .capacity,
            seed: 1,
            eventRate: 9_999,
            burstSize: 9_999
        )
        #expect(plan.eventRate == 120)
        #expect(plan.burstSize == 640)
        #expect(LabScenarioPlan.maximumEventsPerTick == 640)

        let current = LabRendererSnapshot(
            admitted: 6,
            droppedNoLane: 2,
            droppedCapacity: 1,
            active: 4,
            peakActive: 5
        )
        var mapped = LabStatistics()
        mapped.mapRenderer(current)
        #expect(mapped.admitted == 6)
        #expect(mapped.droppedNoLane == 2)
        #expect(mapped.droppedCapacity == 1)
        #expect(mapped.active == 4)
        #expect(mapped.peakActive == 5)
    }

    @Test("run owner waits for a valid surface and tears down idempotently")
    @MainActor
    func runOwnerLifecycle() {
        let owner = LabRunOwner(manifest: .standard)
        let surfaceOwner = UUID()

        #expect(owner.lifecycle == .waitingForSurface)
        #expect(!owner.attachSurface(width: 0, height: 720, ownerID: surfaceOwner))
        #expect(owner.lifecycle == .waitingForSurface)
        #expect(owner.attachSurface(width: 1280, height: 720, ownerID: surfaceOwner))
        #expect(owner.lifecycle == .running)
        #expect(owner.surfaceSize == CGSize(width: 1280, height: 720))
        #expect(
            !owner.updateSurface(
                width: 640,
                height: 360,
                ownerID: UUID()
            )
        )

        owner.shutdown()
        owner.shutdown()
        #expect(owner.lifecycle == .stopped)
        let renderer =
            owner.renderer.backend as? CoreAnimationDanmakuRenderer
        #expect(renderer?.activeLayerCount == 0)
        #expect(owner.renderer.surfaceLayer.speed == 0)
        #expect(owner.detachSurface(ownerID: surfaceOwner))
    }

    @Test("each run owns fresh renderer controller and statistics")
    @MainActor
    func runIsolation() {
        let style = CoreAnimationDanmakuStyle(
            fontScale: 0.8,
            fontWeight: .regular,
            shadowBlurRadius: 0
        )
        let manifest = LabRunManifest(
            scenario: .standard,
            seed: 44,
            eventRate: 24,
            burstSize: 120,
            filter: LabEventFilter(),
            speedLevel: .three,
            opacity: 0.9,
            displayArea: .full,
            density: .normal,
            rendererStyle: style,
            startsPlaying: true
        )
        let first = LabRunOwner(manifest: manifest)
        let second = LabRunOwner(manifest: manifest)

        #expect(first.id != second.id)
        #expect(first.renderer.backend !== second.renderer.backend)
        #expect(first.renderer.surfaceLayer !== second.renderer.surfaceLayer)
        #expect(first.controller !== second.controller)
        let firstRenderer =
            first.renderer.backend as? CoreAnimationDanmakuRenderer
        let secondRenderer =
            second.renderer.backend as? CoreAnimationDanmakuRenderer
        #expect(firstRenderer?.style == style)
        #expect(secondRenderer?.style == style)
        #expect(first.statistics == LabStatistics())
        #expect(second.statistics == LabStatistics())

        first.shutdown()
        second.shutdown()
    }

    @Test("display telemetry uses fixed timestamps and workload deltas")
    func frameTelemetryFixedTimestamps() throws {
        var telemetry = LabFrameTelemetryAccumulator()
        var snapshot: LabFrameTelemetrySnapshot?

        for ordinal in 0...60 {
            snapshot =
                telemetry.record(
                    timestamp: Double(ordinal) / 60,
                    targetDuration: 1 / 60,
                    totals: LabTelemetryTotals(
                        generated: ordinal * 2,
                        admitted: ordinal,
                        dropped: 0
                    )
                ) ?? snapshot
        }

        let result = try #require(snapshot)
        #expect(abs(result.observedFramesPerSecond - 60) < 0.001)
        #expect(abs(result.targetFramesPerSecond - 60) < 0.001)
        #expect(result.missedIntervals == 0)
        #expect(abs(result.longestIntervalMilliseconds - 16.667) < 0.01)
        #expect(abs(result.generatedPerSecond - 120) < 0.001)
        #expect(abs(result.admittedPerSecond - 60) < 0.001)
        #expect(result.droppedPerSecond == 0)
        #expect(result.sampledFrameIntervals == 60)
    }

    @Test("display telemetry reports missed intervals without per-frame publication")
    func frameTelemetryMissedIntervals() {
        var telemetry = LabFrameTelemetryAccumulator(publishInterval: 0.05)
        let totals = LabTelemetryTotals(generated: 0, admitted: 0, dropped: 0)

        #expect(
            telemetry.record(
                timestamp: 0,
                targetDuration: 1 / 60,
                totals: totals
            ) == nil
        )
        #expect(
            telemetry.record(
                timestamp: 1 / 60,
                targetDuration: 1 / 60,
                totals: totals
            ) == nil
        )
        let result = telemetry.record(
            timestamp: 3 / 60,
            targetDuration: 1 / 60,
            totals: totals
        )

        #expect(result?.missedIntervals == 1)
        #expect(result?.sampledFrameIntervals == 2)
        #expect(abs((result?.observedFramesPerSecond ?? 0) - 40) < 0.001)
        #expect(abs((result?.targetFramesPerSecond ?? 0) - 60) < 0.001)
        #expect(abs((result?.longestIntervalMilliseconds ?? 0) - 33.333) < 0.01)
    }

    @Test("display telemetry reset and run replacement isolate samples")
    @MainActor
    func frameTelemetryRunIsolation() {
        let first = LabRunOwner(manifest: .standard)
        let second = LabRunOwner(manifest: .standard)

        for ordinal in 0...60 {
            first.recordDisplayFrame(
                timestamp: Double(ordinal) / 60,
                targetDuration: 1 / 60
            )
        }

        #expect(first.frameTelemetry.sampledFrameIntervals == 60)
        #expect(second.frameTelemetry == .zero)
        first.resetDisplayTelemetry()
        #expect(first.frameTelemetry == .zero)

        first.shutdown()
        second.shutdown()
    }

    @Test("process telemetry computes CPU deltas and resets run peaks")
    func processTelemetryResetAndRates() throws {
        var telemetry = LabProcessTelemetryAccumulator()
        let firstSample = telemetry.record(
            LabProcessTelemetrySample(
                timestamp: 10,
                residentBytes: 100,
                physicalFootprintBytes: 80,
                cumulativeCPUSeconds: 3
            )
        )
        let first = try #require(firstSample)
        #expect(first.residentBytes == 100)
        #expect(first.peakResidentBytes == 100)
        #expect(first.physicalFootprintBytes == 80)
        #expect(first.peakPhysicalFootprintBytes == 80)
        #expect(!first.hasCPUInterval)

        let secondSample = telemetry.record(
            LabProcessTelemetrySample(
                timestamp: 12,
                residentBytes: 90,
                physicalFootprintBytes: 120,
                cumulativeCPUSeconds: 3.5
            )
        )
        let second = try #require(secondSample)
        #expect(second.peakResidentBytes == 100)
        #expect(second.peakPhysicalFootprintBytes == 120)
        #expect(second.hasCPUInterval)
        #expect(abs(second.cpuPercentage - 25) < 0.001)

        telemetry.reset()
        let resetSample = telemetry.record(
            LabProcessTelemetrySample(
                timestamp: 20,
                residentBytes: 50,
                physicalFootprintBytes: 40,
                cumulativeCPUSeconds: 10
            )
        )
        let reset = try #require(resetSample)
        #expect(reset.peakResidentBytes == 50)
        #expect(reset.peakPhysicalFootprintBytes == 40)
        #expect(!reset.hasCPUInterval)
        #expect(reset.cpuPercentage == 0)
    }

    @Test("renderer registry keeps production baseline and hides absent A/B")
    @MainActor
    func rendererRegistryBaselineContract() {
        let registry = LabRendererRegistry.productionOnly

        #expect(registry.descriptors.count == 1)
        #expect(registry.baseline.id == .productionCoreAnimation)
        #expect(registry.baseline.role == .productionBaseline)
        #expect(!registry.hasCandidates)
        #expect(
            registry.descriptor(for: .productionCoreAnimation)?.displayName
                == "Production Core Animation"
        )
    }

    @Test("performance presets freeze workload canvas scale and trace duration")
    func performancePresetCatalogContract() {
        let presets = LabPerformancePresetCatalog.all

        #expect(
            presets.map(\.catalogIdentity) == [
                "steady-80@1",
                "burst-320@1",
                "capacity-640@1",
            ]
        )
        #expect(Set(presets.map(\.id)).count == presets.count)
        #expect(presets.allSatisfy { $0.seed == 44 })
        #expect(
            presets.allSatisfy {
                $0.canvasSize == CGSize(width: 854, height: 480)
                    && $0.requiredBackingScale == 2
                    && $0.warmupSeconds == 5
                    && $0.measurementSeconds == 30
                    && $0.repetitions == 3
                    && $0.traceTimeLimitSeconds == 95
                    && $0.logicalTicksPerSecond == 30
                    && $0.expectedMeasurementTicks == 900
            }
        )
    }

    @Test("performance assessment separates pollution from contract revision")
    func performanceSampleAssessmentContract() {
        let preset = LabPerformancePresetCatalog.steady80
        var validStatistics = LabStatistics()
        validStatistics.generated = preset.expectedGeneratedEvents
        validStatistics.filtered = 5
        validStatistics.attempted = preset.expectedGeneratedEvents - 5
        validStatistics.admitted = 60
        validStatistics.droppedNoLane = validStatistics.attempted - 60
        validStatistics.active = 20
        validStatistics.peakActive = 40
        let validEvidence = LabPerformanceRunEvidence(
            attemptID: UUID(),
            presetIdentity: preset.catalogIdentity,
            logicalTicksProcessed: preset.expectedMeasurementTicks,
            expectedLogicalTicks: preset.expectedMeasurementTicks,
            generatedEvents: preset.expectedGeneratedEvents,
            expectedGeneratedEvents: preset.expectedGeneratedEvents,
            surfaceChangedDuringMeasurement: false
        )

        let eligible = LabPerformanceSampleAssessment(
            preset: preset,
            expectedRendererID: .productionCoreAnimation,
            rendererID: .productionCoreAnimation,
            telemetryEnabled: false,
            surfaceSize: preset.canvasSize,
            backingScale: preset.requiredBackingScale,
            lifecycle: .completed,
            statistics: validStatistics,
            runEvidence: validEvidence
        )
        #expect(eligible.disposition == .eligibleForTraceReview)
        #expect(eligible.pollution.isEmpty)
        #expect(eligible.contractFailures.isEmpty)

        let polluted = LabPerformanceSampleAssessment(
            preset: preset,
            expectedRendererID: .productionCoreAnimation,
            rendererID: LabRendererID(rawValue: "wrong"),
            telemetryEnabled: true,
            surfaceSize: CGSize(width: 640, height: 360),
            backingScale: 1,
            lifecycle: .waitingForSurface,
            statistics: validStatistics,
            runEvidence: validEvidence
        )
        #expect(polluted.disposition == .polluted)
        #expect(
            Set(polluted.pollution) == [
                .telemetryEnabled,
                .rendererMismatch,
                .canvasMismatch,
                .backingScaleMismatch,
                .lifecycleNotRunning,
            ]
        )

        var invalidStatistics = validStatistics
        invalidStatistics.generatorOverflow = 1
        invalidStatistics.attempted -= 1
        invalidStatistics.peakActive =
            DanmakuLaneConfiguration.hardMaximumActiveCount + 1
        let revise = LabPerformanceSampleAssessment(
            preset: preset,
            expectedRendererID: .productionCoreAnimation,
            rendererID: .productionCoreAnimation,
            telemetryEnabled: false,
            surfaceSize: preset.canvasSize,
            backingScale: preset.requiredBackingScale,
            lifecycle: .completed,
            statistics: invalidStatistics,
            runEvidence: validEvidence
        )
        #expect(revise.disposition == .revise)
        #expect(
            Set(revise.contractFailures) == [
                .generatorOverflow,
                .generatedAccountingMismatch,
                .presentationAccountingMismatch,
                .activeHardCapExceeded,
            ]
        )

        let incomplete = LabPerformanceSampleAssessment(
            preset: preset,
            expectedRendererID: .productionCoreAnimation,
            rendererID: .productionCoreAnimation,
            telemetryEnabled: false,
            surfaceSize: preset.canvasSize,
            backingScale: preset.requiredBackingScale,
            lifecycle: .completed,
            statistics: validStatistics,
            runEvidence: LabPerformanceRunEvidence(
                attemptID: UUID(),
                presetIdentity: preset.catalogIdentity,
                logicalTicksProcessed: preset.expectedMeasurementTicks - 1,
                expectedLogicalTicks: preset.expectedMeasurementTicks,
                generatedEvents: preset.expectedGeneratedEvents - 1,
                expectedGeneratedEvents: preset.expectedGeneratedEvents,
                surfaceChangedDuringMeasurement: true
            )
        )
        #expect(incomplete.disposition == .polluted)
        #expect(
            Set(incomplete.pollution) == [
                .incompleteLogicalWorkload,
                .generatedWorkloadMismatch,
                .surfaceChangedDuringMeasurement,
            ]
        )

        let backlog = LabPerformanceSampleAssessment(
            preset: preset,
            expectedRendererID: .productionCoreAnimation,
            rendererID: .productionCoreAnimation,
            telemetryEnabled: false,
            surfaceSize: preset.canvasSize,
            backingScale: preset.requiredBackingScale,
            lifecycle: .polluted(
                .backlogExceeded(pendingTicks: 31, maximumTicks: 30)
            ),
            statistics: LabStatistics(),
            runEvidence: LabPerformanceRunEvidence(
                attemptID: UUID(),
                presetIdentity: preset.catalogIdentity,
                logicalTicksProcessed: 10,
                expectedLogicalTicks: preset.expectedMeasurementTicks,
                generatedEvents: 10,
                expectedGeneratedEvents: preset.expectedGeneratedEvents,
                surfaceChangedDuringMeasurement: false,
                terminalPollution: .backlogExceeded(
                    pendingTicks: 31,
                    maximumTicks: 30
                )
            )
        )
        #expect(backlog.disposition == .revise)
        #expect(backlog.pollution.isEmpty)
        #expect(backlog.contractFailures == [.performanceBacklogExceeded])
    }

    @Test("performance owner finishes an exact logical workload on one warmed backend")
    @MainActor
    func performanceOwnerExactWorkload() async throws {
        let preset = LabPerformancePreset(
            id: LabPerformancePresetID(rawValue: "test-steady"),
            version: 1,
            displayName: "Test steady",
            scenario: .steady,
            seed: 44,
            eventRate: 10,
            burstSize: 10,
            canvasSize: CGSize(width: 320, height: 180),
            requiredBackingScale: 2,
            warmupSeconds: 0.1,
            measurementSeconds: 0.2,
            repetitions: 1,
            logicalTicksPerSecond: 10
        )
        let manifest = LabRunManifest(
            scenario: preset.scenario,
            seed: preset.seed,
            eventRate: preset.eventRate,
            burstSize: preset.burstSize,
            filter: LabEventFilter(),
            speedLevel: .three,
            opacity: 0.9,
            displayArea: .full,
            density: .normal,
            startsPlaying: false,
            descriptor: LabScenarioDescriptor(
                id: preset.scenario.catalogID,
                version: 1,
                durationSeconds: 1,
                logicalTicksPerSecond: preset.logicalTicksPerSecond,
                maximumTicksPerWallAdvance: preset.logicalTicksPerSecond
            )
        )
        let owner = LabRunOwner(manifest: manifest)
        let ownerID = UUID()
        #expect(
            owner.attachSurface(
                width: preset.canvasSize.width,
                height: preset.canvasSize.height,
                backingScale: preset.requiredBackingScale,
                ownerID: ownerID
            )
        )
        let backendSurfaceIdentity = ObjectIdentifier(owner.renderer.surfaceLayer)
        let attemptID = UUID()

        #expect(owner.beginPerformanceWarmup(preset: preset))
        await owner.waitForTerminalState()
        #expect(owner.lifecycle == .completed)
        #expect(owner.statistics.logicalTicksProcessed == 1)
        #expect(owner.beginPerformanceMeasurement(preset: preset, attemptID: attemptID))
        await owner.waitForTerminalState()

        #expect(owner.lifecycle == .completed)
        #expect(
            ObjectIdentifier(owner.renderer.surfaceLayer) == backendSurfaceIdentity
        )
        let evidence = try #require(owner.performanceRunEvidence)
        #expect(evidence.attemptID == attemptID)
        #expect(evidence.logicalTicksProcessed == preset.expectedMeasurementTicks)
        #expect(evidence.generatedEvents == preset.expectedGeneratedEvents)
        owner.shutdown()
    }

    @Test("surface mutation irreversibly pollutes a performance measurement")
    @MainActor
    func performanceSurfaceMutationPollution() throws {
        let preset = LabPerformancePresetCatalog.steady80
        let owner = LabRunOwner(
            manifest: LabRunManifest(
                scenario: preset.scenario,
                seed: preset.seed,
                eventRate: preset.eventRate,
                burstSize: preset.burstSize,
                filter: LabEventFilter(),
                speedLevel: .three,
                opacity: 0.9,
                displayArea: .full,
                density: .normal,
                startsPlaying: true,
                descriptor: LabScenarioDescriptor(
                    id: preset.scenario.catalogID,
                    version: 1,
                    durationSeconds: 60,
                    logicalTicksPerSecond: preset.logicalTicksPerSecond,
                    maximumTicksPerWallAdvance: preset.logicalTicksPerSecond
                )
            )
        )
        let ownerID = UUID()
        #expect(
            owner.attachSurface(
                width: preset.canvasSize.width,
                height: preset.canvasSize.height,
                backingScale: preset.requiredBackingScale,
                ownerID: ownerID
            )
        )
        #expect(owner.beginPerformanceMeasurement(preset: preset, attemptID: UUID()))

        #expect(
            !owner.updateSurface(
                width: preset.canvasSize.width - 1,
                height: preset.canvasSize.height,
                backingScale: preset.requiredBackingScale,
                ownerID: ownerID
            )
        )
        #expect(owner.lifecycle == .polluted(.surfaceChangedDuringMeasurement))
        #expect(try #require(owner.performanceRunEvidence).surfaceChangedDuringMeasurement)
        owner.shutdown()
    }

    @Test("backing-scale mutation and detach irreversibly pollute measurement")
    @MainActor
    func performanceSurfaceLifecyclePollution() throws {
        let preset = LabPerformancePresetCatalog.steady80

        let (scaleOwner, scaleOwnerID) = makePerformanceOwner(preset: preset)
        #expect(scaleOwner.beginPerformanceMeasurement(preset: preset, attemptID: UUID()))
        #expect(
            !scaleOwner.updateSurface(
                width: preset.canvasSize.width,
                height: preset.canvasSize.height,
                backingScale: preset.requiredBackingScale + 0.5,
                ownerID: scaleOwnerID
            )
        )
        #expect(scaleOwner.lifecycle == .polluted(.surfaceChangedDuringMeasurement))
        #expect(
            try #require(scaleOwner.performanceRunEvidence).surfaceChangedDuringMeasurement
        )
        scaleOwner.shutdown()

        let (detachOwner, detachOwnerID) = makePerformanceOwner(preset: preset)
        #expect(detachOwner.beginPerformanceMeasurement(preset: preset, attemptID: UUID()))
        #expect(detachOwner.detachSurface(ownerID: detachOwnerID))
        #expect(detachOwner.lifecycle == .polluted(.surfaceChangedDuringMeasurement))
        #expect(
            try #require(detachOwner.performanceRunEvidence).surfaceChangedDuringMeasurement
        )
        detachOwner.shutdown()
    }

    @Test("warmup surface mutation is terminal before measurement can begin")
    @MainActor
    func performanceWarmupSurfacePollution() async throws {
        let preset = LabPerformancePresetCatalog.steady80

        let (resizeOwner, resizeOwnerID) = makePerformanceOwner(preset: preset)
        #expect(resizeOwner.beginPerformanceWarmup(preset: preset))
        #expect(
            !resizeOwner.updateSurface(
                width: preset.canvasSize.width - 1,
                height: preset.canvasSize.height,
                backingScale: preset.requiredBackingScale,
                ownerID: resizeOwnerID
            )
        )
        #expect(resizeOwner.lifecycle == .polluted(.surfaceChangedDuringMeasurement))
        #expect(!resizeOwner.beginPerformanceMeasurement(preset: preset, attemptID: UUID()))
        resizeOwner.shutdown()

        let (scaleOwner, scaleOwnerID) = makePerformanceOwner(preset: preset)
        #expect(scaleOwner.beginPerformanceWarmup(preset: preset))
        #expect(
            !scaleOwner.updateSurface(
                width: preset.canvasSize.width,
                height: preset.canvasSize.height,
                backingScale: preset.requiredBackingScale + 0.5,
                ownerID: scaleOwnerID
            )
        )
        #expect(scaleOwner.lifecycle == .polluted(.surfaceChangedDuringMeasurement))
        scaleOwner.shutdown()

        let (detachOwner, detachOwnerID) = makePerformanceOwner(preset: preset)
        #expect(detachOwner.beginPerformanceWarmup(preset: preset))
        let terminal = Task {
            await detachOwner.waitForTerminalState()
            return detachOwner.lifecycle
        }
        await Task.yield()
        #expect(detachOwner.detachSurface(ownerID: detachOwnerID))
        #expect(await terminal.value == .polluted(.surfaceChangedDuringMeasurement))
        detachOwner.shutdown()

        let boundaryPreset = LabPerformancePreset(
            id: LabPerformancePresetID(rawValue: "test-warmup-boundary"),
            version: 1,
            displayName: "Test warmup boundary",
            scenario: .steady,
            seed: 44,
            eventRate: 10,
            burstSize: 10,
            canvasSize: CGSize(width: 320, height: 180),
            requiredBackingScale: 2,
            warmupSeconds: 0.1,
            measurementSeconds: 0.1,
            repetitions: 1,
            logicalTicksPerSecond: 10
        )
        let (boundaryOwner, boundaryOwnerID) = makePerformanceOwner(
            preset: boundaryPreset
        )
        #expect(boundaryOwner.beginPerformanceWarmup(preset: boundaryPreset))
        await boundaryOwner.waitForTerminalState()
        #expect(boundaryOwner.lifecycle == .completed)
        #expect(
            !boundaryOwner.updateSurface(
                width: boundaryPreset.canvasSize.width - 1,
                height: boundaryPreset.canvasSize.height,
                backingScale: boundaryPreset.requiredBackingScale,
                ownerID: boundaryOwnerID
            )
        )
        #expect(boundaryOwner.lifecycle == .polluted(.surfaceChangedDuringMeasurement))
        boundaryOwner.shutdown()
    }

    @Test("shutdown releases surface and terminal waiters without arbitrary sleeps")
    @MainActor
    func shutdownReleasesWaiters() async {
        let preset = LabPerformancePresetCatalog.steady80
        let (waitingOwner, waitingOwnerID) = makePerformanceOwner(preset: preset)
        #expect(waitingOwner.detachSurface(ownerID: waitingOwnerID))
        let ready = Task { await waitingOwner.waitUntilRunning() }
        await Task.yield()
        waitingOwner.shutdown()
        #expect(await ready.value == false)

        let (runningOwner, _) = makePerformanceOwner(preset: preset)
        let terminal = Task {
            await runningOwner.waitForTerminalState()
            return runningOwner.lifecycle
        }
        await Task.yield()
        runningOwner.shutdown()
        #expect(await terminal.value == .stopped)
    }

    @Test("performance owner rejects a manifest that only claims the preset identity")
    @MainActor
    func performanceManifestMismatch() {
        let preset = LabPerformancePresetCatalog.steady80
        let (owner, _) = makePerformanceOwner(preset: preset, seed: preset.seed + 1)
        #expect(!preset.matches(owner.manifest))
        #expect(!owner.beginPerformanceWarmup(preset: preset))
        #expect(!owner.beginPerformanceMeasurement(preset: preset, attemptID: UUID()))
        owner.shutdown()
    }

    @Test("performance artifact store atomically binds pending identity to structured result")
    @MainActor
    func performanceArtifactStoreContract() throws {
        let root = URL(
            fileURLWithPath:
                "/private/tmp/danmaku-lab-artifact-store-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sampleID = UUID()
        let pending = [
            "protocol-version=4",
            "sample-id=\(sampleID.uuidString.lowercased())",
            "preset=steady-80@1",
            "renderer=production-core-animation",
            "repetition=2",
            "binary-sha256=binary-hash",
            "benchmark-manifest-sha256=manifest-hash",
            "threshold-sha256=threshold-hash",
            "",
        ].joined(separator: "\n")
        try pending.write(
            to: root.appendingPathComponent("pending-sample.txt"),
            atomically: true,
            encoding: .utf8
        )
        let store = LabPerformanceArtifactStore(
            environment: [
                LabPerformanceArtifactStore.environmentKey: root.path
            ]
        )
        let pendingClaim = try store.claimPendingSample(
            presetIdentity: "steady-80@1",
            rendererID: .productionCoreAnimation,
            repetition: 2
        )
        let claimed = try #require(pendingClaim)
        #expect(claimed.sampleID == sampleID)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("pending-sample.txt").path
            )
        )

        let preset = LabPerformancePresetCatalog.steady80
        var statistics = LabStatistics()
        statistics.generated = preset.expectedGeneratedEvents
        statistics.attempted = preset.expectedGeneratedEvents
        statistics.droppedNoLane = preset.expectedGeneratedEvents
        statistics.peakActive = 86
        let evidence = LabPerformanceRunEvidence(
            attemptID: sampleID,
            presetIdentity: preset.catalogIdentity,
            logicalTicksProcessed: preset.expectedMeasurementTicks,
            expectedLogicalTicks: preset.expectedMeasurementTicks,
            generatedEvents: preset.expectedGeneratedEvents,
            expectedGeneratedEvents: preset.expectedGeneratedEvents,
            surfaceChangedDuringMeasurement: false,
            measurementDurationSeconds: 30.01
        )
        let assessment = LabPerformanceSampleAssessment(
            preset: preset,
            expectedRendererID: .productionCoreAnimation,
            rendererID: .productionCoreAnimation,
            telemetryEnabled: false,
            surfaceSize: preset.canvasSize,
            backingScale: preset.requiredBackingScale,
            lifecycle: .completed,
            statistics: statistics,
            runEvidence: evidence
        )
        try store.writeResult(
            pending: claimed,
            assessment: assessment,
            evidence: evidence,
            statistics: statistics,
            processTelemetry: LabProcessTelemetrySnapshot(
                residentBytes: 1,
                peakResidentBytes: 2,
                physicalFootprintBytes: 3,
                peakPhysicalFootprintBytes: 4,
                cpuPercentage: 5,
                hasCPUInterval: true
            )
        )
        let result = try String(
            contentsOf: root.appendingPathComponent(
                "lab-results/\(sampleID.uuidString.lowercased()).txt"
            ),
            encoding: .utf8
        )
        #expect(result.contains("sample-id=\(sampleID.uuidString.lowercased())"))
        #expect(result.contains("protocol-version=4"))
        #expect(result.contains("benchmark-manifest-sha256=manifest-hash"))
        #expect(result.contains("repetition=2"))
        #expect(result.contains("logical-ticks-actual=900"))
        #expect(result.contains("disposition=eligible"))
        #expect(result.contains("peak-active=86"))
    }

    @Test("candidate renderer is Lab-owned and tears down in an isolated run")
    @MainActor
    func candidateRendererSelectionAndTeardown() {
        let candidateID = LabRendererID(rawValue: "test-candidate")
        var createdBackend: TestDanmakuRenderingBackend?
        let candidate = LabRendererDescriptor.candidate(
            id: candidateID,
            displayName: "Test Candidate"
        ) { _ in
            let backend = TestDanmakuRenderingBackend()
            createdBackend = backend
            return LabRendererInstance(
                backend: backend,
                surfaceLayer: backend.surfaceLayer
            )
        }
        let registry = LabRendererRegistry(candidates: [candidate])

        #expect(registry.hasCandidates)
        #expect(
            registry.descriptors.map(\.id) == [
                .productionCoreAnimation,
                candidateID,
            ]
        )
        #expect(createdBackend == nil)

        let manifest = LabRunManifest(
            scenario: .standard,
            seed: 44,
            eventRate: 24,
            burstSize: 120,
            filter: LabEventFilter(),
            speedLevel: .three,
            opacity: 0.9,
            displayArea: .full,
            density: .normal,
            rendererID: candidateID,
            startsPlaying: false
        )
        let owner = LabRunOwner(
            manifest: manifest,
            rendererDescriptor: candidate
        )
        let backend = createdBackend

        #expect(backend != nil)
        #expect(owner.rendererDescriptor.id == candidateID)
        #expect(owner.statistics == LabStatistics())
        owner.shutdown()
        #expect(backend?.stopCount == 1)
        #expect(owner.lifecycle == .stopped)
        #expect(owner.statistics == LabStatistics())
    }

    @Test("production renderer handles play, pause, resize, discontinuity, and stop")
    @MainActor
    func productionRendererLifecycleSmoke() {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 1)
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: DanmakuLaneConfiguration.production(
                surfaceWidth: 640,
                surfaceHeight: 360
            )
        )
        let ownerID = UUID()
        let identity = PlaybackItemIdentity(bvid: "synthetic-lab-test", cid: 1)
        let plan = LabScenarioPlan(
            scenario: .burst,
            seed: 44,
            eventRate: 80,
            burstSize: 120
        )

        #expect(controller.attachSurface(ownerID: ownerID))
        #expect(controller.updateSurface(width: 640, height: 360, ownerID: ownerID))
        controller.apply(
            DanmakuPresentationUpdate(
                snapshot: snapshot(identity: identity, generation: 1, state: .playing),
                batch: DanmakuBatch(
                    identity: identity,
                    discontinuityGeneration: 1,
                    events: (0..<120).map(plan.event(at:)),
                    clearsExisting: false
                )
            )
        )
        #expect(renderer.activeLayerCount > 0)
        #expect(
            renderer.activeLayerCount
                <= DanmakuLaneConfiguration.hardMaximumActiveCount
        )
        #expect(controller.statistics.active == renderer.activeLayerCount)

        controller.apply(
            DanmakuPresentationUpdate(
                snapshot: snapshot(identity: identity, generation: 1, state: .paused),
                batch: nil
            )
        )
        #expect(renderer.rootLayer.speed == 0)

        #expect(controller.updateSurface(width: 960, height: 540, ownerID: ownerID))
        #expect(renderer.rootLayer.frame.size.width == 960)
        #expect(renderer.rootLayer.frame.size.height == 540)

        controller.apply(
            DanmakuPresentationUpdate(
                snapshot: snapshot(identity: identity, generation: 2, state: .playing),
                batch: DanmakuBatch(
                    identity: identity,
                    discontinuityGeneration: 2,
                    events: [],
                    clearsExisting: true
                )
            )
        )
        #expect(renderer.activeLayerCount == 0)
        #expect(controller.statistics.active == 0)

        controller.stopPresentation()
        #expect(renderer.activeLayerCount == 0)
        #expect(renderer.rootLayer.speed == 0)
        #expect(controller.detachSurface(ownerID: ownerID))
    }

    private func events(for scenario: LabScenario, count: Int) -> [DanmakuEvent] {
        let plan = LabScenarioPlan(
            scenario: scenario,
            seed: 44,
            eventRate: 30,
            burstSize: 80
        )
        return (0..<count).map(plan.event(at:))
    }

    private func snapshot(
        identity: PlaybackItemIdentity,
        generation: UInt64,
        state: PlaybackTimelineState
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: 1,
            durationSeconds: nil,
            rate: state == .playing ? 1 : 0,
            state: state,
            discontinuityGeneration: generation
        )
    }

    @MainActor
    private func makePerformanceOwner(
        preset: LabPerformancePreset,
        seed: UInt64? = nil
    ) -> (LabRunOwner, UUID) {
        let owner = LabRunOwner(
            manifest: LabRunManifest(
                scenario: preset.scenario,
                seed: seed ?? preset.seed,
                eventRate: preset.eventRate,
                burstSize: preset.burstSize,
                filter: LabEventFilter(),
                speedLevel: .three,
                opacity: 0.9,
                displayArea: .full,
                density: .normal,
                startsPlaying: true,
                descriptor: LabScenarioDescriptor(
                    id: preset.scenario.catalogID,
                    version: 1,
                    durationSeconds: 60,
                    logicalTicksPerSecond: preset.logicalTicksPerSecond,
                    maximumTicksPerWallAdvance: preset.logicalTicksPerSecond
                )
            )
        )
        let ownerID = UUID()
        precondition(
            owner.attachSurface(
                width: preset.canvasSize.width,
                height: preset.canvasSize.height,
                backingScale: preset.requiredBackingScale,
                ownerID: ownerID
            )
        )
        return (owner, ownerID)
    }
}

@MainActor
private final class TestDanmakuRenderingBackend: DanmakuRenderingBackend {
    weak var delegate: (any DanmakuRenderingBackendDelegate)?
    let surfaceLayer = CALayer()
    private(set) var stopCount = 0

    func measure(_ event: DanmakuEvent) -> DanmakuTextMetrics {
        DanmakuTextMetrics(width: 100, height: 36)
    }

    func render(_ placement: DanmakuLanePlacement) {}

    func remove(eventID: String) {}

    func clearAll() {}

    func setPlaybackRate(_ rate: Double) {
        surfaceLayer.speed = Float(rate)
    }

    func setOpacity(_ opacity: DanmakuOpacity) {
        surfaceLayer.opacity = Float(opacity.value)
    }

    func updateSurfaceSize(width: Double, height: Double) {
        surfaceLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: width,
            height: height
        )
    }

    func stop() {
        stopCount += 1
        surfaceLayer.speed = 0
    }
}
