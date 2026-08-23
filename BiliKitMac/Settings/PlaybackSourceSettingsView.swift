import BiliPlayback
import Foundation
import SwiftUI

struct PlaybackSourceSettingsView: View {
    @Bindable var model: AppSettingsModel

    var body: some View {
        Form {
            if #available(macOS 26.0, *) {
                Section("音频") {
                    Toggle(
                        "响度均一化",
                        isOn: loudnessNormalizationEnabled
                    )
                    Text("实验性功能，仅适用于 macOS 26。只影响下一次新播放，当前播放不会改变或重建。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("此功能依赖系统未文档化的 HLS 音频处理行为，可能随系统更新失效；失效或缺少安全元数据时保持原始响度。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("播放线路") {
                Picker("新播放优先线路", selection: selection) {
                    ForEach(PlaybackSourceSelection.allCases) { item in
                        Text(
                            item.isExperimental
                                ? AppStrings.localized("\(item.displayName)（实验）")
                                : item.displayName
                        )
                        .tag(item)
                    }
                }
                Text("默认使用 B 站服务端顺序。改选只影响之后新开始的播放，当前播放不会切源或重建。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("18 条 bilivideo 镜像线路属于实验性能力，可能失效，不保证每个视频都完整可用；不可用时仍回退服务端原始完整候选。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("线路测速参考") {
                Picker("不同样本", selection: benchmarkSampleCount) {
                    ForEach(AppSettingsModel.supportedBenchmarkSampleCounts, id: \.self) {
                        Text("\($0) 个").tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.state.isRunning)

                Text("最多约 \(maximumTrafficMiB) MiB；每个样本对 1 条原始 Akamai 与 18 条实验 bilivideo 线路逐条串行测试。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if case .testing(let completed, let total) = model.state {
                    ProgressView(value: Double(completed), total: Double(total)) {
                        Text("正在测试 \(completed) / \(total) 项")
                    }
                } else {
                    Text(statusText).foregroundStyle(.secondary)
                }

                ForEach(model.measurements, id: \.target) { result in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.target.appDisplayName)
                        Text(Self.resultText(result))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let distribution = Self.sampleDistributionText(result) {
                            Text(distribution)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if model.state.isRunning {
                    Button("取消测速", role: .cancel) { model.cancelBenchmark() }
                } else {
                    Button(
                        model.measurements.isEmpty
                            ? AppStrings.localized("开始测速")
                            : AppStrings.localized("重新测速")
                    ) {
                        model.startBenchmark()
                    }
                    .disabled(!model.benchmarkAccess.allowsBenchmark)
                }
            }

            Text(
                "测速需要登录，Cookie 仅用于 api.bilibili.com 的 playurl 请求，不会发给媒体线路。结果仅存在于当前设置窗口，不会保存、推荐线路或更改手动选择。"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 520)
        .onDisappear { model.closeSettings() }
    }

    private var selection: Binding<PlaybackSourceSelection> {
        Binding(get: { model.selection }, set: { model.selection = $0 })
    }

    private var loudnessNormalizationEnabled: Binding<Bool> {
        Binding(
            get: { model.loudnessNormalizationEnabled },
            set: { model.loudnessNormalizationEnabled = $0 }
        )
    }

    private var benchmarkSampleCount: Binding<Int> {
        Binding(
            get: { model.benchmarkSampleCount },
            set: { model.setBenchmarkSampleCount($0) }
        )
    }

    private var maximumTrafficMiB: UInt64 {
        let bytes =
            AppSettingsModel.maximumTrafficBytes(repetitions: model.benchmarkSampleCount) ?? 0
        let mebibyte: UInt64 = 1_024 * 1_024
        return (bytes + mebibyte - 1) / mebibyte
    }

    private var statusText: String {
        if model.benchmarkAccess == .resolving {
            return AppStrings.localized("正在确认登录状态…")
        }
        if model.benchmarkAccess == .signedOut {
            return AppStrings.localized("请先在主窗口登录。")
        }
        switch model.state {
        case .notTested:
            return AppStrings.localized("尚未测速。开始后会从不同分区寻找近期、低播放量且足够长的公开视频样本。")
        case .findingSample:
            return AppStrings.localized("正在寻找 \(model.benchmarkSampleCount) 个合格样本…")
        case .testing:
            return AppStrings.localized("正在串行测试…")
        case .completed:
            return AppStrings.localized("测速完成；请根据结果自行选择线路。")
        case .cancelled:
            return AppStrings.localized("测速已取消，线路选择未改变。")
        case .sampleUnavailable:
            return AppStrings.localized("暂时找不到合格样本，请稍后重试。")
        case .authenticationFailure:
            return AppStrings.localized("登录状态已失效或暂时不可用，请重新登录后再试。")
        case .networkOrProtocolFailure:
            return AppStrings.localized("网络或远端协议未能完成测速，未暴露样本或网络详情。")
        }
    }

    static func resultText(
        _ result: PlaybackRouteMeasurement,
        locale: Locale = .current
    ) -> String {
        guard let bits = result.effectiveBitsPerSecond, bits.isFinite, bits >= 0 else {
            return AppStrings.localized(
                "不可用 · 0/\(result.totalRuns) 个样本成功",
                locale: locale
            )
        }
        if result.totalRuns > 1 {
            let minimum =
                result.minimumBitsPerSecond.map {
                    speedText($0, locale: locale)
                } ?? "—"
            let median =
                result.medianBitsPerSecond.map {
                    speedText($0, locale: locale)
                } ?? "—"
            let effective = speedText(bits, locale: locale)
            return AppStrings.localized(
                "综合 \(effective) · 最低 \(minimum) · 中位 \(median) · \(result.successfulRuns)/\(result.totalRuns) 个样本成功",
                locale: locale
            )
        }
        let effective = speedText(bits, locale: locale)
        return AppStrings.localized(
            "最慢片段吞吐 \(effective) · \(result.successfulRuns)/\(result.totalRuns) 个样本成功",
            locale: locale
        )
    }

    static func sampleDistributionText(
        _ result: PlaybackRouteMeasurement,
        locale: Locale = .current
    ) -> String? {
        guard result.totalRuns > 1, !result.sampleBitsPerSecond.isEmpty else {
            return nil
        }
        let samples = result.sampleBitsPerSecond
            .map { speedText($0, locale: locale) }
            .joined(separator: " / ")
        return AppStrings.localized("匿名样本：\(samples)", locale: locale)
    }

    private static func speedText(_ bits: Double, locale: Locale) -> String {
        let speed = String(format: "%.1f", locale: locale, bits / 1_000_000)
        return "\(speed) Mbps"
    }
}
