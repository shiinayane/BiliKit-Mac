@preconcurrency import AVFoundation
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
        } catch {
            writeError(
                "BiliPlaybackProbe failed: \(String(reflecting: type(of: error)))\n"
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func run(_ configuration: ProbeConfiguration) async throws {
        let client = ProbeAPIClient(bvid: configuration.bvid)
        let cid: Int64
        if let configuredCID = configuration.cid {
            cid = configuredCID
        } else {
            cid = try await client.firstCID()
        }
        let response = try await client.playURL(cid: cid)
        let video = try response.selectedAVCVideo()
        let audio = try response.selectedAACAudio()
        let headers = client.mediaHeaders

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
            mediaHeaders: headers
        )
        let engine = AVPlayerEngine()
        engine.player.isMuted = true
        try await load(engine, request: request, timeout: .seconds(30))
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
            cycles: configuration.replacementCycles,
            maximumGrowthMiB: configuration.maximumMemoryGrowthMiB
        )
        print("RESULT: PASS")
    }

    private static func auditReplacementMemory(
        engine: AVPlayerEngine,
        request: PlaybackRequest,
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
            try await load(engine, request: request, timeout: .seconds(30))
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
        timeout: Duration
    ) async throws {
        let loadTask = Task { @MainActor in
            try await engine.load(request)
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

private struct ProbeAPIClient: Sendable {
    let bvid: String

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 BiliKitMac/0.1"

    var referer: String {
        "https://www.bilibili.com/video/\(bvid)/"
    }

    var mediaHeaders: [String: String] {
        [
            "Referer": referer,
            "User-Agent": userAgent,
        ]
    }

    func firstCID() async throws -> Int64 {
        let url = try endpoint(
            path: "/x/player/pagelist",
            queryItems: [URLQueryItem(name: "bvid", value: bvid)]
        )
        let response: PageListEnvelope = try await get(url)
        guard response.code == 0, let cid = response.data?.first?.cid else {
            throw ProbeError.apiRejected(response.code)
        }
        return cid
    }

    func playURL(cid: Int64) async throws -> PlayURLData {
        let url = try endpoint(
            path: "/x/player/playurl",
            queryItems: [
                URLQueryItem(name: "bvid", value: bvid),
                URLQueryItem(name: "cid", value: String(cid)),
                URLQueryItem(name: "qn", value: "32"),
                URLQueryItem(name: "fnval", value: "16"),
                URLQueryItem(name: "fnver", value: "0"),
                URLQueryItem(name: "fourk", value: "0"),
            ]
        )
        let response: PlayURLEnvelope = try await get(url)
        guard response.code == 0, let data = response.data else {
            throw ProbeError.apiRejected(response.code)
        }
        return data
    }

    private func get<Response: Decodable & Sendable>(
        _ url: URL
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              data.count <= 5 * 1_024 * 1_024
        else {
            throw ProbeError.invalidAPIResponse
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func endpoint(
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.bilibili.com"
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ProbeError.invalidAPIResponse
        }
        return url
    }
}

private struct PageListEnvelope: Decodable, Sendable {
    let code: Int
    let data: [Page]?
}

private struct Page: Decodable, Sendable {
    let cid: Int64
}

private struct PlayURLEnvelope: Decodable, Sendable {
    let code: Int
    let data: PlayURLData?
}

private struct PlayURLData: Decodable, Sendable {
    let dash: DASH

    func selectedAVCVideo() throws -> MediaRepresentation {
        let candidates = try dash.video
            .filter { $0.codecid == 7 }
            .map { try $0.mediaRepresentation(kind: .video) }
        guard let selected = candidates.max(by: { $0.id < $1.id }) else {
            throw ProbeError.noAVCVideo
        }
        return selected
    }

    func selectedAACAudio() throws -> MediaRepresentation {
        let candidates = try dash.audio.map {
            try $0.mediaRepresentation(kind: .audio)
        }
        guard let selected = candidates.min(by: {
            ($0.bandwidth ?? .max) < ($1.bandwidth ?? .max)
        }) else {
            throw ProbeError.noAACAudio
        }
        return selected
    }
}

private struct DASH: Decodable, Sendable {
    let video: [DASHRepresentation]
    let audio: [DASHRepresentation]
}

private struct DASHRepresentation: Decodable, Sendable {
    let id: Int
    let codecid: Int?
    let codecs: String
    let mimeType: String
    let bandwidth: Int?
    let baseURL: String
    let backupURLs: [String]
    let segmentBase: DASHSegmentBase

    private enum CodingKeys: String, CodingKey {
        case id
        case codecid
        case codecs
        case mimeType = "mime_type"
        case mimeTypeCamel = "mimeType"
        case bandwidth
        case baseURL = "base_url"
        case baseURLCamel = "baseUrl"
        case backupURLs = "backup_url"
        case backupURLsCamel = "backupUrl"
        case segmentBase = "segment_base"
        case segmentBaseCamel = "SegmentBase"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        codecid = try container.decodeIfPresent(Int.self, forKey: .codecid)
        codecs = try container.decode(String.self, forKey: .codecs)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
            ?? container.decode(String.self, forKey: .mimeTypeCamel)
        bandwidth = try container.decodeIfPresent(Int.self, forKey: .bandwidth)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
            ?? container.decode(String.self, forKey: .baseURLCamel)
        backupURLs = try container.decodeIfPresent([String].self, forKey: .backupURLs)
            ?? container.decodeIfPresent([String].self, forKey: .backupURLsCamel)
            ?? []
        segmentBase = try container.decodeIfPresent(
            DASHSegmentBase.self,
            forKey: .segmentBase
        ) ?? container.decode(DASHSegmentBase.self, forKey: .segmentBaseCamel)
    }

    func mediaRepresentation(kind: MediaKind) throws -> MediaRepresentation {
        var seen = Set<URL>()
        let urls = ([baseURL] + backupURLs)
            .compactMap(URL.init(string:))
            .filter { seen.insert($0).inserted }
        guard let primaryURL = urls.first else {
            throw ProbeError.invalidMediaURL
        }
        return MediaRepresentation(
            id: id,
            kind: kind,
            codecs: codecs,
            mimeType: mimeType,
            bandwidth: bandwidth,
            primaryURL: primaryURL,
            backupURLs: Array(urls.dropFirst()),
            segmentBase: try segmentBase.model()
        )
    }
}

private struct DASHSegmentBase: Decodable, Sendable {
    let initialization: String
    let indexRange: String

    private enum CodingKeys: String, CodingKey {
        case initialization
        case indexRange = "index_range"
        case indexRangeCamel = "indexRange"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        initialization = try container.decode(String.self, forKey: .initialization)
        indexRange = try container.decodeIfPresent(String.self, forKey: .indexRange)
            ?? container.decode(String.self, forKey: .indexRangeCamel)
    }

    func model() throws -> SegmentBase {
        SegmentBase(
            initialization: try byteRange(initialization),
            index: try byteRange(indexRange)
        )
    }

    private func byteRange(_ value: String) throws -> MediaByteRange {
        let bounds = value.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1])
        else {
            throw ProbeError.invalidSegmentBase
        }
        return try MediaByteRange(start: start, endInclusive: end)
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidAPIResponse
    case apiRejected(Int)
    case noAVCVideo
    case noAACAudio
    case invalidMediaURL
    case invalidSegmentBase
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
        case let .apiRejected(code): "api-rejected-\(code)"
        case .noAVCVideo: "no-avc-video"
        case .noAACAudio: "no-aac-audio"
        case .invalidMediaURL: "invalid-media-url"
        case .invalidSegmentBase: "invalid-segment-base"
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
