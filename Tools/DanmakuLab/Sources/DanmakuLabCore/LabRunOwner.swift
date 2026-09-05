import BiliApplication
import BiliDanmaku
import BiliModels
import Foundation
import Observation

public enum LabRunLifecycle: Sendable, Equatable {
    case waitingForSurface
    case running
    case completed
    case polluted(LabRunPollution)
    case stopped
}

@MainActor
@Observable
public final class LabRunOwner {
    public let id = UUID()
    public let manifest: LabRunManifest
    public let rendererDescriptor: LabRendererDescriptor
    public let renderer: LabRendererInstance
    public private(set) var controller: DanmakuPresentationController
    public private(set) var lifecycle = LabRunLifecycle.waitingForSurface
    public private(set) var statistics = LabStatistics()
    public private(set) var surfaceSize = CGSize(width: 1280, height: 720)
    public private(set) var surfaceBackingScale = 0.0
    public private(set) var frameTelemetry = LabFrameTelemetrySnapshot.zero
    public private(set) var processTelemetry = LabProcessTelemetrySnapshot.zero
    public private(set) var performanceRunEvidence: LabPerformanceRunEvidence?

    private let identity = PlaybackItemIdentity(
        bvid: "synthetic-danmaku-lab",
        cid: 1
    )
    private let wallClock = ContinuousClock()
    private var logicalClock: LabLogicalClock
    private var playback = LabPlaybackState()
    private var clockTask: Task<Void, Never>?
    private var lastWallSample: ContinuousClock.Instant?
    private var nextEventIndex = 0
    private var surfaceOwnerID: UUID?
    private var workingStatistics = LabStatistics()
    private var readyContinuation: CheckedContinuation<Bool, Never>?
    private var terminalContinuation: CheckedContinuation<Void, Never>?
    private var performanceAttemptID: UUID?
    private var performancePresetIdentity: String?
    private var expectedPerformanceTicks = 0
    private var expectedPerformanceEvents = 0
    private var isFormalPerformanceRunActive = false
    private var isPerformanceMeasurementActive = false
    private var surfaceChangedDuringMeasurement = false
    private var performanceTerminalPollution: LabRunPollution?
    private var lastFormalProcessSample: ContinuousClock.Instant?
    private var performanceMeasurementStartedAt: ContinuousClock.Instant?
    @ObservationIgnored
    private var frameTelemetryAccumulator = LabFrameTelemetryAccumulator()
    @ObservationIgnored
    private var processTelemetryAccumulator = LabProcessTelemetryAccumulator()

    public init(
        manifest: LabRunManifest,
        rendererDescriptor: LabRendererDescriptor = .productionCoreAnimation
    ) {
        precondition(manifest.rendererID == rendererDescriptor.id)
        self.manifest = manifest
        self.rendererDescriptor = rendererDescriptor
        logicalClock = LabLogicalClock(
            ticksPerSecond: manifest.descriptor.logicalTicksPerSecond,
            maximumTicksPerWallAdvance:
                manifest.descriptor.maximumTicksPerWallAdvance,
            durationSeconds: manifest.descriptor.durationSeconds,
            initialPositionSeconds: manifest.initialPositionSeconds,
            isPlaying: manifest.startsPlaying
        )
        let renderer = rendererDescriptor.makeRenderer(
            style: manifest.rendererStyle
        )
        self.renderer = renderer
        controller = DanmakuPresentationController(
            backend: renderer.backend,
            configuration: DanmakuLaneConfiguration.production(
                surfaceWidth: 1280,
                surfaceHeight: 720
            )
        )
        if manifest.initialPositionSeconds > 0 {
            playback.seekForward(by: manifest.initialPositionSeconds)
        }
        if manifest.startsPlaying {
            playback.play()
        }
        applyProductionControls(manifest)
    }

    public var isPlaying: Bool {
        lifecycle == .running && logicalClock.isPlaying
    }

