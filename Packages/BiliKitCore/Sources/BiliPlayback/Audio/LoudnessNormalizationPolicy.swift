import BiliModels
import Foundation

/// 把一条完整语义音轨的静态响度元数据转换为透明的线性 PCM 增益。
public struct LoudnessNormalizationPolicy: Sendable {
    public static let maximumBoostDB = 6.0
    public static let maximumAttenuationDB = -12.0

    public init() {}

    public func linearGain(for metadata: PlaybackLoudnessMetadata?) -> Float {
        guard let metadata,
            Self.isValid(metadata)
        else { return 1 }

        let wantedDB =
            metadata.targetIntegratedLUFS - metadata.measuredIntegratedLUFS
        let peakSafeDB =
            metadata.targetTruePeakDBTP - metadata.measuredTruePeakDBTP
        let gainDB = max(
            min(wantedDB, peakSafeDB, Self.maximumBoostDB),
            Self.maximumAttenuationDB
        )
        let gain = pow(10, gainDB / 20)
        guard gain.isFinite, gain > 0, gain <= 2 else { return 1 }
        return Float(gain)
    }

    private static func isValid(_ value: PlaybackLoudnessMetadata) -> Bool {
        valid(value.measuredIntegratedLUFS, in: -100...0)
            && valid(value.measuredLoudnessRangeLU, in: 0...100)
            && valid(value.measuredTruePeakDBTP, in: -100...20)
            && valid(value.measuredThresholdLUFS, in: -100...0)
            && valid(value.targetIntegratedLUFS, in: -70 ... -5)
            && valid(value.targetTruePeakDBTP, in: -20...0)
            && value.measuredThresholdLUFS <= value.measuredIntegratedLUFS
    }

    private static func valid(_ value: Double, in range: ClosedRange<Double>) -> Bool {
        value.isFinite && range.contains(value)
    }
}

enum LoudnessNormalizationRuntimePolicy {
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    static func shouldInstall(
        enabled: Bool,
        hasMetadata: Bool,
        runtimeSupportsTap: Bool = isSupported
    ) -> Bool {
        runtimeSupportsTap && enabled && hasMetadata
    }
}
