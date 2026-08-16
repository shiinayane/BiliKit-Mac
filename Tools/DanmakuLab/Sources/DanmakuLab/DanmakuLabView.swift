import BiliApplication
import BiliDanmaku
import DanmakuLabCore
import SwiftUI

struct DanmakuLabView: View {
    @State private var model = DanmakuLabModel()

    var body: some View {
        HSplitView {
            controls
                .frame(minWidth: 290, idealWidth: 320, maxWidth: 360)
            preview
                .frame(minWidth: 620)
        }
        .onAppear {
            model.activate()
        }
        .onDisappear {
            model.shutdown()
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Danmaku Lab")
                        .font(.title2.bold())
                    Text("Production Core Animation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                performanceProtocolControls

                GroupBox("Playback") {
                    HStack {
                        Button(model.isPlaying ? "Pause" : "Play") {
                            model.togglePlayback()
                        }
                        Button("Reset") { model.reset() }
                        Button("Replay") { model.deterministicReplay() }
                    }
                    .buttonStyle(.bordered)
                    Button("Seek +10s / reseed") { model.seekForward() }
                        .buttonStyle(.bordered)
                }
                .disabled(model.performanceLocksControls)

                GroupBox("Deterministic input") {
                    formRow("Scenario") {
                        Picker("Scenario", selection: $model.scenario) {
                            ForEach(LabScenario.allCases) { scenario in
                                Text(scenario.rawValue).tag(scenario)
                            }
                        }
                        .labelsHidden()
                    }
                    formRow("Seed") {
                        TextField("Seed", value: $model.seed, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                    sliderRow("Rate", value: $model.eventRate, range: 1...120, suffix: "events/s")
                    Stepper(
                        "Burst size: \(model.burstSize)",
                        value: $model.burstSize,
                        in: 1...640,
                        step: 10
                    )
                }
                .onChange(of: model.scenario) { model.scenarioInputsChanged() }
                .onChange(of: model.seed) { model.scenarioInputsChanged() }
                .onChange(of: model.eventRate) { model.scenarioInputsChanged() }
                .onChange(of: model.burstSize) { model.scenarioInputsChanged() }
                .disabled(model.performanceLocksControls)

                GroupBox("Generated events") {
                    VStack(alignment: .leading, spacing: 10) {
                        compactToggleRow("Modes") {
                            compactToggle("Scroll", isOn: $model.filter.showsScrolling)
                            compactToggle("Top", isOn: $model.filter.showsTop)
                            compactToggle("Bottom", isOn: $model.filter.showsBottom)
                        }
                        compactToggleRow("Received font sizes") {
                            compactToggle("18 pt", isOn: $model.filter.showsSmall)
                            compactToggle("25 pt", isOn: $model.filter.showsStandard)
                            compactToggle("36 pt", isOn: $model.filter.showsLarge)
                        }
                    }
                }
                .onChange(of: model.filter) { model.scenarioInputsChanged() }
                .disabled(model.performanceLocksControls)

                if model.hasRendererCandidates {
                    GroupBox("Visual renderer A/B") {
                        pickerRow(
                            "Renderer",
                            selection: $model.selectedRendererID
                        ) {
                            ForEach(model.rendererDescriptors) { descriptor in
                                Text(descriptor.displayName)
                                    .tag(descriptor.id)
                            }
                        }
                        Text(
                            "Manual visual comparison only. Quantitative runs must use one renderer per process."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .onChange(of: model.selectedRendererID) {
                        model.rendererSelectionChanged()
                    }
                    .disabled(model.performanceLocksControls)
                }

                GroupBox("Renderer style") {
                    visualSliderRow(
                        "Font scale",
                        value: $model.fontScale,
                        range: CoreAnimationDanmakuStyle.fontScaleRange,
                        step: 0.05,
                        suffix: "×",
                        fractionDigits: 2
                    )
                    pickerRow("Weight", selection: $model.fontWeight) {
                        ForEach(CoreAnimationDanmakuFontWeight.allCases, id: \.self) { weight in
                            Text(weight.rawValue.capitalized).tag(weight)
                        }
                    }
                    visualSliderRow(
                        "Shadow blur",
                        value: $model.shadowBlurRadius,
                        range: CoreAnimationDanmakuStyle.shadowBlurRadiusRange,
                        step: 0.25,
                        suffix: "pt",
                        fractionDigits: 2
                    )
                    Text(
                        "Changing renderer style restarts the run with the same deterministic input."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .onChange(of: model.fontScale) { model.rendererStyleChanged() }
                .onChange(of: model.fontWeight) { model.rendererStyleChanged() }
                .onChange(of: model.shadowBlurRadius) { model.rendererStyleChanged() }
                .disabled(model.performanceLocksControls)

                GroupBox("Production controls") {
                    speedSliderRow(selection: $model.speedLevel)
                    sliderRow("Opacity", value: $model.opacity, range: 0.2...1, suffix: "")
                    pickerRow("Area", selection: $model.displayArea) {
                        ForEach(DanmakuDisplayArea.allCases, id: \.self) { area in
                            Text("\(area.rawValue)%").tag(area)
                        }
                    }
                    pickerRow("Density", selection: $model.density) {
                        Text("Normal").tag(DanmakuDensity.normal)
                        Text("Increased").tag(DanmakuDensity.increased)
                        Text("Overlapping").tag(DanmakuDensity.overlapping)
                    }
                }
                .onChange(of: model.speedLevel) { model.productionControlsChanged() }
                .onChange(of: model.opacity) { model.productionControlsChanged() }
                .onChange(of: model.displayArea) { model.productionControlsChanged() }
                .onChange(of: model.density) { model.productionControlsChanged() }
                .disabled(model.performanceLocksControls)

                GroupBox("Canvas") {
                    pickerRow("Shape", selection: $model.canvasMode) {
                        ForEach(CanvasMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    pickerRow("Background", selection: $model.background) {
                        ForEach(CanvasBackground.allCases) { background in
                            Text(background.rawValue).tag(background)
                        }
                    }
                }
                .disabled(model.performanceLocksControls)

                GroupBox("Diagnostics") {
                    Toggle("Display telemetry", isOn: $model.telemetryEnabled)
                        .toggleStyle(.checkbox)
                    Text(
                        "Lab-only display-link cadence. Disable it for formal performance traces."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .disabled(model.performanceLocksControls)

                Text("Synthetic data only. No network, credentials, video, or persistence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private var preview: some View {
        GeometryReader { proxy in
            let size = canvasSize(in: proxy.size)
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                ZStack(alignment: .topLeading) {
                    backgroundView
                    DanmakuSurfaceView(
                        runOwner: model.runOwner,
                        telemetryEnabled: model.telemetryEnabled
                    )
                    if model.performanceLocksControls {
                        performanceCanvasNotice
                            .padding(12)
                    } else {
                        statisticsHUD
                            .padding(12)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                }
                .shadow(radius: 8)
            }
            .padding(16)
        }
    }

    private var performanceProtocolControls: some View {
        GroupBox("Performance protocol") {
            VStack(alignment: .leading, spacing: 8) {
                if case .inactive = model.performanceStatus {
                    pickerRow(
                        "Preset",
                        selection: $model.selectedPerformancePresetID
                    ) {
                        ForEach(LabPerformancePresetCatalog.all) { preset in
                            Text(preset.displayName).tag(preset.id)
                        }
                    }
                    Stepper(
                        "Repetition: \(model.selectedPerformanceRepetition) / \(model.performancePreset.repetitions)",
                        value: $model.selectedPerformanceRepetition,
                        in: 1...model.performancePreset.repetitions
                    )
                    performancePresetSummary
                    if let error = model.performanceArtifactError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button("Prepare Release trace run") {
                        model.preparePerformanceProtocol()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text(performanceStatusText)
                        .font(.subheadline.bold())
                    performancePresetSummary
                    if let error = model.performanceArtifactError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    performanceProtocolActions
                    Button("Exit protocol") {
                        model.exitPerformanceProtocol()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var performancePresetSummary: some View {
        let preset = model.performancePreset
        return VStack(alignment: .leading, spacing: 2) {
            Text(preset.catalogIdentity)
            Text("renderer \(model.selectedRendererID.rawValue)")
            Text(
                "\(Int(preset.canvasSize.width)) × \(Int(preset.canvasSize.height)) pt @ \(preset.requiredBackingScale, specifier: "%.0f")×"
            )
            Text(
                "warmup \(preset.warmupSeconds, specifier: "%.0f")s · measure \(preset.measurementSeconds, specifier: "%.0f")s · \(preset.repetitions) repetitions"
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var performanceProtocolActions: some View {
        switch model.performanceStatus {
        case .inactive:
            EmptyView()
        case .prepared(let repetition):
            Button("Run repetition \(repetition)") {
                model.runPerformanceRepetition()
            }
            .buttonStyle(.borderedProminent)
        case .warmingUp(let repetition):
            Text("Repetition \(repetition): warmup signpost active")
                .foregroundStyle(.orange)
        case .measuring(let repetition):
            Text("Repetition \(repetition): measurement signpost active")
                .foregroundStyle(.green)
        case .sampleComplete(_, let assessment):
            Text(assessmentText(assessment))
                .foregroundStyle(
                    assessment.disposition == .polluted ? .orange : .green
                )
            performanceRunEvidence
            if assessment.disposition == .polluted {
                Text(
                    "Finalize this polluted attempt, then relaunch a fresh process for the same repetition."
                )
                .font(.caption)
            } else {
                Button(
                    "Finish this process"
                ) {
                    model.prepareNextPerformanceRepetition()
                }
                .buttonStyle(.borderedProminent)
            }
        case .revisionRequired(let assessment):
            Text(assessmentText(assessment))
                .foregroundStyle(.red)
            performanceRunEvidence
            Text("REVISION REQUIRED — do not tune the workload.")
                .font(.caption.bold())
        case .finished:
            Text(
                "\(model.performanceAssessments.count) samples eligible for trace review."
            )
            .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var performanceRunEvidence: some View {
        if let evidence = model.runOwner.performanceRunEvidence {
            let stats = model.runOwner.statistics
            let process = model.runOwner.processTelemetry
            VStack(alignment: .leading, spacing: 2) {
                Text("attempt \(evidence.attemptID.uuidString)")
                Text(
                    "ticks \(evidence.logicalTicksProcessed) / \(evidence.expectedLogicalTicks) · generated \(evidence.generatedEvents) / \(evidence.expectedGeneratedEvents)"
                )
                Text(
                    "admitted \(stats.admitted) · dropped \(stats.droppedNoLane + stats.droppedCapacity) · peak active \(stats.peakActive)"
                )
                Text(
                    "rss peak \(mebibytes(process.peakResidentBytes)) MiB · footprint peak \(mebibytes(process.peakPhysicalFootprintBytes)) MiB"
                )
                Text("1 Hz task_vm_info memory sampler; trace evidence remains separate")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.monospaced())
            .textSelection(.enabled)
        }
    }

    private var performanceStatusText: String {
        switch model.performanceStatus {
        case .inactive:
            "INACTIVE"
        case .prepared(let repetition):
            "PREPARED · repetition \(repetition)"
        case .warmingUp(let repetition):
            "WARMUP · repetition \(repetition)"
        case .measuring(let repetition):
            "MEASURING · repetition \(repetition)"
        case .sampleComplete(let repetition, _):
            "SAMPLE COMPLETE · repetition \(repetition)"
        case .revisionRequired:
            "REVISE"
        case .finished:
            "LAB RUNS COMPLETE"
        }
    }

    private func assessmentText(
        _ assessment: LabPerformanceSampleAssessment
    ) -> String {
        switch assessment.disposition {
        case .polluted:
            "POLLUTED · \(assessment.pollution.map(\.displayName).joined(separator: ", "))"
        case .revise:
            "REVISE · \(assessment.contractFailures.map(\.displayName).joined(separator: ", "))"
        case .eligibleForTraceReview:
            "ELIGIBLE FOR TRACE REVIEW"
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch model.background {
        case .dark:
            Color(red: 0.08, green: 0.09, blue: 0.12)
        case .light:
            Color(red: 0.93, green: 0.94, blue: 0.96)
        case .solid:
            Color(red: 0.08, green: 0.20, blue: 0.36)
        case .gradient:
            LinearGradient(
                colors: [.indigo, .cyan, .orange],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .highContrast:
            ZStack {
                Color.black
                HStack(spacing: 0) {
                    Color.white
                    Color.black
                }
                .opacity(0.35)
            }
        }
    }

    private var statisticsHUD: some View {
        let stats = model.statistics
        let telemetry = model.runOwner.frameTelemetry
        let process = model.runOwner.processTelemetry
        return VStack(alignment: .leading, spacing: 3) {
            Text(model.runOwner.lifecycle.displayName)
                .font(.caption.bold())
            Text(model.runOwner.rendererDescriptor.displayName)
            Text("generated \(stats.generated)  attempted \(stats.attempted)")
            Text("admitted \(stats.admitted)  no lane \(stats.droppedNoLane)")
            Text(
                "capacity \(stats.droppedCapacity)  active \(stats.active) / peak \(stats.peakActive)"
            )
            if stats.filtered > 0 || stats.generatorOverflow > 0 {
                Text("filtered \(stats.filtered)  generator-overflow \(stats.generatorOverflow)")
            }
            Text(
                "\(model.eventRate, specifier: "%.0f") events/s  seed \(model.seed)  ticks \(stats.logicalTicksProcessed)"
            )
            Text(model.runOwner.manifest.inputSummary)
            Text("\(Int(model.surfaceSize.width)) × \(Int(model.surfaceSize.height))")
            if model.telemetryEnabled {
                Divider()
                    .overlay(.white.opacity(0.35))
                if telemetry.sampledFrameIntervals > 0 {
                    Text(
                        "display \(telemetry.observedFramesPerSecond, specifier: "%.1f") / \(telemetry.targetFramesPerSecond, specifier: "%.1f") fps"
                    )
                    Text(
                        "missed \(telemetry.missedIntervals)  longest \(telemetry.longestIntervalMilliseconds, specifier: "%.1f") ms"
                    )
                    Text(
                        "flow gen \(telemetry.generatedPerSecond, specifier: "%.1f")  admit \(telemetry.admittedPerSecond, specifier: "%.1f")  drop \(telemetry.droppedPerSecond, specifier: "%.1f") /s"
                    )
                    Text(
                        "rss \(mebibytes(process.residentBytes)) / \(mebibytes(process.peakResidentBytes)) MiB"
                    )
                    Text(
                        "footprint \(mebibytes(process.physicalFootprintBytes)) / \(mebibytes(process.peakPhysicalFootprintBytes)) MiB"
                    )
                    if process.hasCPUInterval {
                        Text(
                            "process cpu \(process.cpuPercentage, specifier: "%.1f")%  (100% = one core)"
                        )
                    } else {
                        Text("process cpu warming up…")
                    }
                    Text("memory current / run peak")
                        .foregroundStyle(.secondary)
                } else {
                    Text("display telemetry warming up…")
                }
                Text("DIAGNOSTIC — NOT INSTRUMENTS EVIDENCE")
                    .foregroundStyle(.yellow)
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.white)
        .padding(9)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Danmaku statistics")
    }

    private var performanceCanvasNotice: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("FORMAL PERFORMANCE MODE")
                .font(.caption.bold())
            Text(model.performancePreset.catalogIdentity)
            Text("HUD updates frozen during the run")
            Text("Use the Measurement signpost as the trace window")
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.white)
        .padding(9)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 7))
    }

    private func canvasSize(in available: CGSize) -> CGSize {
        if let performanceCanvasSize = model.performanceCanvasSize {
            return performanceCanvasSize
        }
        let inset = CGSize(
            width: max(available.width - 32, 1),
            height: max(available.height - 32, 1)
        )
        guard model.canvasMode == .sixteenByNine else { return inset }
        let widthFromHeight = inset.height * 16 / 9
        if widthFromHeight <= inset.width {
            return CGSize(width: widthFromHeight, height: inset.height)
        }
        return CGSize(width: inset.width, height: inset.width * 9 / 16)
    }

    private func mebibytes(_ bytes: UInt64) -> String {
        (Double(bytes) / 1_048_576).formatted(
            .number.precision(.fractionLength(1))
        )
    }

    private func formRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            content()
        }
    }

    private func compactToggleRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10, content: content)
        }
    }

    private func compactToggle(
        _ title: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickerRow<Value: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Value>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        formRow(title) {
            Picker(title, selection: selection, content: content)
                .labelsHidden()
                .frame(maxWidth: 160)
        }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title): \(value.wrappedValue, specifier: "%.0f") \(suffix)")
            Slider(value: value, in: range)
        }
    }

    private func speedSliderRow(
        selection: Binding<DanmakuSpeedLevel>
    ) -> some View {
        let value = Binding<Double>(
            get: { Double(selection.wrappedValue.rawValue) },
            set: { newValue in
                let rawValue = Int(newValue.rounded())
                if let level = DanmakuSpeedLevel(rawValue: rawValue) {
                    selection.wrappedValue = level
                }
            }
        )
        let range =
            Double(
                DanmakuSpeedLevel.one.rawValue
            )...Double(
                DanmakuSpeedLevel.five.rawValue
            )
        return VStack(alignment: .leading, spacing: 3) {
            Text("Speed level: \(selection.wrappedValue.rawValue)")
            Slider(
                value: value,
                in: range,
                step: 1
            )
            HStack {
                Text("1 · slower")
                Spacer()
                Text("5 · faster")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func visualSliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String,
        fractionDigits: Int
    ) -> some View {
        let formattedValue = value.wrappedValue.formatted(
            .number.precision(.fractionLength(fractionDigits))
        )
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(title): \(formattedValue) \(suffix)")
            Slider(value: value, in: range, step: step)
        }
    }
}

extension LabRunLifecycle {
    fileprivate var displayName: String {
        switch self {
        case .waitingForSurface:
            "WAITING FOR SURFACE"
        case .running:
            "RUNNING"
        case .completed:
            "COMPLETED"
        case .polluted(let pollution):
            "POLLUTED: \(pollution.displayName)"
        case .stopped:
            "STOPPED"
        }
    }
}

extension LabRunPollution {
    fileprivate var displayName: String {
        switch self {
        case .wallClockOverflow:
            "wall clock overflow"
        case .backlogExceeded(let pending, let maximum):
            "tick backlog \(pending) > \(maximum)"
        case .eventBatchExceeded(let pending, let maximum):
            "event batch \(pending) > \(maximum)"
        case .surfaceChangedDuringMeasurement:
            "surface changed during measurement"
        }
    }
}

extension LabPerformanceSamplePollution {
    fileprivate var displayName: String {
        switch self {
        case .telemetryEnabled:
            "telemetry enabled"
        case .rendererMismatch:
            "renderer mismatch"
        case .canvasMismatch:
            "canvas mismatch"
        case .backingScaleMismatch:
            "backing scale mismatch"
        case .lifecycleNotRunning:
            "run not active"
        case .runPolluted:
            "logical run polluted"
        case .manifestMismatch:
            "run manifest mismatch"
        case .incompleteLogicalWorkload:
            "incomplete logical workload"
        case .generatedWorkloadMismatch:
            "generated workload mismatch"
        case .surfaceChangedDuringMeasurement:
            "surface changed during measurement"
        }
    }
}

extension LabPerformanceContractFailure {
    fileprivate var displayName: String {
        switch self {
        case .generatorOverflow:
            "generator overflow"
        case .generatedAccountingMismatch:
            "generated accounting mismatch"
        case .presentationAccountingMismatch:
            "presentation accounting mismatch"
        case .activeHardCapExceeded:
            "active hard cap exceeded"
        case .performanceBacklogExceeded:
            "performance backlog exceeded"
        }
    }
}
