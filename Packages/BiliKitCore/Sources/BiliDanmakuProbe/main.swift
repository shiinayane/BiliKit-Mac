import BiliAPI
import BiliApplication
import BiliDanmaku
import BiliNetworking
import Foundation

@main
struct BiliDanmakuProbe {
    static func main() async {
        do {
            let configuration = try Configuration(arguments: CommandLine.arguments)
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.httpShouldSetCookies = false
            sessionConfiguration.httpCookieStorage = nil
            sessionConfiguration.urlCache = nil
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            sessionConfiguration.timeoutIntervalForRequest = 15
            sessionConfiguration.timeoutIntervalForResource = 30
            let client = BiliAPIClient(
                transport: URLSessionTransport(
                    configuration: sessionConfiguration,
                    redirectPolicy: .reject
                )
            )
            let cid: Int64
            if let configuredCID = configuration.cid {
                cid = configuredCID
            } else {
                guard let firstPage = try await client.pages(
                    for: configuration.bvid
                ).first else {
                    throw DanmakuApplicationError.invalidResponse
                }
                cid = firstPage.cid
            }
            let identity = PlaybackItemIdentity(
                bvid: configuration.bvid,
                cid: cid
            )
            let useCase = DanmakuSegmentUseCase(
                repository: BiliDanmakuRepository(client: client)
            )
            let segment = try await useCase.segment(
                index: configuration.segmentIndex,
                for: identity
            )

            var scheduler = DanmakuScheduler()
            scheduler.begin(for: identity)
            scheduler.store(segment, for: identity)
            let start = Double(configuration.segmentIndex - 1)
                * DanmakuScheduler.segmentDurationSeconds
            _ = scheduler.consume(
                snapshot(
                    identity: identity,
                    position: start,
                    generation: 1
                )
            )
            let batch = scheduler.consume(
                snapshot(
                    identity: identity,
                    position: start + DanmakuScheduler.segmentDurationSeconds,
                    generation: 1
                )
            )
            print(
                "danmaku-production segment=ready decoded=\(segment.events.count) "
                    + "scheduled=\(batch?.events.count ?? 0) cache=\(scheduler.cachedSegmentCount)"
            )
            print("RESULT: PASS")
        } catch let error as DanmakuApplicationError {
            writeError("BiliDanmakuProbe failed: \(safeName(error))\n")
            exit(EXIT_FAILURE)
        } catch {
            writeError(
                "BiliDanmakuProbe failed: \(String(reflecting: type(of: error)))\n"
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func snapshot(
        identity: PlaybackItemIdentity,
        position: Double,
        generation: UInt64
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: nil,
            rate: 1,
            state: .playing,
            discontinuityGeneration: generation
        )
    }

    private static func safeName(_ error: DanmakuApplicationError) -> String {
        switch error {
        case .invalidRequest: "invalid-request"
        case .requestRestricted: "request-restricted"
        case .transportFailure: "transport-failure"
        case .invalidResponse: "invalid-response"
        case .unavailable: "unavailable"
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private struct Configuration {
    let bvid: String
    let cid: Int64?
    let segmentIndex: Int

    init(arguments: [String]) throws {
        let arguments = Array(arguments.dropFirst())
        guard arguments.count.isMultiple(of: 2) else {
            throw DanmakuApplicationError.invalidRequest
        }
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard name.hasPrefix("--"), values[name] == nil else {
                throw DanmakuApplicationError.invalidRequest
            }
            values[name] = arguments[index + 1]
            index += 2
        }
        guard (2...3).contains(values.count),
              let bvid = values["--bvid"],
              bvid.count == 12,
              bvid.hasPrefix("BV"),
              bvid.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let rawSegmentIndex = values["--segment-index"],
              let segmentIndex = Int(rawSegmentIndex),
              (1...DanmakuSegmentUseCase.maximumSegmentIndex).contains(segmentIndex)
        else {
            throw DanmakuApplicationError.invalidRequest
        }
        let cid: Int64?
        if let rawCID = values["--cid"] {
            guard let parsed = Int64(rawCID), parsed > 0 else {
                throw DanmakuApplicationError.invalidRequest
            }
            cid = parsed
        } else {
            cid = nil
        }
        self.bvid = bvid
        self.cid = cid
        self.segmentIndex = segmentIndex
    }
}
