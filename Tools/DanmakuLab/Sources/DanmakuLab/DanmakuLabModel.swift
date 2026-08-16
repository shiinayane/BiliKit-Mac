import BiliApplication
import BiliDanmaku
import DanmakuLabCore
import Foundation
import Observation
import os.signpost

enum LabPerformanceUIStatus: Equatable {
    case inactive
    case prepared(repetition: Int)
    case warmingUp(repetition: Int)
    case measuring(repetition: Int)
    case sampleComplete(
        repetition: Int,
        assessment: LabPerformanceSampleAssessment
    )
    case revisionRequired(LabPerformanceSampleAssessment)
    case finished
}

@MainActor
@Observable
final class DanmakuLabModel {
    let rendererRegistry: LabRendererRegistry
    let performanceArtifactStore: LabPerformanceArtifactStore
    var scenario = LabScenario.standard
    var seed: UInt64 = 44
    var eventRate = 24.0
    var burstSize = 120
    var filter = LabEventFilter()
    var speedLevel = DanmakuSpeedLevel.three
    var opacity = 0.9
    var displayArea = DanmakuDisplayArea.full
    var density = DanmakuDensity.normal
    var fontScale = CoreAnimationDanmakuStyle.production.fontScale
    var fontWeight = CoreAnimationDanmakuStyle.production.fontWeight
    var shadowBlurRadius = CoreAnimationDanmakuStyle.production.shadowBlurRadius
    var canvasMode = CanvasMode.free
    var background = CanvasBackground.dark
    var telemetryEnabled = true
    var selectedRendererID: LabRendererID
    var selectedPerformancePresetID =
        LabPerformancePresetCatalog.steady80.id
    var selectedPerformanceRepetition = 1
    private(set) var performanceStatus = LabPerformanceUIStatus.inactive
    private(set) var performanceAssessments: [LabPerformanceSampleAssessment] = []
    private(set) var performanceArtifactError: String?
    private(set) var runOwner: LabRunOwner

    private var isShutdown = false
    private var playbackIntent = true
    private var resumesPlaying = true
    private var performanceTask: Task<Void, Never>?
    private var performanceToken = UUID()
    private var performanceRendererID = LabRendererID.productionCoreAnimation
    private var activePerformanceSample: LabPerformancePendingSample?
    private let performanceLog = OSLog(
        subsystem: "com.shirokyan.BiliKit.DanmakuLab",
        category: "PerformanceProtocol"
    )

    init(
        rendererRegistry: LabRendererRegistry = .productionOnly,
        performanceArtifactStore: LabPerformanceArtifactStore = LabPerformanceArtifactStore()
    ) {
        self.rendererRegistry = rendererRegistry
        self.performanceArtifactStore = performanceArtifactStore
        let baseline = rendererRegistry.baseline
        selectedRendererID = baseline.id
        runOwner = LabRunOwner(
            manifest: .standard,
            rendererDescriptor: baseline
        )
    }

    var isPlaying: Bool { runOwner.isPlaying }
    var statistics: LabStatistics { runOwner.statistics }
    var surfaceSize: CGSize { runOwner.surfaceSize }
    var hasRendererCandidates: Bool { rendererRegistry.hasCandidates }
    var rendererDescriptors: [LabRendererDescriptor] {
        rendererRegistry.descriptors
    }
    var performancePreset: LabPerformancePreset {
        LabPerformancePresetCatalog.all.first {
            $0.id == selectedPerformancePresetID
        } ?? LabPerformancePresetCatalog.steady80
    }
    var performanceLocksControls: Bool {
        performanceStatus != .inactive
    }
    var performanceCanvasSize: CGSize? {
        performanceLocksControls ? performancePreset.canvasSize : nil
    }

    func activate() {
        guard isShutdown else { return }
        isShutdown = false
        replaceRun(play: resumesPlaying)
    }

    func togglePlayback() {
        guard runOwner.lifecycle == .running else { return }
        runOwner.togglePlayback()
        playbackIntent = runOwner.isPlaying
    }

    func reset() {
        replaceRun(play: false)
    }

    func deterministicReplay() {
        replaceRun(play: true)
    }

    func seekForward() {
        replaceRun(
            play: playbackIntent,
            initialPositionSeconds: runOwner.positionSeconds + 10
        )
    }

    func scenarioInputsChanged() {
        guard !performanceLocksControls else { return }
        replaceRun(play: playbackIntent)
    }

    func productionControlsChanged() {
        guard !performanceLocksControls else { return }
        runOwner.setSpeedLevel(speedLevel)
        if let opacity = DanmakuOpacity(opacity) {
            runOwner.setOpacity(opacity)
        }
        runOwner.setDisplayArea(displayArea)
        runOwner.setDensity(density)
    }

