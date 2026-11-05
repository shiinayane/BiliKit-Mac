import BiliApplication
import BiliPlayback
import BiliUI
import Foundation
import SwiftUI

/// 设置窗口的表单：HDR 视频开关、新播放优先线路与线路测速参考。
///
/// 只绑定进程级 `AppSettingsModel`；窗口消失时调用 `closeSettings()` 取消测速并丢弃结果。
struct PlaybackSourceSettingsView: View {
    private static let experimentalRouteCount = BilivideoRoute.allCases.count

    @Bindable var model: AppSettingsModel

    var body: some View {
        Form {
            Section("视频") {
                Toggle("HDR 视频", isOn: $model.hdrVideoEnabled)
                Text(
                    "窗口所在的屏幕能显示 HDR 时，有 HDR 真彩或杜比视界的视频以 HDR 播放。低电量模式或使用蜂窝数据、个人热点等受限网络时不使用 HDR。改动只影响之后新开始的播放。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                Text(
                    "\(Self.experimentalRouteCount) 条 bilivideo 镜像线路属于实验性能力，可能失效，不保证每个视频都完整可用；不可用时仍回退服务端原始完整候选。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("线路测速参考") {
                Picker("不同样本", selection: benchmarkSampleCount) {
                    ForEach(PlaybackRouteBenchmarkPolicy.supportedSampleCounts, id: \.self) {
                        Text("\($0) 个").tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.state.isRunning)

                Text(
                    "最多约 \(maximumTrafficMiB) MiB；每个样本对 1 条原始 Akamai 与 \(Self.experimentalRouteCount) 条实验 bilivideo 线路逐条串行测试。"
                )
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
                "测速需要登录，Cookie 仅用于 api.bilibili.com 的测速样本详情与 playurl 请求，不会发给媒体线路。结果仅存在于当前设置窗口，不会保存、推荐线路或更改手动选择。"
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
        case .authenticationRequired:
            return AppStrings.localized("请先在主窗口登录。")
        case .authenticationInvalid:
            return AppStrings.localized("登录状态已失效，请在主窗口重新登录后再试。")
        case .authenticationUnavailable:
            return AppStrings.localized("无法读取登录状态，请稍后重试。")
        case .restricted:
            return AppStrings.localized("B 站暂时限制了测速请求，请稍后再试。")
        case .networkOrProtocolFailure:
            return AppStrings.localized("网络或服务器响应异常，测速未能完成，请稍后重试。")
        }
    }

    static func resultText(
        _ result: PlaybackRouteMeasurement,
        locale: Locale = InterfaceLocale.current
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
        locale: Locale = InterfaceLocale.current
    ) -> String? {
        guard result.totalRuns > 1, !result.sampleBitsPerSecond.isEmpty else {
            return nil
        }
        let samples = result.sampleBitsPerSecond
            .map { speedText($0, locale: locale) }
            .joined(separator: " / ")
        return AppStrings.localized("匿名样本：\(samples)", locale: locale)
    }

    /// 一位小数、按 locale 分组的 Mbps；Foundation 没有数据速率的 `Unit`，单位自己拼。
    private static func speedText(_ bits: Double, locale: Locale) -> String {
        let speed = (bits / 1_000_000).formatted(
            .number.precision(.fractionLength(1)).locale(locale)
        )
        return "\(speed) Mbps"
    }
}
