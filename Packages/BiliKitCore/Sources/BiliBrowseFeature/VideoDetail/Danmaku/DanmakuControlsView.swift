import BiliApplication
import SwiftUI

struct DanmakuControlsView: View {
    let model: DanmakuControlsViewModel
    @State private var showsSettings = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle(
                "弹幕",
                isOn: Binding(
                    get: { model.isEnabled },
                    set: { model.setEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .fixedSize()

            Button {
                showsSettings.toggle()
            } label: {
                Label("弹幕设置", systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help("弹幕设置")
            .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                DanmakuSettingsPopover(model: model)
            }

            Spacer()
        }
        .font(.title3)
    }
}

private struct DanmakuSettingsPopover: View {
    private enum Mode {
        case scrolling
        case top
        case bottom
    }

    let model: DanmakuControlsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("弹幕设置")
                .font(.headline)

            modeSettings

            Divider()

            densitySettings

            Divider()

            speedSettings

            Divider()

            opacitySettings
        }
        .padding(16)
        .frame(width: 360)
        .font(.body)
    }

    private var densitySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("显示区域")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Text(model.displayArea.displayName)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }

                Slider(
                    value: Binding(
                        get: {
                            Double(
                                DanmakuDisplayArea.allCases.firstIndex(
                                    of: model.displayArea
                                ) ?? 0
                            )
                        },
                        set: { value in
                            let index = Int(value.rounded())
                            guard DanmakuDisplayArea.allCases.indices.contains(index) else {
                                return
                            }
                            model.setDisplayArea(
                                DanmakuDisplayArea.allCases[index]
                            )
                        }
                    ),
                    in: 0...Double(DanmakuDisplayArea.allCases.count - 1),
                    step: 1
                ) {
                    Text("显示区域")
                }
                .labelsHidden()
                .accessibilityValue(Text(model.displayArea.displayName))

                SliderScaleLabels(
                    labels: DanmakuDisplayArea.allCases.map(\.displayName),
                    selectedIndex: DanmakuDisplayArea.allCases.firstIndex(
                        of: model.displayArea
                    )
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("同屏密度")
                    .font(.subheadline.weight(.semibold))

                Picker(
                    "同屏密度",
                    selection: Binding(
                        get: { model.density },
                        set: { model.setDensity($0) }
                    )
                ) {
                    ForEach(DanmakuDensity.allCases, id: \.rawValue) { density in
                        Text(density.displayName).tag(density)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.canAdjustDensity)
                .accessibilityValue(Text(model.density.displayName))

                if !model.canAdjustDensity {
                    Text("同屏密度仅在显示区域为 100% 时生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var modeSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("显示类型")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 18) {
                modeToggle(
                    "滚动",
                    isOn: model.showsScrolling,
                    isLastVisibleMode: model.showsScrolling
                        && !model.showsTop
                        && !model.showsBottom,
                    mode: .scrolling
                )
                modeToggle(
                    "顶部",
                    isOn: model.showsTop,
                    isLastVisibleMode: model.showsTop
                        && !model.showsScrolling
                        && !model.showsBottom,
                    mode: .top
                )
                modeToggle(
                    "底部",
                    isOn: model.showsBottom,
                    isLastVisibleMode: model.showsBottom
                        && !model.showsScrolling
                        && !model.showsTop,
                    mode: .bottom
                )
            }

            Text("至少保留一种显示类型")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var speedSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("滚动速度")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(model.speedLevel.displayName)
                    .font(.subheadline.weight(.semibold))
            }

            Slider(
                value: Binding(
                    get: { Double(model.speedLevel.rawValue) },
                    set: { rawValue in
                        let levelValue = Int(rawValue.rounded())
                        guard
                            let level = DanmakuSpeedLevel(
                                rawValue: levelValue
                            )
                        else {
                            return
                        }
                        model.setSpeedLevel(level)
                    }
                ),
                in: Double(
                    DanmakuSpeedLevel.one.rawValue
                )...Double(
                    DanmakuSpeedLevel.five.rawValue
                ),
                step: 1
            ) {
                Text("滚动速度")
            }
            .labelsHidden()
            .accessibilityValue(Text(model.speedLevel.displayName))
            .disabled(!model.showsScrolling)

            SliderScaleLabels(
                labels: DanmakuSpeedLevel.allCases.map(\.displayName),
                selectedIndex: DanmakuSpeedLevel.allCases.firstIndex(
                    of: model.speedLevel
                )
            )
        }
    }

    private var opacitySettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("透明度")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(
                    model.opacity.value,
                    format: .percent.precision(.fractionLength(0))
                )
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            }

            Slider(
                value: Binding(
                    get: { model.opacity.value },
                    set: { model.setOpacity($0) }
                ),
                in: DanmakuOpacity.allowedRange,
                step: 0.05
            ) {
                Text("透明度")
            }
            .labelsHidden()
            .accessibilityValue(
                Text(
                    model.opacity.value,
                    format: .percent.precision(.fractionLength(0))
                )
            )

            SliderScaleLabels(
                labels: [
                    DanmakuOpacity.allowedRange.lowerBound.formatted(
                        .percent.precision(.fractionLength(0))
                    ),
                    DanmakuOpacity.allowedRange.upperBound.formatted(
                        .percent.precision(.fractionLength(0))
                    ),
                ]
            )
        }
    }

    private func modeToggle(
        _ title: String,
        isOn: Bool,
        isLastVisibleMode: Bool,
        mode: Mode
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { isOn },
                set: { newValue in
                    switch mode {
                    case .scrolling:
                        model.setShowsScrolling(newValue)
                    case .top:
                        model.setShowsTop(newValue)
                    case .bottom:
                        model.setShowsBottom(newValue)
                    }
                }
            )
        )
        .toggleStyle(.checkbox)
        .disabled(isLastVisibleMode)
    }
}

private struct SliderScaleLabels: View {
    private let trackInset: CGFloat = 8

    let labels: [String]
    var selectedIndex: Int?

    init(labels: [String], selectedIndex: Int? = nil) {
        self.labels = labels
        self.selectedIndex = selectedIndex
    }

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = max(geometry.size.width - trackInset * 2, 0)

            ZStack(alignment: .topLeading) {
                ForEach(labels.indices, id: \.self) { index in
                    Text(labels[index])
                        .font(.caption2)
                        .fontWeight(
                            index == selectedIndex ? .semibold : .regular
                        )
                        .foregroundStyle(
                            index == selectedIndex
                                ? Color.primary
                                : Color.secondary
                        )
                        .fixedSize()
                        .position(
                            x: trackInset + trackWidth * progress(at: index),
                            y: geometry.size.height / 2
                        )
                }
            }
        }
        .frame(height: 13)
        .accessibilityHidden(true)
    }

    private func progress(at index: Int) -> CGFloat {
        guard labels.count > 1 else {
            return 0.5
        }
        return CGFloat(index) / CGFloat(labels.count - 1)
    }
}

extension DanmakuSpeedLevel {
    fileprivate var displayName: String {
        switch self {
        case .one:
            "极慢"
        case .two:
            "较慢"
        case .three:
            "适中"
        case .four:
            "较快"
        case .five:
            "极快"
        }
    }
}

extension DanmakuDisplayArea {
    fileprivate var displayName: String {
        "\(rawValue)%"
    }
}

extension DanmakuDensity {
    fileprivate var displayName: String {
        switch self {
        case .normal:
            "正常"
        case .increased:
            "较多"
        case .overlapping:
            "重叠"
        }
    }
}
