import BiliApplication
import BiliAuth
import BiliModels
import BiliNetworking
import CoreFoundation
import Foundation
import XCTest

@testable import BiliAPI

/// 显式 opt-in 的 Stage 0 字幕目录事实探针。
///
/// 探针只输出字幕字段组合与耗时，不输出输入 identity、URL、Cookie、正文或完整响应。
final class NativeSubtitleStage0ContractProbeTests: XCTestCase {
    private static let inputEnvironmentKey =
        "BILIKIT_NATIVE_SUBTITLE_STAGE0_INPUT_FILE"

    @MainActor
    func testAuthenticatedCatalogFieldCombinationsWhenExplicitlyConfigured()
        async throws
    {
        guard
            let input = try SecureProbeInput.load(
                environmentKey: Self.inputEnvironmentKey
            )
        else {
            throw XCTSkip("仅在显式提供安全本机输入时运行原生字幕 Stage 0 探针")
        }
        guard let bvid = input["bvid"], Self.isValidBVID(bvid),
            let rawCID = input["cid"],
            let cid = Int64(rawCID),
            cid > 0
        else {
            throw ProbeFailure.invalidInput
        }

        let transport = CatalogRecordingTransport()
        defer { transport.invalidateAndCancel() }
        let client = BiliAPIClient(
            requestAuthorizer: BiliCredentialRequestAuthorizer(),
            transportFactory: { transport }
        )
        let identity = PlaybackItemIdentity(bvid: bvid, cid: cid)
        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            let resources = try await client.subtitleResources(for: identity)
            let elapsed = startedAt.duration(to: clock.now)
            guard !resources.isEmpty else {
                throw ProbeFailure.emptyCatalog
            }
            guard let body = await transport.catalogBody() else {
                throw ProbeFailure.missingCapturedCatalog
            }

            let observations = try Self.fieldObservations(from: body)
            guard !observations.isEmpty else {
                throw ProbeFailure.emptyCatalog
            }
            let summary =
                observations
                .map(\.summary)
                .sorted()
                .joined(separator: ";")
            let elapsedMilliseconds = Self.milliseconds(elapsed)

            XCTContext.runActivity(
                named:
                    "native-subtitle-stage0 tracks=\(resources.count) "
                    + "raw-tracks=\(observations.count) elapsed-ms=\(elapsedMilliseconds) "
                    + "combinations=\(summary)"
            ) { _ in }
        } catch {
            let receivedCatalogResponse = await transport.catalogBody() != nil
            let failureType =
                if let apiError = error as? BiliAPIError {
                    Self.safeFailureValue(
                        apiError.description
                            + (receivedCatalogResponse
                                ? "-after-catalog-response"
                                : "-before-catalog-response")
                    )
                } else {
                    Self.safeFailureValue(
                        String(reflecting: type(of: error))
                    )
                }
            XCTContext.runActivity(
                named: "native-subtitle-stage0 failure-type=\(failureType)"
            ) { _ in }
            throw error
        }
    }

    private static func fieldObservations(
        from data: Data
    ) throws
        -> [FieldObservation]
    {
        guard data.count <= 1 * 1_024 * 1_024,
            let envelope = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let payload = envelope["data"] as? [String: Any],
            let subtitle = payload["subtitle"] as? [String: Any],
            let tracks = subtitle["subtitles"] as? [[String: Any]],
            tracks.count <= 128
        else {
            throw ProbeFailure.invalidCatalogShape
        }

        return try tracks.map { track in
            FieldObservation(
                languageTag: try safeString(track["lan"], maximumLength: 64),
                sourceLabel: try safeString(
                    track["lan_doc"],
                    maximumLength: 128
                ),
                aiType: safeInteger(track["ai_type"]),
                aiStatus: safeInteger(track["ai_status"])
            )
        }
    }

    private static func safeString(
        _ value: Any?,
        maximumLength: Int
    ) throws -> String {
        guard let string = value as? String else { return "<missing>" }
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            normalized.count <= maximumLength,
            normalized.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw ProbeFailure.unsafeFieldValue
        }
        return normalized
    }

    private static func safeInteger(_ value: Any?) -> String {
        guard let value else { return "<missing>" }
        if value is NSNull { return "<null>" }
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            let exactInteger = Int64(number.stringValue)
        else {
            return "<non-integer>"
        }
        return String(exactInteger)
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
        guard !seconds.overflow else { return .max }
        return seconds.partialValue
            + Int64(components.attoseconds / 1_000_000_000_000_000)
    }

    private static func safeFailureValue(_ value: String) -> String {
        let safe = value.filter {
            $0.isASCII
                && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_"
                    || $0 == "-")
        }
        return safe.isEmpty ? "unknown" : String(safe.prefix(128))
    }

    private static func isValidBVID(_ value: String) -> Bool {
        value.count == 12
            && value.hasPrefix("BV")
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private struct FieldObservation {
        let languageTag: String
        let sourceLabel: String
        let aiType: String
        let aiStatus: String

        var summary: String {
            "lan=\(languageTag),lan_doc=\(sourceLabel),ai_type=\(aiType),ai_status=\(aiStatus)"
        }
    }

    private enum ProbeFailure: Error {
        case invalidInput
        case emptyCatalog
        case missingCapturedCatalog
        case invalidCatalogShape
        case unsafeFieldValue
    }
}

private actor CatalogRecordingTransport: HTTPTransport {
    private let transport: URLSessionTransport
    private var capturedCatalogBody: Data?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        transport = URLSessionTransport(
            configuration: configuration,
            redirectPolicy: .reject
        )
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await transport.send(request)
        if request.url.path == "/x/player/wbi/v2" {
            capturedCatalogBody = response.body
        }
        return response
    }

    func catalogBody() -> Data? {
        capturedCatalogBody
    }

    nonisolated func invalidateAndCancel() {
        transport.invalidateAndCancel()
    }
}

private enum SecureProbeInput {
    private static let maximumBytes = 4 * 1_024

    static func load(environmentKey: String) throws -> [String: String]? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey] else {
            return nil
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let permissions = attributes[.posixPermissions] as? NSNumber,
            permissions.intValue & 0o077 == 0
        else {
            throw NativeSubtitleStage0InputError.insecureInput
        }
        let data = try Data(
            contentsOf: URL(fileURLWithPath: path),
            options: .mappedIfSafe
        )
        guard data.count <= maximumBytes else {
            throw NativeSubtitleStage0InputError.insecureInput
        }
        return try PropertyListDecoder().decode([String: String].self, from: data)
    }
}

private enum NativeSubtitleStage0InputError: Error {
    case insecureInput
}
