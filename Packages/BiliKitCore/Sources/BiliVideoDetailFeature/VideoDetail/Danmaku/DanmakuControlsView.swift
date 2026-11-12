import BiliApplication
import BiliUI
import SwiftUI

/// 播放页工具栏的弹幕按钮：文字加图标，图标随开关变化（与快捷键 D 的反馈一致）；
/// 弹出面板顶部是开关，其余设置在弹幕关闭时不可调。
struct DanmakuControlsView: View {
    let model: DanmakuControlsViewModel
    @State private var showsSettings = false

    var body: some View {
        Button {
            showsSettings.toggle()
        } label: {
            Label(
                VideoDetailFeatureStrings.localized("弹幕"),
                systemImage: model.isEnabled ? "text.bubble.fill" : "text.bubble"
            )
            .labelStyle(.titleAndIcon)
        }
        .help(VideoDetailFeatureStrings.localized("弹幕设置"))
        .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
            DanmakuSettingsPopover(model: model)
        }
    }
}

/// 播放页工具栏的发送弹幕按钮：呼出播放器上的输入胶囊，与回车、播放器动作菜单同一入口（`DanmakuComposerModel.present`）。
///
/// 不随登录状态禁用：门槛不是可观察状态，按下时由胶囊核对，未登录时在播放器顶部提示。
struct DanmakuPostButton: View {
    let composer: DanmakuComposerModel

    var body: some View {
        Button {
            composer.present()
        } label: {
            Label(VideoDetailFeatureStrings.localized("发弹幕"), systemImage: "plus.bubble")
        }
        .help(VideoDetailFeatureStrings.localized("在当前播放位置发一条弹幕（回车）"))
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
            Toggle(
                isOn: Binding(
                    get: { model.isEnabled },
                    set: { model.setEnabled($0) }
                )
            ) {
                Text(VideoDetailFeatureStrings.localized("弹幕"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                modeSettings

                Divider()

                mergeSettings

                Divider()

                densitySettings

                Divider()

                speedSettings

                Divider()

                opacitySettings
            }
            .disabled(!model.isEnabled)
            .foregroundStyle(model.isEnabled ? .primary : .tertiary)
        }
        .padding(16)
        .frame(width: 360)
        .font(.body)
    }

    private var densitySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(VideoDetailFeatureStrings.localized("显示区域"))
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
                    Text(VideoDetailFeatureStrings.localized("显示区域"))
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
                Text(VideoDetailFeatureStrings.localized("同屏密度"))
                    .font(.subheadline.weight(.semibold))

                Picker(
                    VideoDetailFeatureStrings.localized("同屏密度"),
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
                    Text(VideoDetailFeatureStrings.localized("同屏密度仅在显示区域为 100% 时生效"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var modeSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(VideoDetailFeatureStrings.localized("显示类型"))
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 18) {
                modeToggle(
                    VideoDetailFeatureStrings.localized("滚动"),
                    isOn: model.showsScrolling,
                    isLastVisibleMode: model.showsScrolling
                        && !model.showsTop
                        && !model.showsBottom,
                    mode: .scrolling
                )
                modeToggle(
                    VideoDetailFeatureStrings.localized("顶部"),
                    isOn: model.showsTop,
                    isLastVisibleMode: model.showsTop
                        && !model.showsScrolling
                        && !model.showsBottom,
                    mode: .top
                )
                modeToggle(
                    VideoDetailFeatureStrings.localized("底部"),
                    isOn: model.showsBottom,
                    isLastVisibleMode: model.showsBottom
                        && !model.showsScrolling
                        && !model.showsTop,
                    mode: .bottom
                )
            }

            Text(VideoDetailFeatureStrings.localized("至少保留一种显示类型"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var mergeSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                VideoDetailFeatureStrings.localized("合并重复弹幕"),
                isOn: Binding(
                    get: { model.mergesDuplicates },
                    set: { model.setMergesDuplicates($0) }
                )
            )
            .toggleStyle(.checkbox)

            Text(VideoDetailFeatureStrings.localized("4 秒内内容相同的弹幕只显示一条，并在末尾标出条数"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var speedSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(VideoDetailFeatureStrings.localized("滚动速度"))
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
                Text(VideoDetailFeatureStrings.localized("滚动速度"))
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
                Text(VideoDetailFeatureStrings.localized("透明度"))
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(danmakuPercentText(model.opacity.value))
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
                Text(VideoDetailFeatureStrings.localized("透明度"))
            }
            .labelsHidden()
            .accessibilityValue(Text(danmakuPercentText(model.opacity.value)))

            SliderScaleLabels(
                labels: [
                    danmakuPercentText(DanmakuOpacity.allowedRange.lowerBound),
                    danmakuPercentText(DanmakuOpacity.allowedRange.upperBound)
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

/// 滑块下方的刻度文字：等距排在轨道上，选中档加粗并用主色；读屏隐藏，档位由滑块自身报告。
///
/// `trackInset` 让首末文字对准滑块轨道两端，而不是视图边缘。
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
            VideoDetailFeatureStrings.localized("极慢")
        case .two:
            VideoDetailFeatureStrings.localized("较慢")
        case .three:
            VideoDetailFeatureStrings.localized("适中")
        case .four:
            VideoDetailFeatureStrings.localized("较快")
        case .five:
            VideoDetailFeatureStrings.localized("极快")
        }
    }
}

extension DanmakuDisplayArea {
    fileprivate var displayName: String {
        danmakuPercentText(Double(rawValue) / 100)
    }
}

/// 弹幕面板里百分比（显示区域与透明度）的唯一写法。
///
/// locale 取与文案同语言的 `InterfaceLocale`；`Text(_:format:)` 会改用环境 `locale`，即系统 locale，所以先格式化成
/// 字符串。
private func danmakuPercentText(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)).locale(InterfaceLocale.current))
}

extension DanmakuDensity {
    fileprivate var displayName: String {
        switch self {
        case .normal:
            VideoDetailFeatureStrings.localized("正常")
        case .increased:
            VideoDetailFeatureStrings.localized("较多")
        case .overlapping:
            VideoDetailFeatureStrings.localized("重叠")
        }
    }
}
