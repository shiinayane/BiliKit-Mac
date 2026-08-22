@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaToolbox
import Synchronization

final class LoudnessProcessingTap: @unchecked Sendable {
    static let rampDurationSeconds = 0.150

    private let state: State
    private let tap: MTAudioProcessingTap

    private init(state: State, tap: MTAudioProcessingTap) {
        self.state = state
        self.tap = tap
    }

    static func make(initialGain: Float) -> LoudnessProcessingTap? {
        guard initialGain.isFinite, initialGain > 0 else { return nil }
        let state = State(initialGain: initialGain)
        let retainedState = Unmanaged.passRetained(state)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retainedState.toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<State>.fromOpaque(
                    MTAudioProcessingTapGetStorage(tap)
                ).release()
            },
            prepare: { tap, _, format in
                LoudnessProcessingTap.state(for: tap).prepare(format.pointee)
            },
            unprepare: { tap in
                LoudnessProcessingTap.state(for: tap).unprepare()
            },
            process: process
        )
        var createdTap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &createdTap
        )
        guard status == noErr, let createdTap else {
            retainedState.release()
            return nil
        }
        return LoudnessProcessingTap(state: state, tap: createdTap)
    }

    func makeAudioMix() -> AVAudioMix {
        let parameters = AVMutableAudioMixInputParameters()
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    func setTargetGain(_ gain: Float) {
        state.setTargetGain(gain)
    }
}

extension LoudnessProcessingTap {
    final class State: @unchecked Sendable {
        private let targetGainBits: Atomic<UInt32>
        private var formatIsSupported = false
        private var sampleRate = 0.0
        private var currentGain: Float
        private var rampStartGain: Float
        private var rampTargetGain: Float
        private var rampFrameCount = 0
        private var rampFrameIndex = 0

        init(initialGain: Float) {
            targetGainBits = Atomic(initialGain.bitPattern)
            currentGain = initialGain
            rampStartGain = initialGain
            rampTargetGain = initialGain
        }

        func setTargetGain(_ gain: Float) {
            guard gain.isFinite, gain > 0 else { return }
            targetGainBits.store(gain.bitPattern, ordering: .releasing)
        }

        func prepare(_ format: AudioStreamBasicDescription) {
            sampleRate = format.mSampleRate
            let flags = format.mFormatFlags
            let isFloat = flags & kAudioFormatFlagIsFloat != 0
            let isBigEndian = flags & kAudioFormatFlagIsBigEndian != 0
            let isPacked = flags & kAudioFormatFlagIsPacked != 0
            let isNonInterleaved =
                flags & kAudioFormatFlagIsNonInterleaved != 0
            let expectedBytesPerFrame =
                UInt32(MemoryLayout<Float>.size)
                * (isNonInterleaved ? 1 : format.mChannelsPerFrame)
            formatIsSupported =
                format.mFormatID == kAudioFormatLinearPCM
                && isFloat
                && !isBigEndian
                && isPacked
                && format.mBitsPerChannel == 32
                && format.mChannelsPerFrame > 0
                && format.mFramesPerPacket == 1
                && format.mBytesPerFrame == expectedBytesPerFrame
                && format.mBytesPerPacket == expectedBytesPerFrame
                && sampleRate.isFinite
                && sampleRate > 0
            resetToTarget()
        }

        func unprepare() {
            formatIsSupported = false
            sampleRate = 0
            resetToTarget()
        }

        func resetToTarget() {
            let target = targetGain()
            currentGain = target
            rampStartGain = target
            rampTargetGain = target
            rampFrameCount = 0
            rampFrameIndex = 0
        }

        func process(
            buffers: UnsafeMutablePointer<AudioBufferList>,
            frameCount: Int,
            discontinuity: Bool
        ) {
            guard formatIsSupported, frameCount > 0 else { return }
            if discontinuity { resetToTarget() }

            let target = targetGain()
            if target != rampTargetGain {
                rampStartGain = currentGain
                rampTargetGain = target
                rampFrameCount = max(
                    1,
                    Int(
                        (sampleRate * LoudnessProcessingTap.rampDurationSeconds)
                            .rounded()
                    )
                )
                rampFrameIndex = 0
            }

            let bufferList = UnsafeMutableAudioBufferListPointer(buffers)
            for frame in 0..<frameCount {
                let gain = gainForCurrentFrame()
                for bufferIndex in bufferList.indices {
                    let buffer = bufferList[bufferIndex]
                    let channels = Int(buffer.mNumberChannels)
                    guard channels > 0, let data = buffer.mData else { continue }
                    let availableSamples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let firstSample = frame * channels
                    guard firstSample >= 0,
                        firstSample < availableSamples,
                        channels <= availableSamples - firstSample
                    else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for channel in 0..<channels {
                        samples[firstSample + channel] *= gain
                    }
                }
                advanceRamp(appliedGain: gain)
            }
        }

        private func targetGain() -> Float {
            Float(
                bitPattern: targetGainBits.load(ordering: .acquiring)
            )
        }

        private func gainForCurrentFrame() -> Float {
            guard rampFrameCount > 0, rampFrameIndex < rampFrameCount else {
                return rampTargetGain
            }
            let progress = Float(rampFrameIndex + 1) / Float(rampFrameCount)
            return rampStartGain + (rampTargetGain - rampStartGain) * progress
        }

        private func advanceRamp(appliedGain: Float) {
            currentGain = appliedGain
            guard rampFrameCount > 0 else {
                return
            }
            rampFrameIndex += 1
            if rampFrameIndex >= rampFrameCount {
                currentGain = rampTargetGain
                rampFrameCount = 0
                rampFrameIndex = 0
            }
        }
    }

    static func state(for tap: MTAudioProcessingTap) -> State {
        Unmanaged<State>.fromOpaque(
            MTAudioProcessingTapGetStorage(tap)
        ).takeUnretainedValue()
    }

    static let process: MTAudioProcessingTapProcessCallback = {
        tap,
        requestedFrames,
        _,
        buffers,
        framesOut,
        flagsOut in
        var sourceFlags = MTAudioProcessingTapFlags()
        var sourceFrames = CMItemCount(0)
        let status = MTAudioProcessingTapGetSourceAudio(
            tap,
            requestedFrames,
            buffers,
            &sourceFlags,
            nil,
            &sourceFrames
        )
        framesOut.pointee = sourceFrames
        flagsOut.pointee = sourceFlags
        guard status == noErr, sourceFrames > 0 else { return }
        state(for: tap).process(
            buffers: buffers,
            frameCount: Int(sourceFrames),
            discontinuity:
                sourceFlags & kMTAudioProcessingTapFlag_StartOfStream != 0
        )
    }
}
