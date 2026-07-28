import BiliApplication
import BiliDanmaku
import BiliModels
import BiliNetworking
import Darwin.Mach
import Foundation
import SwiftProtobuf
import XCTest

@testable import BiliAPI

final class M501DanmakuWorkingSetProbeTests: XCTestCase {
    @MainActor
    func testRealSegmentFailureClassificationWhenExplicitlyConfigured()
        async throws
    {
        guard let input = try LocalProbeInput.load() else {
            throw XCTSkip(
                "仅在显式提供安全本机 probe 输入文件时运行真实弹幕失败分类探针"
            )
        }
        guard let bvid = input["bvid"],
            Self.isValidBVID(bvid)
        else {
            throw LocalProbeInputError.invalidValue
        }
        let segmentIndex =
            input["segment"].flatMap(Int.init) ?? 6
        guard
            (1...DanmakuSegmentUseCase.maximumSegmentIndex).contains(
                segmentIndex
            )
        else {
            throw XCTSkip("M5.0.1 probe 分段序号无效")
        }

        let transport = M501DanmakuCapturingTransport(
            underlying: Self.ephemeralTransport()
        )
        let client = BiliAPIClient(transport: transport)
        let pages = try await client.pages(for: bvid)
        let page = try XCTUnwrap(pages.first)
        let lastSegmentIndex = max(
            1,
            Int(
                ceil(
                    Double(page.durationSeconds)
                        / DanmakuScheduler.segmentDurationSeconds
                )
            )
        )
        let identity = PlaybackItemIdentity(bvid: bvid, cid: page.cid)
        let useCase = DanmakuSegmentUseCase(
            repository: BiliDanmakuRepository(client: client)
        )

        let result: String
        do {
            _ = try await useCase.segment(index: segmentIndex, for: identity)
            result = "success"
        } catch let error as DanmakuApplicationError {
            result = Self.safeName(error)
        }
        let capturedResponse = await transport.lastResponse()
        let response = try XCTUnwrap(capturedResponse)
        let classification = Self.classify(response)
        XCTContext.runActivity(
            named: [
                "m501-danmaku-failure-classification",
                "segment=\(segmentIndex)",
                "duration-seconds=\(page.durationSeconds)",
                "last-segment=\(lastSegmentIndex)",
                "within-duration=\(segmentIndex <= lastSegmentIndex ? 1 : 0)",
                "result=\(result)",
                "http=\(response.statusCode)",
                "content=\(Self.contentTypeCategory(response))",
                "body-bytes=\(response.body.count)",
                "wire=\(classification.wire)",
                "elements=\(classification.elementCount)",
                "unsupported=\(classification.unsupportedModeCount)",
                "blank=\(classification.blankTextCount)",
                "missing-id=\(classification.missingIDCount)",
                "long-id=\(classification.longIDCount)",
                "time=\(classification.invalidTimeCount)",
                "long-text=\(classification.longTextCount)",
                "color=\(classification.invalidColorCount)",
                "event-over=\(classification.eventCountOverLimit ? 1 : 0)",
                "text-over=\(classification.totalTextOverLimit ? 1 : 0)",
                "cleanup=complete",
            ].joined(separator: " ")
        ) { _ in }
    }

    @MainActor
    func testThreeRealSegmentsShareOneBoundedWorkingSetWhenExplicitlyConfigured()
        async throws
    {
        guard let input = try LocalProbeInput.load() else {
            throw XCTSkip(
                "仅在显式提供安全本机 probe 输入文件时运行真实三段弹幕工作集探针"
            )
        }
        guard let bvid = input["bvid"],
            Self.isValidBVID(bvid)
        else {
            throw LocalProbeInputError.invalidValue
        }

        let client = BiliAPIClient(
            transport: Self.ephemeralTransport()
        )
        let pages = try await client.pages(for: bvid)
        let page = try XCTUnwrap(pages.first)
        let lastSegmentIndex = max(
            1,
            Int(
                ceil(
                    Double(page.durationSeconds)
                        / DanmakuScheduler.segmentDurationSeconds
                )
            )
        )
        guard lastSegmentIndex >= 3 else {
            throw XCTSkip("M5.0.1 工作集探针需要至少三个合法弹幕分段")
        }
        let segmentIndices = Array(
            (lastSegmentIndex - 2)...lastSegmentIndex
        )
        let identity = PlaybackItemIdentity(bvid: bvid, cid: page.cid)
        let useCase = DanmakuSegmentUseCase(
            repository: BiliDanmakuRepository(client: client)
        )
        var scheduler = DanmakuScheduler()
        scheduler.begin(for: identity)

        let baselineRSS = Self.residentMemoryBytes()
        var residentSamples = [baselineRSS]
        var eventCounts: [Int] = []
        for index in segmentIndices {
            let segment = try await useCase.segment(
                index: index,
                for: identity
            )
            XCTAssertFalse(segment.events.isEmpty)
            eventCounts.append(segment.events.count)
            scheduler.store(segment, for: identity)
            residentSamples.append(Self.residentMemoryBytes())
        }

        XCTAssertEqual(
            scheduler.cachedSegmentCount,
            DanmakuScheduler.maximumCachedSegments
        )
        let retainedRSS = Self.residentMemoryBytes()
        scheduler.reset()
        XCTAssertEqual(scheduler.cachedSegmentCount, 0)
        for _ in 0..<20 {
            await Task.yield()
        }
        let resetRSS = Self.residentMemoryBytes()

        let fields = [
            "m501-danmaku-working-set",
            "segments=\(eventCounts.count)",
            "first-segment=\(segmentIndices.first ?? 0)",
            "last-segment=\(segmentIndices.last ?? 0)",
            "events=\(eventCounts.reduce(0, +))",
            "min-segment-events=\(eventCounts.min() ?? 0)",
            "max-segment-events=\(eventCounts.max() ?? 0)",
            "cache-before-reset=\(DanmakuScheduler.maximumCachedSegments)",
            "cache-after-reset=\(scheduler.cachedSegmentCount)",
            "rss-baseline-mib=\(Self.formattedMiB(baselineRSS))",
            "rss-peak-mib=\(Self.formattedMiB(residentSamples.max() ?? 0))",
            "rss-retained-mib=\(Self.formattedMiB(retainedRSS))",
            "rss-after-reset-mib=\(Self.formattedMiB(resetRSS))",
            "cleanup=complete",
        ]
        XCTContext.runActivity(named: fields.joined(separator: " ")) { _ in }
    }

