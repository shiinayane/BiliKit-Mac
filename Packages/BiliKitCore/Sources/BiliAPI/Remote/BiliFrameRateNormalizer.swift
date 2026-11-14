import Foundation

/// 把 playurl DASH 视频的 `frame_rate` 文本规范为标准帧率，供 loopback HLS 清单的 `FRAME-RATE`
/// 使用。
///
/// B 站常给出按 16 kHz 时基量化后的帧时长（如 `16000/672`，或换算成小数的 `30.303`）：
/// 先按时基分桶归回 24／25／30／50／60／120，再认 NTSC 分数帧率与相对误差 0.5% 以内的名义帧率；
/// 都不符时保留报告值本身。只有缺失、无法解析或超出 1–120 时为 nil，清单不写帧率。
///
/// 归不到名义帧率不等于帧率未知：RFC 8216bis 的 `FRAME-RATE` 是“四舍五入到三位小数的最高帧率”，报告值
/// 本身就合规。nil 会让 SDR 档省略这个可选属性，却让 HDR 档整档被丢弃（见 `DASHVideoVariants`），所以只
/// 在真的不知道帧率时给 nil。
enum BiliFrameRateNormalizer {
    /// 接受的帧率范围；超出时多半是错误数据，宁可不写 `FRAME-RATE`。
    private static let acceptedRates = 1.0...120.0
    /// B 站帧时长使用的时基（Hz）。
    private static let timescale = 16_000.0
    /// 帧时长按 16 个时基单位量化，名义帧时长向下与向上取整的两个桶都认。
    private static let durationQuantum = 16.0
    /// 与桶边界的允许误差（时基单位），只为吸收三位小数文本反算时长的舍入误差，远小于量化步长 16。
    private static let durationTolerance = 0.1
    /// 与 NTSC 分数帧率的允许绝对误差（帧/秒）。
    private static let fractionalTolerance = 0.01
    /// 与名义帧率的相对误差上限；放宽会把更多非标准帧率也归为名义帧率。
    private static let nominalDriftRatio = 0.005

    private static let fractionalRates = [
        24_000.0 / 1_001.0,
        30_000.0 / 1_001.0,
        60_000.0 / 1_001.0,
        120_000.0 / 1_001.0
    ]

    private static let nominalRates = [24.0, 25.0, 30.0, 50.0, 60.0, 120.0]

    static func normalizedValue(from rawValue: String?) -> Double? {
        guard let reportedRate = parsedValue(from: rawValue),
            reportedRate.isFinite,
            reportedRate > 0
        else {
            return nil
        }

        if let quantizedRate = biliTimescaleRate(for: reportedRate) {
            return quantizedRate
        }

        if let fractionalRate = nearestRate(
            to: reportedRate,
            among: fractionalRates,
            tolerance: fractionalTolerance
        ) {
            return fractionalRate
        }

        if let nominalRate = nominalRates.min(by: {
            abs($0 - reportedRate) < abs($1 - reportedRate)
        }),
            abs(nominalRate - reportedRate) <= nominalRate * nominalDriftRatio
        {
            return nominalRate
        }

        return acceptedRates.contains(reportedRate) ? reportedRate : nil
    }

    private static func parsedValue(from rawValue: String?) -> Double? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        if components.count == 1 {
            return Double(components[0])
        }
        guard components.count == 2,
            let numerator = Double(components[0]),
            let denominator = Double(components[1]),
            denominator != 0
        else {
            return nil
        }
        return numerator / denominator
    }

    private static func biliTimescaleRate(for reportedRate: Double) -> Double? {
        let reportedDuration = timescale / reportedRate
        for nominalRate in nominalRates {
            let nominalDuration = timescale / nominalRate
            let lowerBucket =
                floor(nominalDuration / durationQuantum) * durationQuantum
            let upperBucket =
                ceil(nominalDuration / durationQuantum) * durationQuantum
            if abs(reportedDuration - lowerBucket) <= durationTolerance
                || abs(reportedDuration - upperBucket) <= durationTolerance
            {
                return nominalRate
            }
        }
        return nil
    }

    private static func nearestRate(
        to reportedRate: Double,
        among candidates: [Double],
        tolerance: Double
    ) -> Double? {
        guard
            let nearest = candidates.min(by: {
                abs($0 - reportedRate) < abs($1 - reportedRate)
            }),
            abs(nearest - reportedRate) <= tolerance
        else {
            return nil
        }
        return nearest
    }
}
