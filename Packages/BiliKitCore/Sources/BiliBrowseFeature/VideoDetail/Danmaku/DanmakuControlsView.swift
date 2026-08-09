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
            .accessibilityIdentifier("danmaku.enabled")

            Button {
                showsSettings.toggle()
            } label: {
                Label("弹幕设置", systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help("弹幕设置")
            .accessibilityIdentifier("danmaku.settings")
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

            speedSettings

            Divider()

            opacitySettings
        }
        .padding(16)
        .frame(width: 340)
        .font(.body)
        .accessibilityIdentifier("danmaku.settings.popover")
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
                    identifier: "danmaku.mode.scrolling",
                    mode: .scrolling
                )
                modeToggle(
                    "顶部",
                    isOn: model.showsTop,
                    isLastVisibleMode: model.showsTop
                        && !model.showsScrolling
                        && !model.showsBottom,
                    identifier: "danmaku.mode.top",
                    mode: .top
                )
                modeToggle(
                    "底部",
                    isOn: model.showsBottom,
                    isLastVisibleMode: model.showsBottom
                        && !model.showsScrolling
                        && !model.showsTop,
                    identifier: "danmaku.mode.bottom",
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
            .accessibilityIdentifier("danmaku.speed")

            HStack(spacing: 0) {
                ForEach(DanmakuSpeedLevel.allCases, id: \.rawValue) { level in
                    Text(level.displayName)
                        .font(.caption2)
                        .fontWeight(
                            level == model.speedLevel ? .semibold : .regular
                        )
                        .foregroundStyle(
                            level == model.speedLevel
                                ? Color.primary
                                : Color.secondary
                        )
                        .frame(maxWidth: .infinity)
                }
            }
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
            .accessibilityIdentifier("danmaku.opacity")

            HStack {
                Text(
                    DanmakuOpacity.allowedRange.lowerBound,
                    format: .percent.precision(.fractionLength(0))
                )

                Spacer()

                Text(
                    DanmakuOpacity.allowedRange.upperBound,
                    format: .percent.precision(.fractionLength(0))
                )
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func modeToggle(
        _ title: String,
        isOn: Bool,
        isLastVisibleMode: Bool,
        identifier: String,
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
        .accessibilityIdentifier(identifier)
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
