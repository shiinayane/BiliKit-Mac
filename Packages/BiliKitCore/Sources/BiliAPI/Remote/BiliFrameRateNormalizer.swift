import Foundation

enum BiliFrameRateNormalizer {
    private static let timescale = 16_000.0
    private static let durationQuantum = 16.0
    private static let durationTolerance = 0.1
    private static let fractionalTolerance = 0.01
    private static let nominalDriftRatio = 0.005

    private static let fractionalRates = [
        24_000.0 / 1_001.0,
        30_000.0 / 1_001.0,
        60_000.0 / 1_001.0,
        120_000.0 / 1_001.0,
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

        let integralRate = reportedRate.rounded()
        guard abs(integralRate - reportedRate) < .ulpOfOne,
            (1...120).contains(integralRate)
        else {
            return nil
        }
        return integralRate
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
