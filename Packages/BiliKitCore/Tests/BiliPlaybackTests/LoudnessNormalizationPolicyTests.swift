import AudioToolbox
import Foundation
import Testing

@testable import BiliModels
@testable import BiliPlayback

struct LoudnessNormalizationPolicyTests {
    private let policy = LoudnessNormalizationPolicy()

    @Test
    func appliesLoudnessDifferenceAndDBConversion() {
        let gain = policy.linearGain(
            for: metadata(measuredI: -17, measuredTP: -5)
        )

        #expect(abs(gain - Float(pow(10, 3.0 / 20))) < 0.0001)
    }

    @Test
    func truePeakAndProductCapsConstrainBoost() {
        let peakLimited = policy.linearGain(
            for: metadata(measuredI: -30, measuredTP: -2)
        )
        let productLimited = policy.linearGain(
            for: metadata(measuredI: -30, measuredTP: -20)
        )

        #expect(abs(peakLimited - Float(pow(10, 1.0 / 20))) < 0.0001)
        #expect(abs(productLimited - Float(pow(10, 6.0 / 20))) < 0.0001)
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

    @Test
    func runtimePolicyRequiresMacOS26SettingAndMetadata() {
        #expect(
            !LoudnessNormalizationRuntimePolicy.shouldInstall(
                enabled: true,
                hasMetadata: true,
                runtimeSupportsTap: false
            )
        )
        #expect(
            !LoudnessNormalizationRuntimePolicy.shouldInstall(
                enabled: false,
                hasMetadata: true,
                runtimeSupportsTap: true
            )
        )
        #expect(
            !LoudnessNormalizationRuntimePolicy.shouldInstall(
                enabled: true,
                hasMetadata: false,
                runtimeSupportsTap: true
            )
        )
        #expect(
            LoudnessNormalizationRuntimePolicy.shouldInstall(
                enabled: true,
                hasMetadata: true,
                runtimeSupportsTap: true
            )
        )
    }

    @Test
    func float32ProcessorHandlesInterleavedAndBoundedBuffers() {
        let state = LoudnessProcessingTap.State(initialGain: 2)
        state.prepare(floatFormat(sampleRate: 10, channels: 2, interleaved: true))
        var samples: [Float] = [1, -1, 0.5, -0.5, 7]
        samples.withUnsafeMutableBytes { bytes in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: 4 * UInt32(MemoryLayout<Float>.size),
                    mData: bytes.baseAddress
                )
            )
            state.process(buffers: &bufferList, frameCount: 3, discontinuity: false)
        }

        #expect(samples == [2, -2, 1, -1, 7])
    }

    @Test
    func float32ProcessorHandlesNonInterleavedRampAndUnsupportedFormat() {
        let state = LoudnessProcessingTap.State(initialGain: 1)
        state.prepare(floatFormat(sampleRate: 10, channels: 2, interleaved: false))
        state.setTargetGain(2)
        var left: [Float] = [1, 1]
        var right: [Float] = [1, 1]
        withUnsafeMutablePointer(to: &left) { leftArray in
            withUnsafeMutablePointer(to: &right) { rightArray in
                leftArray.pointee.withUnsafeMutableBytes { leftBytes in
                    rightArray.pointee.withUnsafeMutableBytes { rightBytes in
                        let size =
                            MemoryLayout<AudioBufferList>.size
                            + MemoryLayout<AudioBuffer>.size
                        let storage = UnsafeMutableRawPointer.allocate(
                            byteCount: size,
                            alignment: MemoryLayout<AudioBufferList>.alignment
                        )
                        defer { storage.deallocate() }
                        let list = storage.assumingMemoryBound(
                            to: AudioBufferList.self
                        )
                        list.pointee.mNumberBuffers = 2
                        let buffers = UnsafeMutableAudioBufferListPointer(list)
                        buffers[0] = AudioBuffer(
                            mNumberChannels: 1,
                            mDataByteSize: UInt32(leftBytes.count),
                            mData: leftBytes.baseAddress
                        )
                        buffers[1] = AudioBuffer(
                            mNumberChannels: 1,
                            mDataByteSize: UInt32(rightBytes.count),
                            mData: rightBytes.baseAddress
                        )
                        state.process(
                            buffers: list,
                            frameCount: 2,
                            discontinuity: false
                        )
                    }
                }
            }
        }
        #expect(abs(left[0] - 1.5) < 0.001)
        #expect(left == right)

        let unsupported = LoudnessProcessingTap.State(initialGain: 2)
        var format = floatFormat(sampleRate: 10, channels: 1, interleaved: true)
        format.mBitsPerChannel = 16
        unsupported.prepare(format)
        var untouched: [Float] = [1]
        untouched.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            unsupported.process(buffers: &list, frameCount: 1, discontinuity: false)
        }
        #expect(untouched == [1])
    }

    @Test
    func discontinuityResetsAnInFlightRampToTheLatestTarget() {
        let state = LoudnessProcessingTap.State(initialGain: 1)
        state.prepare(floatFormat(sampleRate: 48_000, channels: 1, interleaved: true))
        state.setTargetGain(2)
        var samples: [Float] = [1]
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            state.process(buffers: &list, frameCount: 1, discontinuity: true)
        }

        #expect(samples == [2])
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

    private func floatFormat(
        sampleRate: Double,
        channels: UInt32,
        interleaved: Bool
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags:
                kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: 4 * (interleaved ? channels : 1),
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * (interleaved ? channels : 1),
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
