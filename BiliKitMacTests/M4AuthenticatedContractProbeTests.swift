import BiliApplication
import BiliAuth
import BiliBrowseFeature
import BiliNetworking
import Foundation
import XCTest
@testable import BiliKit

final class M4AuthenticatedContractProbeTests: XCTestCase {
    private static let maximumCatalogSize = 1 * 1_024 * 1_024
    private static let maximumPageListSize = 512 * 1_024
    private static let maximumSubtitleBodySize = 2 * 1_024 * 1_024
    private static let allowedSubtitleHosts: Set<String> = [
        "aisubtitle.hdslb.com",
    ]

    @MainActor
    func testAuthenticatedSubtitleContractWhenExplicitlyConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let bvid = environment["BILIKIT_M4_PROBE_BVID"],
              Self.isValidBVID(bvid)
        else {
            throw XCTSkip(
                "仅在显式提供 BILIKIT_M4_PROBE_BVID 时运行已登录 M4 探针"
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let transport = URLSessionTransport(
            configuration: configuration,
            redirectPolicy: .reject
        )
        defer { transport.invalidateAndCancel() }

        let referer = "https://www.bilibili.com/video/\(bvid)"
        let cid: Int64
        if let rawCID = environment["BILIKIT_M4_PROBE_CID"] {
            guard let configuredCID = Int64(rawCID), configuredCID > 0 else {
                throw ProbeFailure.invalidRequest
            }
            cid = configuredCID
        } else {
            cid = try await Self.firstPageCID(
                bvid: bvid,
                referer: referer,
                transport: transport
            )
        }
        let catalogRequest = try Self.catalogRequest(
            bvid: bvid,
            cid: cid,
            referer: referer
        )
        let authorizedRequest = try await BiliCredentialRequestAuthorizer()
            .authorize(catalogRequest)
        let catalogResponse = try await transport.send(authorizedRequest)
        let catalog = try Self.catalogObservation(from: catalogResponse)

        let catalogSummary = "m4-subtitle-catalog status=200 content-type=json "
            + "bytes=\(catalogResponse.body.count) tracks=\(catalog.trackCount) "
            + "usable-tracks=\(catalog.usableTrackCount) "
            + "needs-login=\(catalog.needsLogin) "
            + "envelope-fields=\(catalog.envelopeFieldTypes.joined(separator: ",")) "
            + "data-fields=\(catalog.dataFieldTypes.joined(separator: ",")) "
            + "subtitle-fields=\(catalog.subtitleFieldTypes.joined(separator: ",")) "
            + "track-fields=\(catalog.trackFieldTypes.joined(separator: ","))"
        XCTContext.runActivity(named: catalogSummary) { _ in }
        guard catalog.hasSuccessfulEnvelope,
              catalog.hasSubtitleCatalog
        else {
            throw ProbeFailure.invalidJSONShape
        }
        guard catalog.usableTrackCount > 0 else {
            throw XCTSkip("当前显式样本没有字幕轨，请更换带字幕的公开视频")
        }
        guard catalog.hasMinimumTrackFields else {
            throw ProbeFailure.invalidJSONShape
        }
        guard let subtitleURL = catalog.firstSubtitleURL else {
            throw ProbeFailure.invalidSubtitleURL
        }

        let host = try Self.validatedSubtitleHost(for: subtitleURL)
        let subtitleResponse = try await transport.send(
            HTTPRequest(
                url: subtitleURL,
                headers: [
                    "Accept": "application/json",
                    "Referer": referer,
                    "User-Agent": "BiliKitMac-M4ContractProbe/0.1",
                ]
            )
        )
        let body = try Self.subtitleBodyObservation(from: subtitleResponse)
        let bodySummary = "m4-subtitle-body status=200 host=\(host) "
            + "content-type=json bytes=\(subtitleResponse.body.count) "
            + "cues=\(body.cueCount) "
            + "cue-fields=\(body.cueFieldTypes.joined(separator: ","))"
        XCTContext.runActivity(named: bodySummary) { _ in }
        guard body.hasMinimumCueFields else {
            throw ProbeFailure.invalidJSONShape
        }

        let identity = PlaybackItemIdentity(bvid: bvid, cid: cid)
        let productionModel = AppEnvironment.live.makeSubtitleViewModel()
        productionModel.selectVideo(identity)
        await productionModel.waitForCurrentTask()
        guard productionModel.state == .ready(identity),
              !productionModel.tracks.isEmpty,
              productionModel.selectedTrackID != nil
        else {
            throw ProbeFailure.productionDecoderFailed
        }
        XCTContext.runActivity(
            named: "m4-subtitle-production tracks=\(productionModel.tracks.count) decoder=ready"
        ) { _ in }
        productionModel.reset()
    }

    private static func firstPageCID(
        bvid: String,
        referer: String,
        transport: URLSessionTransport
    ) async throws -> Int64 {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.bilibili.com"
        components.path = "/x/player/pagelist"
        components.queryItems = [URLQueryItem(name: "bvid", value: bvid)]
        guard let url = components.url else { throw ProbeFailure.invalidRequest }
        let response = try await transport.send(
            HTTPRequest(
                url: url,
                headers: [
                    "Accept": "application/json",
                    "Referer": referer,
                    "User-Agent": "BiliKitMac-M4ContractProbe/0.1",
                ]
            )
        )
        guard response.statusCode == 200 else {
            throw ProbeFailure.unexpectedStatus
        }
        guard response.body.count <= maximumPageListSize else {
            throw ProbeFailure.responseTooLarge
        }
        guard contentType(response).contains("json") else {
            throw ProbeFailure.unexpectedContentType
        }
        guard let envelope = try JSONSerialization.jsonObject(
            with: response.body
        ) as? [String: Any],
              envelope["code"] as? Int == 0,
              let pages = envelope["data"] as? [[String: Any]],
              let firstCID = pages.first?["cid"] as? NSNumber,
              firstCID.int64Value > 0
        else {
            throw ProbeFailure.invalidJSONShape
        }
        return firstCID.int64Value
    }

    private static func catalogRequest(
        bvid: String,
        cid: Int64,
        referer: String
    ) throws -> HTTPRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.bilibili.com"
        components.path = "/x/player/v2"
        components.queryItems = [
            URLQueryItem(name: "bvid", value: bvid),
            URLQueryItem(name: "cid", value: String(cid)),
        ]
        guard let url = components.url else { throw ProbeFailure.invalidRequest }
        return HTTPRequest(
            url: url,
            headers: [
                "Accept": "application/json",
                "Referer": referer,
                "User-Agent": "BiliKitMac-M4ContractProbe/0.1",
            ]
        )
    }

