import BiliApplication
import BiliBrowseFeature
import BiliNetworking
import Foundation
import XCTest

@testable import BiliKit

final class M4AuthenticatedContractProbeTests: XCTestCase {
    private static let maximumPageListSize = 512 * 1_024

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
        let identity = PlaybackItemIdentity(bvid: bvid, cid: cid)
        let productionModel = AppEnvironment.live().makeSubtitleViewModel()
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
        guard
            let envelope = try JSONSerialization.jsonObject(
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

    private enum ProbeFailure: Error {
        case invalidRequest
        case unexpectedStatus
        case responseTooLarge
        case unexpectedContentType
        case invalidJSONShape
        case productionDecoderFailed
    }
}