    func rendererStyleChanged() {
        guard !performanceLocksControls else { return }
        replaceRun(play: playbackIntent)
    }

    func rendererSelectionChanged() {
        guard !performanceLocksControls else { return }
        guard
            rendererRegistry.descriptor(for: selectedRendererID) != nil
        else {
            selectedRendererID = rendererRegistry.baseline.id
            return
        }
        replaceRun(play: playbackIntent)
    }

    func preparePerformanceProtocol() {
        cancelPerformanceTask()
        let preset = performancePreset
        guard rendererRegistry.descriptor(for: selectedRendererID) != nil else {
            return
        }
        scenario = preset.scenario
        seed = preset.seed
        eventRate = preset.eventRate
        burstSize = preset.burstSize
        filter = LabEventFilter()
        speedLevel = .three
        opacity = 0.9
        displayArea = .full
        density = .normal
        fontScale = CoreAnimationDanmakuStyle.production.fontScale
        fontWeight = CoreAnimationDanmakuStyle.production.fontWeight
        shadowBlurRadius =
            CoreAnimationDanmakuStyle.production.shadowBlurRadius
        canvasMode = .free
        background = .dark
        telemetryEnabled = false
        performanceRendererID = selectedRendererID
        performanceAssessments = []
        performanceArtifactError = nil
        activePerformanceSample = nil
        performanceStatus = .prepared(repetition: selectedPerformanceRepetition)
        replaceRun(play: false)
    }

    func runPerformanceRepetition() {
        let repetition: Int
        switch performanceStatus {
        case .prepared(let value):
            repetition = value
        case .inactive, .warmingUp, .measuring, .sampleComplete,
            .revisionRequired, .finished:
            return
        }
        do {
            activePerformanceSample = try performanceArtifactStore.claimPendingSample(
                presetIdentity: performancePreset.catalogIdentity,
                rendererID: performanceRendererID,
                repetition: repetition
            )
            performanceArtifactError = nil
        } catch {
            performanceArtifactError = error.localizedDescription
            return
        }
        cancelPerformanceTask()
        let token = UUID()
        performanceToken = token
        let preset = performancePreset
        performanceStatus = .warmingUp(repetition: repetition)
        replaceRun(play: false)
        let owner = runOwner
        performanceTask = Task { [weak self] in
            guard let self else { return }
            guard await owner.waitUntilRunning(),
                !Task.isCancelled,
                performanceToken == token,
                runOwner === owner
            else {
                if performanceToken == token, !Task.isCancelled {
                    completePerformanceRepetition(
                        repetition: repetition,
                        preset: preset
                    )
                }
                return
            }
            guard owner.beginPerformanceWarmup(preset: preset) else {
                completePerformanceRepetition(
                    repetition: repetition,
                    preset: preset
                )
                return
            }
            let warmupID = OSSignpostID(log: performanceLog)
            os_signpost(
                .begin,
                log: performanceLog,
                name: "DanmakuLab Warmup",
                signpostID: warmupID,
                "%{public}@ repetition=%{public}d",
                preset.catalogIdentity,
                repetition
            )
            await owner.waitForTerminalState()
            let warmupWasCancelled =
                Task.isCancelled || performanceToken != token || runOwner !== owner
            os_signpost(
                .end,
                log: performanceLog,
                name: "DanmakuLab Warmup",
                signpostID: warmupID,
                "%{public}@",
                warmupWasCancelled ? "cancelled" : "complete"
            )
            guard !warmupWasCancelled else { return }

            let attemptID = activePerformanceSample?.sampleID ?? UUID()
            guard
                owner.beginPerformanceMeasurement(
                    preset: preset,
                    attemptID: attemptID
                )
            else {
                completePerformanceRepetition(
                    repetition: repetition,
                    preset: preset
                )
                return
            }
            performanceStatus = .measuring(repetition: repetition)
            let measurementID = OSSignpostID(log: performanceLog)
            os_signpost(
                .begin,
                log: performanceLog,
                name: "DanmakuLab Measurement",
                signpostID: measurementID,
                "%{public}@ renderer=%{public}@ repetition=%{public}d attempt=%{public}@ ticks=%{public}d events=%{public}d",
                preset.catalogIdentity,
                performanceRendererID.rawValue,
                repetition,
                attemptID.uuidString,
                preset.expectedMeasurementTicks,
                preset.expectedGeneratedEvents
            )
            await owner.waitForTerminalState()
            let wasCancelled =
                Task.isCancelled || performanceToken != token || runOwner !== owner
            os_signpost(
                .end,
                log: performanceLog,
                name: "DanmakuLab Measurement",
                signpostID: measurementID,
                "%{public}@",
                wasCancelled ? "cancelled" : "complete"
            )
            guard !wasCancelled else { return }
            completePerformanceRepetition(
                repetition: repetition,
                preset: preset
            )
        }
    }