    private static func catalogObservation(
        from response: HTTPResponse
    ) throws -> CatalogObservation {
        guard response.statusCode == 200 else {
            throw ProbeFailure.unexpectedStatus
        }
        guard response.body.count <= maximumCatalogSize else {
            throw ProbeFailure.responseTooLarge
        }
        guard contentType(response).contains("json") else {
            throw ProbeFailure.unexpectedContentType
        }
        guard let envelope = try JSONSerialization.jsonObject(
            with: response.body
        ) as? [String: Any] else {
            throw ProbeFailure.invalidJSONShape
        }
        let data = envelope["data"] as? [String: Any]
        let subtitle = data?["subtitle"] as? [String: Any]
        let tracks = subtitle?["subtitles"] as? [[String: Any]] ?? []
        let usableTracks = try tracks.compactMap { track -> ([String: Any], URL)? in
            guard let rawURL = track["subtitle_url"] as? String else {
                throw ProbeFailure.invalidJSONShape
            }
            guard !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let absolute = rawURL.hasPrefix("//") ? "https:\(rawURL)" : rawURL
            guard let url = URL(string: absolute) else {
                throw ProbeFailure.invalidSubtitleURL
            }
            return (track, url)
        }
        let firstTrack = usableTracks.first?.0
        let firstURL = usableTracks.first?.1
        return CatalogObservation(
            needsLogin: data?["need_login_subtitle"] as? Bool ?? false,
            trackCount: tracks.count,
            usableTrackCount: usableTracks.count,
            envelopeFieldTypes: fieldTypes(envelope),
            dataFieldTypes: data.map(fieldTypes) ?? [],
            subtitleFieldTypes: subtitle.map(fieldTypes) ?? [],
            trackFieldTypes: firstTrack.map(fieldTypes) ?? [],
            hasSuccessfulEnvelope:
                (envelope["code"] as? NSNumber)?.intValue == 0
                && data != nil,
            hasSubtitleCatalog:
                subtitle != nil
                && subtitle?["subtitles"] is [[String: Any]],
            hasMinimumTrackFields:
                (firstTrack?["id"] is NSNumber || firstTrack?["id_str"] is String)
                && firstTrack?["lan"] is String
                && firstTrack?["subtitle_url"] is String,
            firstSubtitleURL: firstURL
        )
    }