    public var positionSeconds: Double { logicalClock.positionSeconds }

    @discardableResult
    public func attachSurface(
        width: Double,
        height: Double,
        backingScale: Double = 2,
        ownerID: UUID
    ) -> Bool {
        guard lifecycle == .waitingForSurface,
            width.isFinite,
            height.isFinite,
            width > 0,
            height > 0,
            backingScale.isFinite,
            backingScale > 0
        else {
            return false
        }
        guard controller.attachSurface(ownerID: ownerID),
            controller.updateSurface(
                width: width,
                height: height,
                backingScale: backingScale,
                ownerID: ownerID
            )
        else {
            return false
        }
        surfaceOwnerID = ownerID
        surfaceSize = CGSize(width: width, height: height)
        surfaceBackingScale = backingScale
        lifecycle = .running
        lastWallSample = wallClock.now
        publish(batch: clearBatch())
        startClock()
        readyContinuation?.resume(returning: true)
        readyContinuation = nil
        return true
    }

    @discardableResult
    public func updateSurface(
        width: Double,
        height: Double,
        backingScale: Double = 2,
        ownerID: UUID
    ) -> Bool {
        let proposedSize = CGSize(width: width, height: height)
        if isFormalPerformanceRunActive,
            surfaceOwnerID == ownerID,
            width.isFinite,
            height.isFinite,
            width > 0,
            height > 0,
            backingScale.isFinite,
            backingScale > 0,
            proposedSize != surfaceSize || backingScale != surfaceBackingScale
        {
            surfaceChangedDuringMeasurement = true
            markPolluted(.surfaceChangedDuringMeasurement)
            return false
        }
        guard lifecycle == .running,
            surfaceOwnerID == ownerID,
            width.isFinite,
            height.isFinite,
            width > 0,
            height > 0,
            backingScale.isFinite,
            backingScale > 0,
            controller.updateSurface(
                width: width,
                height: height,
                backingScale: backingScale,
                ownerID: ownerID
            )
        else {
            return false
        }
        surfaceSize = proposedSize
        surfaceBackingScale = backingScale
        return true
    }

    @discardableResult
    public func detachSurface(ownerID: UUID) -> Bool {
        guard surfaceOwnerID == ownerID else { return false }
        if isFormalPerformanceRunActive {
            surfaceChangedDuringMeasurement = true
            markPolluted(.surfaceChangedDuringMeasurement)
        }
        cancelClock()
        let detached = controller.detachSurface(ownerID: ownerID)
        controller.stopPresentation()
        surfaceOwnerID = nil
        if lifecycle == .running {
            lifecycle = .waitingForSurface
        }
        return detached
    }

    public func waitUntilRunning() async -> Bool {
        switch lifecycle {
        case .running:
            return true
        case .waitingForSurface:
            return await withCheckedContinuation { continuation in
                precondition(readyContinuation == nil)
                readyContinuation = continuation
            }
        case .completed, .polluted, .stopped:
            return false
        }
    }