    private static func isValidBVID(_ value: String) -> Bool {
        value.count == 12
            && value.hasPrefix("BV")
            && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber)
            }
    }

    private static func ephemeralTransport() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSessionTransport(
            configuration: configuration,
            redirectPolicy: .reject
        )
    }

    private static func classify(
        _ response: HTTPResponse
    ) -> M501DanmakuFailureClassification {
        guard !response.body.isEmpty else {
            return .init(wire: "not-attempted")
        }
        let payload: Bilikit_Danmaku_SegmentReply
        do {
            payload = try Bilikit_Danmaku_SegmentReply(
                serializedBytes: response.body
            )
        } catch {
            return .init(wire: "decode-failed")
        }

        var classification = M501DanmakuFailureClassification(
            wire: "decoded",
            elementCount: payload.elements.count,
            eventCountOverLimit: payload.elements.count > 20_000
        )
        var totalTextLength = 0
        for element in payload.elements {
            guard [1, 2, 3, 4, 5].contains(element.mode) else {
                classification.unsupportedModeCount += 1
                continue
            }
            let text = element.content.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else {
                classification.blankTextCount += 1
                continue
            }

            let id =
                element.idString.isEmpty
                ? (element.id > 0 ? String(element.id) : nil)
                : element.idString
            if id == nil {
                classification.missingIDCount += 1
            } else if id?.count ?? 0 > 128 {
                classification.longIDCount += 1
            }
            if element.progressMilliseconds < 0
                || element.progressMilliseconds > 86_400_000
            {
                classification.invalidTimeCount += 1
            }
            if text.count > 4_096 {
                classification.longTextCount += 1
            }
            if element.colorRgb > 0xFF_FF_FF {
                classification.invalidColorCount += 1
            }
            totalTextLength += text.count
        }
        classification.totalTextOverLimit = totalTextLength > 1_000_000
        return classification
    }

    private static func contentTypeCategory(
        _ response: HTTPResponse
    ) -> String {
        guard
            let value = response.headers.first(where: {
                $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
            })?.value.lowercased()
        else {
            return "missing"
        }
        if value.contains("application/octet-stream") {
            return "octet-stream"
        }
        if value.contains("json") {
            return "json"
        }
        if value.contains("html") {
            return "html"
        }
        return "other"
    }

    private static func safeName(
        _ error: DanmakuApplicationError
    ) -> String {
        switch error {
        case .invalidRequest: "invalid-request"
        case .requestRestricted: "request-restricted"
        case .transportFailure: "transport-failure"
        case .invalidResponse: "invalid-response"
        case .unavailable: "unavailable"
        }
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

    private static func formattedMiB(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}

private actor M501DanmakuCapturingTransport: HTTPTransport {
    private let underlying: URLSessionTransport
    private var response: HTTPResponse?

    init(underlying: URLSessionTransport) {
        self.underlying = underlying
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await underlying.send(request)
        self.response = response
        return response
    }

    func lastResponse() -> HTTPResponse? {
        response
    }
}

private struct M501DanmakuFailureClassification {
    let wire: String
    var elementCount = 0
    var unsupportedModeCount = 0
    var blankTextCount = 0
    var missingIDCount = 0
    var longIDCount = 0
    var invalidTimeCount = 0
    var longTextCount = 0
    var invalidColorCount = 0
    var eventCountOverLimit = false
    var totalTextOverLimit = false
}