    private static func validatedSubtitleHost(for url: URL) throws -> String {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              allowedSubtitleHosts.contains(host),
              (components.port == nil || components.port == 443),
              components.user == nil,
              components.password == nil,
              components.fragment == nil
        else {
            throw ProbeFailure.untrustedSubtitleOrigin
        }
        return host
    }

    private static func subtitleBodyObservation(
        from response: HTTPResponse
    ) throws -> SubtitleBodyObservation {
        guard response.statusCode == 200 else {
            throw ProbeFailure.unexpectedStatus
        }
        guard response.body.count <= maximumSubtitleBodySize else {
            throw ProbeFailure.responseTooLarge
        }
        guard contentType(response).contains("json") else {
            throw ProbeFailure.unexpectedContentType
        }
        guard let payload = try JSONSerialization.jsonObject(
            with: response.body
        ) as? [String: Any],
              let cues = payload["body"] as? [[String: Any]],
              let firstCue = cues.first
        else {
            throw ProbeFailure.invalidJSONShape
        }
        return SubtitleBodyObservation(
            cueCount: cues.count,
            cueFieldTypes: fieldTypes(firstCue),
            hasMinimumCueFields: firstCue["from"] is NSNumber
                && firstCue["to"] is NSNumber
                && firstCue["content"] is String
        )
    }

    private static func contentType(_ response: HTTPResponse) -> String {
        response.headers.first(where: {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value.lowercased() ?? ""
    }

    private static func isValidBVID(_ value: String) -> Bool {
        value.count == 12
            && value.hasPrefix("BV")
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func fieldTypes(_ dictionary: [String: Any]) -> [String] {
        dictionary.keys.sorted().map { key in
            "\(key):\(JSONValueKind(dictionary[key]).rawValue)"
        }
    }

    private struct CatalogObservation {
        let needsLogin: Bool
        let trackCount: Int
        let usableTrackCount: Int
        let envelopeFieldTypes: [String]
        let dataFieldTypes: [String]
        let subtitleFieldTypes: [String]
        let trackFieldTypes: [String]
        let hasSuccessfulEnvelope: Bool
        let hasSubtitleCatalog: Bool
        let hasMinimumTrackFields: Bool
        let firstSubtitleURL: URL?
    }

    private struct SubtitleBodyObservation {
        let cueCount: Int
        let cueFieldTypes: [String]
        let hasMinimumCueFields: Bool
    }

    private enum JSONValueKind: String {
        case string
        case number
        case boolean
        case array
        case object
        case null
        case unknown

        init(_ value: Any?) {
            switch value {
            case is String:
                self = .string
            case let number as NSNumber:
                self = CFGetTypeID(number) == CFBooleanGetTypeID()
                    ? .boolean : .number
            case is [Any]:
                self = .array
            case is [String: Any]:
                self = .object
            case is NSNull:
                self = .null
            default:
                self = .unknown
            }
        }
    }

    private enum ProbeFailure: Error {
        case invalidRequest
        case unexpectedStatus
        case responseTooLarge
        case unexpectedContentType
        case invalidJSONShape
        case invalidSubtitleURL
        case untrustedSubtitleOrigin
        case productionDecoderFailed
    }
}