    public func beginPerformanceMeasurement(
        preset: LabPerformancePreset,
        attemptID: UUID
    ) -> Bool {
        guard lifecycle == .running || lifecycle == .completed,
            let surfaceOwnerID,
            surfaceSize == preset.canvasSize,
            abs(surfaceBackingScale - preset.requiredBackingScale) <= 0.01,
            preset.matches(manifest)
        else {
            return false
        }

        cancelClock()
        controller.stopPresentation()
        controller = DanmakuPresentationController(
            backend: renderer.backend,
            configuration: DanmakuLaneConfiguration.production(
                surfaceWidth: surfaceSize.width,
                surfaceHeight: surfaceSize.height
            )
        )
        guard controller.attachSurface(ownerID: surfaceOwnerID),
            controller.updateSurface(
                width: surfaceSize.width,
                height: surfaceSize.height,
                backingScale: surfaceBackingScale,
                ownerID: surfaceOwnerID
            )
        else {
            return false
        }
        applyProductionControls(manifest)
        logicalClock = LabLogicalClock(
            ticksPerSecond: preset.logicalTicksPerSecond,
            maximumTicksPerWallAdvance: preset.logicalTicksPerSecond,
            durationSeconds: preset.measurementSeconds,
            isPlaying: true
        )
        playback.reset(play: true)
        nextEventIndex = 0
        workingStatistics = LabStatistics()
        statistics = LabStatistics()
        performanceRunEvidence = nil
        performanceAttemptID = attemptID
        performancePresetIdentity = preset.catalogIdentity
        expectedPerformanceTicks = preset.expectedMeasurementTicks
        expectedPerformanceEvents = preset.expectedGeneratedEvents
        surfaceChangedDuringMeasurement = false
        performanceTerminalPollution = nil
        isFormalPerformanceRunActive = true
        isPerformanceMeasurementActive = true
        processTelemetryAccumulator.reset()
        processTelemetry = .zero
        lastFormalProcessSample = nil
        performanceMeasurementStartedAt = wallClock.now
        lastWallSample = wallClock.now
        lifecycle = .running
        publish(batch: clearBatch())
        sampleFormalProcessTelemetryIfNeeded(force: true)
        startClock()
        return true
    }

    public func beginPerformanceWarmup(
        preset: LabPerformancePreset
    ) -> Bool {
        guard lifecycle == .running,
            surfaceSize == preset.canvasSize,
            abs(surfaceBackingScale - preset.requiredBackingScale) <= 0.01,
            preset.matches(manifest)
        else {
            return false
        }
        cancelClock()
        controller.clearPresentation()
        logicalClock = LabLogicalClock(
            ticksPerSecond: preset.logicalTicksPerSecond,
            maximumTicksPerWallAdvance: preset.logicalTicksPerSecond,
            durationSeconds: preset.warmupSeconds,
            isPlaying: true
        )
        playback.reset(play: true)
        nextEventIndex = 0
        workingStatistics = LabStatistics()
        statistics = LabStatistics()
        performanceRunEvidence = nil
        surfaceChangedDuringMeasurement = false
        performanceTerminalPollution = nil
        isFormalPerformanceRunActive = true
        lastWallSample = wallClock.now
        publish(batch: clearBatch())
        startClock()
        return true
    }

    public func waitForTerminalState() async {
        switch lifecycle {
        case .completed, .polluted, .stopped:
            return
        case .waitingForSurface, .running:
            await withCheckedContinuation { continuation in
                precondition(terminalContinuation == nil)
                terminalContinuation = continuation
            }
        }
    }

    public func togglePlayback() {
        guard lifecycle == .running else { return }
        let shouldPlay = !logicalClock.isPlaying
        logicalClock.setPlaying(shouldPlay)
        if shouldPlay {
            playback.play()
        } else {
            playback.pause()
        }
        lastWallSample = wallClock.now
        publish(batch: nil)
    }

    public func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {
        controller.setSpeedLevel(speedLevel)
    }

    public func setOpacity(_ opacity: DanmakuOpacity) {
        controller.setOpacity(opacity)
    }

    public func setDisplayArea(_ displayArea: DanmakuDisplayArea) {
        controller.setDisplayArea(displayArea)
    }

    public func setDensity(_ density: DanmakuDensity) {
        controller.setDensity(density)
    }

    public func recordDisplayFrame(timestamp: Double, targetDuration: Double) {
        let dropped = statistics.droppedNoLane.addingReportingOverflow(
            statistics.droppedCapacity
        )
        let totals = LabTelemetryTotals(
            generated: statistics.generated,
            admitted: statistics.admitted,
            dropped: dropped.overflow ? Int.max : dropped.partialValue
        )
        if let snapshot = frameTelemetryAccumulator.record(
            timestamp: timestamp,
            targetDuration: targetDuration,
            totals: totals
        ) {
            frameTelemetry = snapshot
            if let processSample = LabProcessMetricsSampler.sample(
                timestamp: timestamp
            ),
                let processSnapshot = processTelemetryAccumulator.record(
                    processSample
                )
            {
                processTelemetry = processSnapshot
            }
        }
    }

