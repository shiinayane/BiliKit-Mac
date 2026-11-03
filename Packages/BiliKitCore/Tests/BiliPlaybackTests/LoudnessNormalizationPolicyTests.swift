@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import BiliModels
@testable import BiliPlayback

/// 响度标准化只把比目标响的音轨压低、从不放大，切换音轨时音量从切换处短过渡。
///
/// 也固定压低上限、无效或缺失的响度数据保持原音量、只有需要压低时才挂 audio mix，
/// 以及系统音轨选项按语言与角色（不按显示名）找回音轨。
struct LoudnessNormalizationPolicyTests {
    private let policy = LoudnessNormalizationPolicy()

    @Test
    func louderThanTargetIsTurnedDownToMinus18LUFS() {
        let gain = policy.linearGain(
            for: metadata(measuredI: -10, measuredTP: 1)
        )

        #expect(abs(gain - Float(pow(10, -8.0 / 20))) < 0.0001)
    }

    /// 只压低不放大：即使峰值余量充足，安静的音轨也保持原样。
    @Test(arguments: [-18.0, -25.0, -40.0])
    func targetOrQuieterKeepsOriginalLoudness(measuredI: Double) {
        #expect(policy.linearGain(for: metadata(measuredI: measuredI, measuredTP: -20)) == 1)
    }

    @Test
    func attenuationCapAndInvalidMetadataFallBackSafely() {
        let attenuated = policy.linearGain(
            for: metadata(measuredI: -1, measuredTP: -20)
        )
        let invalid = PlaybackLoudnessMetadata(
            measuredIntegratedLUFS: .nan,
            measuredLoudnessRangeLU: 3,
            measuredTruePeakDBTP: -2,
            measuredThresholdLUFS: -30,
            targetIntegratedLUFS: -14,
            targetTruePeakDBTP: -1
        )

        #expect(abs(attenuated - Float(pow(10, -12.0 / 20))) < 0.0001)
        #expect(policy.linearGain(for: invalid) == 1)
        #expect(policy.linearGain(for: nil) == 1)
    }

    /// 只有至少一条音轨需要压低时才挂 audio mix；全都不比目标响（或没有响度数据）时不挂。
    @Test
    func audioMixIsInstalledOnlyWhenSomeTrackNeedsAttenuation() {
        let quiet = audioTrack(role: .original, metadata: metadata(measuredI: -25, measuredTP: -3))
        let loud = audioTrack(
            role: .machineGenerated,
            languageTag: "en",
            metadata: metadata(measuredI: -10, measuredTP: 1)
        )
        let unmeasured = audioTrack(role: .original, metadata: nil)

        #expect(!policy.needsAttenuation([quiet, unmeasured]))
        #expect(policy.needsAttenuation([quiet, loud]))
        #expect(!policy.needsAttenuation([]))
    }

    /// 从原声切到更响的配音：mix 只设在全部音轨的混音（mixID）上，锚点之前就是新音量，从切换时的 item
    /// 时间起短过渡，之后保持新音量；gain 不变或停在开头时整段都是同一音量，不做过渡。
    @Test
    func trackSwitchAudioMixRampsMixVolumeFromTheCurrentItemTime() throws {
        guard #available(macOS 27.0, *) else { return }
        let originalGain = policy.linearGain(for: metadata(measuredI: -20, measuredTP: -3))
        let dubGain = policy.linearGain(for: metadata(measuredI: -6, measuredTP: 1))
        let switchTime = CMTime(seconds: 42, preferredTimescale: 600)

        let switched = try #require(
            LoudnessAudioMix.make(
                volume: dubGain,
                rampingFrom: originalGain,
                at: switchTime
            ).inputParameters.only
        )

        #expect(switched.trackID == AVAudioMixInputParametersTrackID.mixID.rawValue)
        let beforeAnchor = try #require(volumeRamp(of: switched, at: 10))
        #expect(beforeAnchor.start == dubGain)
        #expect(beforeAnchor.end == dubGain)
        let ramp = try #require(volumeRamp(of: switched, at: 42.05))
        #expect(ramp.start == originalGain)
        #expect(ramp.end == dubGain)
        #expect(ramp.timeRange.start == switchTime)
        #expect(ramp.timeRange.duration == LoudnessAudioMix.rampDuration)
        // 过渡结束后没有更多音量段，系统沿用最后的音量（新 gain）。
        #expect(volumeRamp(of: switched, at: 60) == nil)

