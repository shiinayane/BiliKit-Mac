@preconcurrency import AVFoundation
import BiliAPI
import BiliApplication
import BiliModels
import BiliPlayback
import Darwin
import Foundation
import QuartzCore

@main
@MainActor
struct BiliPlaybackProbe {
    static func main() async {
        do {
            let configuration = try ProbeConfiguration(arguments: CommandLine.arguments)
            try await run(configuration)
        } catch let error as ProbeError {
            writeError("BiliPlaybackProbe failed: \(error.description)\n")
            exit(EXIT_FAILURE)
        } catch let error as BiliAPIError {
            writeError("BiliPlaybackProbe failed: \(error.description)\n")
            exit(EXIT_FAILURE)
        } catch {
            writeError(
                "BiliPlaybackProbe failed: \(String(reflecting: type(of: error)))\n"
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func run(_ configuration: ProbeConfiguration) async throws {
        let client = BiliAPIClient()
        let cid: Int64
        if let configuredCID = configuration.cid {
            cid = configuredCID
        } else {
            let pages = try await client.pages(for: configuration.bvid)
            guard let firstPage = pages.first else {
                throw ProbeError.invalidAPIResponse
            }
            cid = firstPage.cid
        }
        let playback = try await client.playback(
            for: configuration.bvid,
            cid: cid,
            quality: 32
        )
        guard let video = playback.manifest.videoRepresentations.max(
            by: { $0.id < $1.id }
        ) else {
            throw ProbeError.noAVCVideo
        }
        guard let audio = playback.manifest.audioRepresentations.min(
            by: { ($0.bandwidth ?? .max) < ($1.bandwidth ?? .max) }
        ) else {
            throw ProbeError.noAACAudio
        }

        print("sample: bvid=\(configuration.bvid) cid=\(cid)")
        print(
            "video: id=\(video.id) codec=\(video.codecs) bandwidth=\(video.bandwidth ?? 0) cdns=\(hosts(video.urlCandidates))"
        )
        print(
            "audio: id=\(audio.id) codec=\(audio.codecs) bandwidth=\(audio.bandwidth ?? 0) cdns=\(hosts(audio.urlCandidates))"
        )

        let request = PlaybackRequest(
            manifest: PlaybackManifest(
                videoRepresentations: [video],
                audioRepresentations: [audio]
            ),
            preferredVideoRepresentationID: video.id,
            preferredAudioRepresentationID: audio.id,
            mediaHeaders: playback.mediaHeaders
        )
        let engine = AVPlayerEngine()
        engine.player.isMuted = true
        let identity = PlaybackItemIdentity(
            bvid: configuration.bvid,
            cid: cid
        )
        try await load(
            engine,
            request: request,
            identity: identity,
            timeout: .seconds(30)
        )
        guard let item = engine.player.currentItem else {
            throw ProbeError.missingPlayerItem
        }
        let durationTime = try await item.asset.load(.duration)
        let duration = durationTime.seconds
        guard duration.isFinite, duration > 2 else {
            throw ProbeError.invalidDuration
        }
        let timelineSampler = VideoTimelineSampler(item: item)
        print(
            "ready: duration=\(formatted(duration))s selected-tracks=avc+aac"
        )

        engine.play()
        try await wait(
            for: engine.player,
            toReach: configuration.initialPlaybackSeconds,
            timeout: .seconds(max(15, configuration.initialPlaybackSeconds + 15)),
            timelineSampler: timelineSampler,
            sampleAfter: 0.1
        )
        engine.pause()
        print("play: reached=\(formatted(engine.player.currentTime().seconds))s")

        for cycle in 0..<configuration.seekCycles {
            let forward = min(
                configuration.forwardSeekSeconds + Double(cycle * 17),
                max(configuration.initialPlaybackSeconds + 1, duration - 1)
            )
            try await engine.seek(to: .seconds(forward))
            engine.play()
            try await wait(
                for: engine.player,
                toReach: forward + 0.6,
                timeout: .seconds(15),
                timelineSampler: timelineSampler,
                sampleAfter: forward + 0.2
            )
            engine.pause()
            print(
                "seek-forward[\(cycle + 1)]: target=\(formatted(forward))s ok"
            )

            let backward = min(
                configuration.backwardSeekSeconds + Double(cycle * 3),
                max(0, forward - 1)
            )
            try await engine.seek(to: .seconds(backward))
            engine.play()
            try await wait(
                for: engine.player,
                toReach: backward + 0.6,
                timeout: .seconds(15),
                timelineSampler: timelineSampler,
                sampleAfter: backward + 0.2
            )
            engine.pause()
            print(
                "seek-backward[\(cycle + 1)]: target=\(formatted(backward))s ok"
            )
        }

        guard timelineSampler.sampleCount >= 5 else {
            throw ProbeError.insufficientVideoTimelineSamples
        }
        guard timelineSampler.maximumDelta <= 0.5 else {
            throw ProbeError.videoTimelineDrift(timelineSampler.maximumDelta)
        }
        print(
            "timeline: samples=\(timelineSampler.sampleCount) max-video-delta=\(formatted(timelineSampler.maximumDelta))s"
        )

        try await auditReplacementMemory(
            engine: engine,
            request: request,
            identity: identity,
            cycles: configuration.replacementCycles,
            maximumGrowthMiB: configuration.maximumMemoryGrowthMiB
        )
        print("RESULT: PASS")
    }

    private static func auditReplacementMemory(
        engine: AVPlayerEngine,
        request: PlaybackRequest,
        identity: PlaybackItemIdentity,
        cycles: Int,
        maximumGrowthMiB: Double
    ) async throws {
        guard cycles > 0 else { return }
        let baseline = residentMemoryBytes()
        guard baseline > 0 else {
            throw ProbeError.memoryMeasurementUnavailable
        }
        var samples = [baseline]

        for cycle in 1...cycles {
            try await load(
                engine,
                request: request,
                identity: identity,
                timeout: .seconds(30)
            )
            engine.play()
            try await wait(
                for: engine.player,
                toReach: 0.5,
                timeout: .seconds(15)
            )
            engine.pause()
            try await Task.sleep(for: .milliseconds(200))
            let sample = residentMemoryBytes()
            guard sample > 0 else {
                throw ProbeError.memoryMeasurementUnavailable
            }
            samples.append(sample)
            print(
                "replacement[\(cycle)]: resident=\(formattedMiB(sample))MiB ok"
            )
        }

        let peak = samples.max() ?? baseline
        let final = samples.last ?? baseline
        let growth = final > baseline ? final - baseline : 0
        let growthMiB = Double(growth) / 1_048_576
        print(
            "memory: baseline=\(formattedMiB(baseline))MiB peak=\(formattedMiB(peak))MiB final-growth=\(formatted(growthMiB))MiB"
        )
        guard growthMiB <= maximumGrowthMiB else {
            throw ProbeError.memoryGrowthExceeded(growthMiB)
        }
    }

    private static func load(
        _ engine: AVPlayerEngine,
        request: PlaybackRequest,
        identity: PlaybackItemIdentity,
        timeout: Duration
    ) async throws {
        let loadTask = Task { @MainActor in
            try await engine.load(request, identity: identity)
        }
        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
            loadTask.cancel()
        }
        do {
            try await loadTask.value
            timeoutTask.cancel()
        } catch is CancellationError {
            timeoutTask.cancel()
            throw ProbeError.timedOut
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    private static func wait(
        for player: AVPlayer,
        toReach target: Double,
        timeout: Duration,
        timelineSampler: VideoTimelineSampler? = nil,
        sampleAfter: Double = 0
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let currentTime = player.currentTime().seconds
            if currentTime >= sampleAfter {
                timelineSampler?.sample(player: player)
            }
            if currentTime >= target {
                return
            }
            if player.currentItem?.status == .failed {
                throw ProbeError.playerItemFailed
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ProbeError.timedOut
    }

    private static func hosts(_ urls: [URL]) -> String {
        var seen = Set<String>()
        return urls.compactMap(\.host)
            .filter { seen.insert($0).inserted }
            .joined(separator: ",")
    }

    private static func formatted(_ value: Double) -> String {
        String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    private static func formattedMiB(_ bytes: UInt64) -> String {
        formatted(Double(bytes) / 1_048_576)
    }

    private static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.stride
                / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private struct ProbeConfiguration {
    let bvid: String
    let cid: Int64?
    let initialPlaybackSeconds: Double
    let forwardSeekSeconds: Double
    let backwardSeekSeconds: Double
    let seekCycles: Int
    let replacementCycles: Int
    let maximumMemoryGrowthMiB: Double

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count else {
                throw ProbeError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }

        guard let bvid = values["--bvid"],
              bvid.hasPrefix("BV"),
              bvid.count <= 24,
              bvid.dropFirst(2).allSatisfy({ $0.isLetter || $0.isNumber })
        else {
            throw ProbeError.invalidArguments
        }
        self.bvid = bvid

        if let rawCID = values["--cid"] {
            guard let cid = Int64(rawCID), cid > 0 else {
                throw ProbeError.invalidArguments
            }
            self.cid = cid
        } else {
            cid = nil
        }
        initialPlaybackSeconds = try Self.positiveDouble(
            values["--play-seconds"] ?? "1"
        )
        forwardSeekSeconds = try Self.positiveDouble(
            values["--forward-seek"] ?? "30"
        )
        backwardSeekSeconds = try Self.nonnegativeDouble(
            values["--backward-seek"] ?? "5"
        )
        seekCycles = try Self.positiveInteger(values["--seek-cycles"] ?? "1")
        replacementCycles = try Self.nonnegativeInteger(
            values["--replacement-cycles"] ?? "0"
        )
        maximumMemoryGrowthMiB = try Self.positiveDouble(
            values["--max-memory-growth-mib"] ?? "64"
        )
    }

    private static func positiveDouble(_ value: String) throws -> Double {
        guard let parsed = Double(value), parsed.isFinite, parsed > 0 else {
            throw ProbeError.invalidArguments
        }
        return parsed
    }

    private static func nonnegativeDouble(_ value: String) throws -> Double {
        guard let parsed = Double(value), parsed.isFinite, parsed >= 0 else {
            throw ProbeError.invalidArguments
        }
        return parsed
    }

    private static func positiveInteger(_ value: String) throws -> Int {
        guard let parsed = Int(value), parsed > 0 else {
            throw ProbeError.invalidArguments
        }
        return parsed
    }

    private static func nonnegativeInteger(_ value: String) throws -> Int {
        guard let parsed = Int(value), parsed >= 0 else {
            throw ProbeError.invalidArguments
        }
        return parsed
    }
}

@MainActor
private final class VideoTimelineSampler {
    private let output: AVPlayerItemVideoOutput
    private(set) var sampleCount = 0
    private(set) var maximumDelta = 0.0

    init(item: AVPlayerItem) {
        output = AVPlayerItemVideoOutput(
            pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA),
            ]
        )
        item.add(output)
    }

    func sample(player: AVPlayer) {
        let requestedTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard requestedTime.isValid,
              requestedTime.seconds.isFinite,
              output.hasNewPixelBuffer(forItemTime: requestedTime)
        else {
            return
        }

        var displayTime = CMTime.invalid
        guard output.copyPixelBuffer(
            forItemTime: requestedTime,
            itemTimeForDisplay: &displayTime
        ) != nil else {
            return
        }
        let frameTime = displayTime.isValid ? displayTime : requestedTime
        let playerTime = player.currentTime()
        guard frameTime.seconds.isFinite, playerTime.seconds.isFinite else {
            return
        }
        maximumDelta = max(
            maximumDelta,
            abs(frameTime.seconds - playerTime.seconds)
        )
        sampleCount += 1
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidAPIResponse
    case noAVCVideo
    case noAACAudio
    case missingPlayerItem
    case invalidDuration
    case playerItemFailed
    case insufficientVideoTimelineSamples
    case videoTimelineDrift(Double)
    case memoryMeasurementUnavailable
    case memoryGrowthExceeded(Double)
    case timedOut

    var description: String {
        switch self {
        case .invalidArguments: "invalid-arguments"
        case .invalidAPIResponse: "invalid-api-response"
        case .noAVCVideo: "no-avc-video"
        case .noAACAudio: "no-aac-audio"
        case .missingPlayerItem: "missing-player-item"
        case .invalidDuration: "invalid-duration"
        case .playerItemFailed: "player-item-failed"
        case .insufficientVideoTimelineSamples:
            "insufficient-video-timeline-samples"
        case let .videoTimelineDrift(delta):
            "video-timeline-drift-\(delta)"
        case .memoryMeasurementUnavailable:
            "memory-measurement-unavailable"
        case let .memoryGrowthExceeded(growth):
            "memory-growth-exceeded-\(growth)-mib"
        case .timedOut: "timed-out"
        }
    }
}