    func prepareNextPerformanceRepetition() {
        guard
            case .sampleComplete(_, let assessment) =
                performanceStatus,
            assessment.disposition == .eligibleForTraceReview
        else {
            return
        }
        performanceStatus = .finished
    }

    func exitPerformanceProtocol() {
        cancelPerformanceTask()
        performanceStatus = .inactive
        performanceAssessments = []
        activePerformanceSample = nil
        performanceArtifactError = nil
        telemetryEnabled = true
        replaceRun(play: false)
    }

    func shutdown() {
        guard !isShutdown else { return }
        cancelPerformanceTask()
        resumesPlaying = playbackIntent
        isShutdown = true
        runOwner.shutdown()
    }

    private func replaceRun(
        play: Bool,
        initialPositionSeconds: Double = 0
    ) {
        playbackIntent = play
        let rendererDescriptor =
            rendererRegistry.descriptor(for: selectedRendererID)
            ?? rendererRegistry.baseline
        let replacement = LabRunOwner(
            manifest: LabRunManifest(
                scenario: scenario,
                seed: seed,
                eventRate: eventRate,
                burstSize: burstSize,
                filter: filter,
                speedLevel: speedLevel,
                opacity: opacity,
                displayArea: displayArea,
                density: density,
                rendererStyle: CoreAnimationDanmakuStyle(
                    fontScale: fontScale,
                    fontWeight: fontWeight,
                    shadowBlurRadius: shadowBlurRadius
                ),
                rendererID: rendererDescriptor.id,
                startsPlaying: play,
                initialPositionSeconds: initialPositionSeconds,
                descriptor: performanceDescriptor
            ),
            rendererDescriptor: rendererDescriptor
        )
        runOwner.shutdown()
        runOwner = replacement
    }

    private func completePerformanceRepetition(
        repetition: Int,
        preset: LabPerformancePreset
    ) {
        let assessment = LabPerformanceSampleAssessment(
            preset: preset,
            expectedRendererID: performanceRendererID,
            rendererID: runOwner.manifest.rendererID,
            telemetryEnabled: telemetryEnabled,
            surfaceSize: runOwner.surfaceSize,
            backingScale: runOwner.surfaceBackingScale,
            lifecycle: runOwner.lifecycle,
            statistics: runOwner.statistics,
            runEvidence: runOwner.performanceRunEvidence
        )
        if let activePerformanceSample {
            do {
                try performanceArtifactStore.writeResult(
                    pending: activePerformanceSample,
                    assessment: assessment,
                    evidence: runOwner.performanceRunEvidence,
                    statistics: runOwner.statistics,
                    processTelemetry: runOwner.processTelemetry
                )
                self.activePerformanceSample = nil
                performanceArtifactError = nil
            } catch {
                performanceArtifactError = error.localizedDescription
            }
        }
        if runOwner.isPlaying {
            runOwner.togglePlayback()
        }
        switch assessment.disposition {
        case .polluted:
            performanceStatus = .sampleComplete(
                repetition: repetition,
                assessment: assessment
            )
        case .revise:
            performanceAssessments.append(assessment)
            performanceStatus = .revisionRequired(assessment)
        case .eligibleForTraceReview:
            performanceAssessments.append(assessment)
            performanceStatus = .sampleComplete(
                repetition: repetition,
                assessment: assessment
            )
        }
    }

    private func cancelPerformanceTask() {
        performanceToken = UUID()
        performanceTask?.cancel()
        performanceTask = nil
    }

    private var performanceDescriptor: LabScenarioDescriptor? {
        guard performanceLocksControls else { return nil }
        let preset = performancePreset
        return LabScenarioDescriptor(
            id: preset.scenario.catalogID,
            version: 1,
            durationSeconds: LabScenarioCatalog.descriptor(
                for: preset.scenario
            ).durationSeconds,
            logicalTicksPerSecond: preset.logicalTicksPerSecond,
            maximumTicksPerWallAdvance: preset.logicalTicksPerSecond
        )
    }
}

enum CanvasMode: String, CaseIterable, Identifiable {
    case free = "Free"
    case sixteenByNine = "16:9"

    var id: Self { self }
}

enum CanvasBackground: String, CaseIterable, Identifiable {
    case dark = "Dark"
    case light = "Light"
    case solid = "Solid"
    case gradient = "Gradient"
    case highContrast = "High contrast"

    var id: Self { self }
}