        for constant in [
            LoudnessAudioMix.make(volume: dubGain),
            LoudnessAudioMix.make(volume: dubGain, rampingFrom: dubGain, at: switchTime),
            LoudnessAudioMix.make(volume: dubGain, rampingFrom: originalGain, at: .zero)
        ] {
            let parameters = try #require(constant.inputParameters.only)
            #expect(parameters.trackID == AVAudioMixInputParametersTrackID.mixID.rawValue)
            let whole = try #require(volumeRamp(of: parameters, at: 60))
            #expect(whole.start == dubGain)
            #expect(whole.end == dubGain)
            #expect(whole.timeRange.start == .zero)
            #expect(!whole.timeRange.duration.isNumeric)
        }
    }

    /// 语言按 BCP 47 补全后比较：同一语言的不同写法能对上，不同语言或文字不能。
    @Test(
        arguments: [
            (nil, nil, true),
            (nil, "und", true),
            ("und", nil, true),
            ("zh-Hans", "zh-Hans", true),
            ("zh-Hans", "zh_CN", true),
            ("zh-Hans", "zh-Hans-CN", true),
            ("zh-Hant", "zh-TW", true),
            ("en", "en-US", true),
            ("ja", "JA", true),
            ("zh-Hans", "zh-Hant", false),
            ("en", "ja", false),
            ("en", "und", false),
            (nil, "en", false)
        ] as [(String?, String?, Bool)]
    )
    func audioTrackLanguagesMatchAcrossTagSpellings(
        expected: String?,
        actual: String?,
        matches: Bool
    ) {
        #expect(LoudnessAudioTrackMatching.sameLanguage(expected, actual) == matches)
    }

    /// 选项按语言与角色找回音轨，与显示名无关；角色不同的同语言选项对不上。
    @Test
    func audioTrackMatchingUsesLanguageAndRoleOnly() {
        let original = audioTrack(role: .original, metadata: nil)
        let dub = audioTrack(role: .machineGenerated, languageTag: "zh-Hans", metadata: nil)
        func characteristics(
            _ values: Set<String>
        ) -> (AVMediaCharacteristic) -> Bool {
            { values.contains($0.rawValue) }
        }

        // 原声在播放列表里不写 LANGUAGE，系统选项的语言标签与 locale 都为 nil。
        for optionLanguageTag in [nil, "und"] as [String?] {
            #expect(
                LoudnessAudioTrackMatching.matches(
                    original,
                    optionLanguageTag: optionLanguageTag,
                    optionHasCharacteristic: characteristics(["public.original-content"])
                )
            )
        }
        #expect(
            LoudnessAudioTrackMatching.matches(
                dub,
                optionLanguageTag: "zh_CN",
                optionHasCharacteristic: characteristics(["public.machine-generated"])
            )
        )
        #expect(
            !LoudnessAudioTrackMatching.matches(
                dub,
                optionLanguageTag: "zh-Hans",
                optionHasCharacteristic: characteristics(["public.original-content"])
            )
        )
    }

    private func audioTrack(
        role: PlaybackAudioTrack.Role,
        languageTag: String? = nil,
        metadata: PlaybackLoudnessMetadata?
    ) -> PlaybackAudioTrack {
        PlaybackAudioTrack(
            id: "\(role)-\(languageTag ?? "und")",
            displayName: "系统本地化后的名称",
            languageTag: languageTag,
            role: role,
            isDefault: role == .original,
            isAutoselect: role == .original,
            loudnessMetadata: metadata,
            representations: []
        )
    }

    private func metadata(
        measuredI: Double,
        measuredTP: Double
    ) -> PlaybackLoudnessMetadata {
        PlaybackLoudnessMetadata(
            measuredIntegratedLUFS: measuredI,
            measuredLoudnessRangeLU: 3,
            measuredTruePeakDBTP: measuredTP,
            measuredThresholdLUFS: min(measuredI - 10, -10),
            targetIntegratedLUFS: -14,
            targetTruePeakDBTP: -1
        )
    }
}

/// 某一 item 时间所在的音量段：起止音量与时间范围。
private struct VolumeRamp: Equatable {
    let start: Float
    let end: Float
    let timeRange: CMTimeRange
}

private func volumeRamp(
    of parameters: AVAudioMixInputParameters,
    at seconds: Double
) -> VolumeRamp? {
    var start: Float = 0
    var end: Float = 0
    var timeRange = CMTimeRange()
    guard
        parameters.getVolumeRamp(
            for: CMTime(seconds: seconds, preferredTimescale: 600),
            startVolume: &start,
            endVolume: &end,
            timeRange: &timeRange
        )
    else { return nil }
    return VolumeRamp(start: start, end: end, timeRange: timeRange)
}

extension Array {
    /// 恰好一个元素时返回它。
    fileprivate var only: Element? { count == 1 ? first : nil }
}