    public func resetDisplayTelemetry() {
        frameTelemetryAccumulator.reset()
        processTelemetryAccumulator.reset()
        frameTelemetry = .zero
        processTelemetry = .zero
    }

    public func shutdown() {
        guard lifecycle != .stopped else { return }
        cancelClock()
        controller.stopPresentation()
        resetDisplayTelemetry()
        lifecycle = .stopped
        isFormalPerformanceRunActive = false
        isPerformanceMeasurementActive = false
        readyContinuation?.resume(returning: false)
        readyContinuation = nil
        terminalContinuation?.resume()
        terminalContinuation = nil
    }

    private func startClock() {
        guard clockTask == nil, lifecycle == .running else { return }
        let wallClock = self.wallClock
        let intervalMilliseconds = max(
            1,
            1_000 / logicalClock.ticksPerSecond
        )
        clockTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await wallClock.sleep(
                        for: .milliseconds(intervalMilliseconds)
                    )
                    guard !Task.isCancelled, let self else { return }
                    self.consumeWallClock()
                }
            } catch {
                return
            }
        }
    }

    private func cancelClock() {
        clockTask?.cancel()
        clockTask = nil
        lastWallSample = nil
    }

    private func consumeWallClock() {
        guard lifecycle == .running else { return }
        let now = wallClock.now
        guard let lastWallSample else {
            self.lastWallSample = now
            return
        }
        self.lastWallSample = now
        guard
            let wallNanoseconds = nanoseconds(
                from: lastWallSample.duration(to: now)
            )
        else {
            markPolluted(.wallClockOverflow)
            return
        }
        let advance = logicalClock.advance(wallNanoseconds: wallNanoseconds)
        for ordinal in advance.tickOrdinals {
            guard lifecycle == .running else { break }
            processLogicalTick(ordinal: ordinal)
        }
        switch advance.state {
        case .running:
            if advance.tickOrdinals.isEmpty {
                publish(batch: nil)
            }
        case .completed:
            playback.pause()
            publish(batch: nil)
            cancelClock()
            lifecycle = .completed
            if isPerformanceMeasurementActive {
                finishPerformanceMeasurementIfNeeded()
            } else {
                terminalContinuation?.resume()
                terminalContinuation = nil
            }
        case .polluted(let pollution):
            markPolluted(pollution)
        }
    }

    private func processLogicalTick(ordinal: Int) {
        let logicalPosition =
            Double(ordinal + 1)
            / Double(manifest.descriptor.logicalTicksPerSecond)
        playback.advance(to: logicalPosition)
        workingStatistics.logicalTicksProcessed += 1

        let plan = manifest.plan
        let dueCount = plan.scheduledCount(at: playback.positionSeconds)
        guard dueCount > nextEventIndex else {
            publish(batch: nil)
            return
        }

        let rawDueCount = dueCount - nextEventIndex
        guard rawDueCount <= LabScenarioPlan.maximumEventsPerTick else {
            workingStatistics.generatorOverflow += rawDueCount
            markPolluted(
                .eventBatchExceeded(
                    pendingEvents: rawDueCount,
                    maximumEvents: LabScenarioPlan.maximumEventsPerTick
                )
            )
            return
        }
        workingStatistics.generated += rawDueCount

        let generated = (nextEventIndex..<dueCount).map(plan.event(at:))
        let events = generated.filter(manifest.filter.allows)
        workingStatistics.filtered += generated.count - events.count
        workingStatistics.attempted += events.count
        nextEventIndex = dueCount

        publish(
            batch: DanmakuBatch(
                identity: identity,
                discontinuityGeneration: playback.discontinuityGeneration,
                events: events,
                clearsExisting: false
            )
        )
    }

    private func markPolluted(_ pollution: LabRunPollution) {
        cancelClock()
        logicalClock.setPlaying(false)
        playback.pause()
        controller.stopPresentation()
        performanceTerminalPollution = pollution
        lifecycle = .polluted(pollution)
        finishPerformanceMeasurementIfNeeded()
        isFormalPerformanceRunActive = false
        readyContinuation?.resume(returning: false)
        readyContinuation = nil
        terminalContinuation?.resume()
        terminalContinuation = nil
    }

    private func clearBatch() -> DanmakuBatch {
        DanmakuBatch(
            identity: identity,
            discontinuityGeneration: playback.discontinuityGeneration,
            events: [],
            clearsExisting: true
        )
    }

    private func publish(batch: DanmakuBatch?) {
        controller.apply(
            DanmakuPresentationUpdate(
                snapshot: playback.snapshot(identity: identity),
                batch: batch
            )
        )
        workingStatistics.mapRenderer(LabRendererSnapshot(controller.statistics))
        if !isPerformanceMeasurementActive {
            statistics = workingStatistics
        } else {
            sampleFormalProcessTelemetryIfNeeded(force: false)
        }
    }

    private func applyProductionControls(_ manifest: LabRunManifest) {
        controller.setSpeedLevel(manifest.speedLevel)
        if let opacity = DanmakuOpacity(manifest.opacity) {
            controller.setOpacity(opacity)
        }
        controller.setDisplayArea(manifest.displayArea)
        controller.setDensity(manifest.density)
    }

    private func nanoseconds(from duration: Duration) -> Int64? {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            return nil
        }
        let seconds = components.seconds.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        guard !seconds.overflow else { return nil }
        let attoseconds = components.attoseconds / 1_000_000_000
        guard let fractional = Int64(exactly: attoseconds) else { return nil }
        let sum = seconds.partialValue.addingReportingOverflow(fractional)
        return sum.overflow ? nil : sum.partialValue
    }

    private func finishPerformanceMeasurementIfNeeded() {
        guard isPerformanceMeasurementActive,
            let attemptID = performanceAttemptID,
            let presetIdentity = performancePresetIdentity
        else {
            return
        }
        sampleFormalProcessTelemetryIfNeeded(force: true)
        isPerformanceMeasurementActive = false
        isFormalPerformanceRunActive = false
        statistics = workingStatistics
        performanceRunEvidence = LabPerformanceRunEvidence(
            attemptID: attemptID,
            presetIdentity: presetIdentity,
            logicalTicksProcessed: workingStatistics.logicalTicksProcessed,
            expectedLogicalTicks: expectedPerformanceTicks,
            generatedEvents: workingStatistics.generated,
            expectedGeneratedEvents: expectedPerformanceEvents,
            surfaceChangedDuringMeasurement: surfaceChangedDuringMeasurement,
            manifestMatchesPreset: true,
            terminalPollution: performanceTerminalPollution,
            measurementDurationSeconds: performanceMeasurementStartedAt.map {
                Self.seconds(from: $0.duration(to: wallClock.now))
            } ?? 0
        )
        performanceMeasurementStartedAt = nil
        terminalContinuation?.resume()
        terminalContinuation = nil
    }

    private func sampleFormalProcessTelemetryIfNeeded(force: Bool) {
        guard isPerformanceMeasurementActive else { return }
        let now = wallClock.now
        if !force, let lastFormalProcessSample,
            lastFormalProcessSample.duration(to: now) < .seconds(1)
        {
            return
        }
        lastFormalProcessSample = now
        guard
            let sample = LabProcessMetricsSampler.sample(
                timestamp: ProcessInfo.processInfo.systemUptime
            ),
            let snapshot = processTelemetryAccumulator.record(sample)
        else {
            return
        }
        processTelemetry = snapshot
    }

    private static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
