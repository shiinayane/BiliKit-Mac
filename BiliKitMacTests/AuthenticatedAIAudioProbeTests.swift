@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import BiliNetworking
import BiliPlayback
import Foundation
import XCTest

@testable import BiliAPI
@testable import BiliAuth

/// 显式 opt-in 的登录态 AI 音轨事实探针。
///
/// 探针不输出输入 identity、账号信息、远端 URL、Cookie、响应正文或个人内容。
final class AuthenticatedAIAudioProbeTests: XCTestCase {
    @MainActor
    func testAuthenticatedAIAudioWhenExplicitlyConfigured() async throws {
        guard let input = try LocalProbeInput.load() else {
            throw XCTSkip("仅在显式提供安全本机输入文件时运行 AI 音轨探针")
        }
        guard let bvid = input["bvid"], Self.isValidBVID(bvid),
            let rawCID = input["cid"],
            let cid = Int64(rawCID),
            cid > 0
        else {
            throw ProbeFailure.invalidInput
        }
        do {
            try await Self.runProbe(bvid: bvid, cid: cid)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ProbeFailure {
            throw failure
        } catch {
            throw ProbeFailure.remoteValidationFailed
        }
    }

    @MainActor
    private static func runProbe(bvid: String, cid: Int64) async throws {
        recordStage("input-ready")

        let authorizer = BiliCredentialRequestAuthorizer()
        guard case .signedIn = try await authorizer.restoreAccountSession() else {
            throw ProbeFailure.missingAuthenticatedSession
        }
        recordStage("session-ready")

        let apiTransport = ProbeAPITransport()
        defer { apiTransport.invalidateAndCancel() }
        let client = BiliAPIClient(
            transport: apiTransport,
            requestAuthorizer: authorizer
        )
        let originalPlayback = try await client.playback(for: bvid, cid: cid)
        guard let catalogBody = await apiTransport.firstPlayURLBody() else {
            throw ProbeFailure.missingCatalogBody
        }
        let catalog = try Self.catalog(from: catalogBody)
        guard catalog.support, let selected = catalog.items.first else {
            throw ProbeFailure.unsupportedCatalog
        }
        recordStage("catalog-ready")

        let referer = "https://www.bilibili.com/video/\(bvid)/"
        let userAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 BiliKitMac/0.1"
        let aiRequest = try Self.playURLRequest(
            bvid: bvid,
            cid: cid,
            language: selected.languageCode,
            referer: referer,
            userAgent: userAgent
        )
        let authorizedRequest = try await authorizer.authorize(aiRequest)
        let aiResponse = try await HTTPClient(transport: apiTransport).send(
            authorizedRequest
        )
        let aiPayload = try Self.playURLPayload(from: aiResponse)
        guard aiPayload.currentLanguage == selected.languageCode else {
            throw ProbeFailure.currentLanguageMismatch
        }
        let aiAudio = try aiPayload.playURL.dash.audio
            .filter(\.isAACAudio)
            .map { try $0.model(kind: .audio) }
        guard !aiAudio.isEmpty else {
            throw ProbeFailure.missingAIAudio
        }
        recordStage("ai-response-ready")

        let originalAudio = originalPlayback.manifest.audioTracks
            .filter { $0.role == .original }
            .flatMap(\.representations)
        let productionAITracks = originalPlayback.manifest.audioTracks.filter {
            $0.role == .machineGenerated
        }
        guard !productionAITracks.isEmpty else {
            throw ProbeFailure.missingProductionAITrack
        }
        let originalResourcePaths = resourcePathSet(originalAudio)
        let aiResourcePaths = resourcePathSet(aiAudio)
        guard !originalAudio.isEmpty,
            !originalResourcePaths.isEmpty,
            !aiResourcePaths.isEmpty,
            originalResourcePaths != aiResourcePaths
        else {
            throw ProbeFailure.audioSourcesDidNotChange
        }

        let mediaTransport = ProbeMediaTransport()
        defer { mediaTransport.invalidateAndCancel() }
        let loadedIndex = try await RepresentationIndexLoader(
            rangeClient: HTTPRangeClient(transport: mediaTransport)
        ).load(
            for: aiAudio[0],
            headers: [
                "Referer": referer,
                "User-Agent": userAgent,
            ]
        )
        let mediaObservation = await mediaTransport.observation()
        guard !loadedIndex.index.references.isEmpty,
            loadedIndex.completeMediaLength != nil,
            mediaObservation.requestCount > 0,
            !mediaObservation.sawCookie
        else {
            throw ProbeFailure.mediaIndexNotReady
        }

        let engine = AVPlayerEngine()
        defer { engine.stop() }
        try await engine.load(
            originalPlayback,
            identity: PlaybackItemIdentity(bvid: bvid, cid: cid)
        )
        guard let item = engine.player.currentItem,
            let audibleGroup = try await item.asset.loadMediaSelectionGroup(
                for: .audible
            ),
            audibleGroup.options.count >= 2,
            let initialOption = item.currentMediaSelection.selectedMediaOption(
                in: audibleGroup
            ),
            let alternateOption = audibleGroup.options.first(where: {
                $0 != initialOption
            })
        else {
            throw ProbeFailure.systemMediaSelectionNotReady
        }
        item.select(alternateOption, in: audibleGroup)
        guard
            item.currentMediaSelection.selectedMediaOption(
                in: audibleGroup
            ) == alternateOption
        else {
            throw ProbeFailure.systemMediaSelectionNotReady
        }

        let productionTypes = Array(Set(catalog.items.map(\.productionType)))
            .sorted()
        let summary = [
            "authenticated-ai-audio",
            "catalog-count=\(catalog.items.count)",
            "production-types=\(productionTypes)",
            "selected-current-match=true",
            "original-aac=\(originalAudio.count)",
            "ai-aac=\(aiAudio.count)",
            "production-ai-tracks=\(productionAITracks.count)",
            "system-audible-options=\(audibleGroup.options.count)",
            "system-selection-ready=true",
            "sources-differ=true",
            "media-index-ready=true",
            "media-cookie=false",
        ].joined(separator: " ")
        XCTContext.runActivity(named: summary) { _ in }
    }

    @MainActor
    private static func recordStage(_ stage: String) {
        FileHandle.standardError.write(
            Data("authenticated-ai-audio-stage stage=\(stage)\n".utf8)
        )
        XCTContext.runActivity(
            named: "authenticated-ai-audio-stage stage=\(stage)"
        ) { _ in }
    }

    private static func catalog(from body: Data) throws -> LanguageCatalog {
        guard body.count <= 5 * 1_024 * 1_024 else {
            throw ProbeFailure.responseTooLarge
        }
        let envelope = try JSONDecoder().decode(
            CatalogEnvelope.self,
            from: body
        )
        guard envelope.code == 0, let catalog = envelope.data?.language,
            (1...32).contains(catalog.items.count),
            catalog.items.allSatisfy({
                isAllowedLanguage($0.languageCode)
                    && $0.title.count <= 128
                    && !$0.title.isEmpty
                    && $0.title.unicodeScalars.allSatisfy {
                        !CharacterSet.controlCharacters.contains($0)
                    }
            })
        else {
            throw ProbeFailure.invalidCatalog
        }
        return catalog
    }

    private static func playURLPayload(
        from response: HTTPResponse
    ) throws -> AIAudioEnvelope {
        guard response.body.count <= 5 * 1_024 * 1_024,
            Self.looksLikeJSON(response)
        else {
            throw ProbeFailure.invalidResponse
        }
        let envelope = try JSONDecoder().decode(
            AIAudioEnvelope.self,
            from: response.body
        )
        guard envelope.code == 0, envelope.data != nil else {
            throw ProbeFailure.apiRejected
        }
        return envelope
    }

    private static func playURLRequest(
        bvid: String,
        cid: Int64,
        language: String,
        referer: String,
        userAgent: String
    ) throws -> HTTPRequest {
        var components = URLComponents(
            url: BiliAPIClient.productionBaseURL,
            resolvingAgainstBaseURL: false
        )
        components?.path = "/x/player/playurl"
        components?.queryItems = [
            URLQueryItem(name: "bvid", value: bvid),
            URLQueryItem(name: "cid", value: String(cid)),
            URLQueryItem(name: "qn", value: "120"),
            URLQueryItem(name: "fnval", value: "976"),
            URLQueryItem(name: "fnver", value: "0"),
            URLQueryItem(name: "fourk", value: "1"),
            URLQueryItem(name: "cur_language", value: language),
        ]
        guard let url = components?.url else {
            throw ProbeFailure.invalidRequest
        }
        return HTTPRequest(
            url: url,
            headers: [
                "Accept": "application/json",
                "Referer": referer,
                "User-Agent": userAgent,
            ]
        )
    }

    private static func resourcePathSet(
        _ representations: [MediaRepresentation]
    ) -> Set<String> {
        Set(
            representations.flatMap(\.urlCandidates).compactMap { url in
                URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false
                )?.percentEncodedPath
            }.filter { !$0.isEmpty }
        )
    }

    private static func looksLikeJSON(_ response: HTTPResponse) -> Bool {
        let contentType = response.headers.first(where: {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value.lowercased()
        guard contentType?.contains("json") == true,
            let firstByte = response.body.first(where: {
                ![9, 10, 13, 32].contains($0)
            })
        else {
            return false
        }
        return firstByte == 0x7B
    }

    private static func isAllowedLanguage(_ value: String) -> Bool {
        guard (2...35).contains(value.count) else { return false }
        let subtags = value.split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard let primary = subtags.first,
            (2...3).contains(primary.count),
            primary.allSatisfy({
                $0.isASCII && $0.isLetter && $0.isLowercase
            })
        else {
            return false
        }
        return subtags.dropFirst().allSatisfy { subtag in
            (1...8).contains(subtag.count)
                && subtag.allSatisfy {
                    $0.isASCII && ($0.isLetter || $0.isNumber)
                }
        }
    }

    private static func isValidBVID(_ value: String) -> Bool {
        value.count == 12
            && value.hasPrefix("BV")
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private enum ProbeFailure: Error {
        case invalidInput
        case invalidRequest
        case missingAuthenticatedSession
        case missingCatalogBody
        case responseTooLarge
        case invalidCatalog
        case unsupportedCatalog
        case invalidResponse
        case apiRejected
        case currentLanguageMismatch
        case missingAIAudio
        case missingProductionAITrack
        case audioSourcesDidNotChange
        case mediaIndexNotReady
        case systemMediaSelectionNotReady
        case remoteValidationFailed
    }
}

private struct CatalogEnvelope: Decodable {
    let code: Int
    let data: CatalogData?
}

private struct CatalogData: Decodable {
    let language: LanguageCatalog?
}

private struct LanguageCatalog: Decodable {
    let support: Bool
    let items: [LanguageItem]
}

private struct LanguageItem: Decodable {
    let languageCode: String
    let title: String
    let productionType: Int

    private enum CodingKeys: String, CodingKey {
        case languageCode = "lang"
        case title
        case productionType = "production_type"
    }
}

private struct AIAudioEnvelope: Decodable {
    let code: Int
    let data: AIAudioData?

    var playURL: PlayURLPayload {
        get throws {
            guard let data else {
                throw AIAudioEnvelopeError.missingData
            }
            return data.playURL
        }
    }

    var currentLanguage: String? { data?.currentLanguage }
}

private struct AIAudioData: Decodable {
    let playURL: PlayURLPayload
    let currentLanguage: String?

    private enum CodingKeys: String, CodingKey {
        case currentLanguage = "cur_language"
        case dash
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentLanguage = try container.decodeIfPresent(
            String.self,
            forKey: .currentLanguage
        )
        playURL = try PlayURLPayload(from: decoder)
    }
}

private enum AIAudioEnvelopeError: Error {
    case missingData
}

private actor ProbeAPITransport: HTTPTransport {
    private let transport: URLSessionTransport
    private var initialPlayURLBody: Data?

    init() {
        transport = Self.ephemeralTransport()
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await transport.send(request)
        if request.url.path == "/x/player/playurl",
            initialPlayURLBody == nil
        {
            initialPlayURLBody = response.body
        }
        return response
    }

    func firstPlayURLBody() -> Data? {
        initialPlayURLBody
    }

    nonisolated func invalidateAndCancel() {
        transport.invalidateAndCancel()
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
}

private actor ProbeMediaTransport: HTTPTransport {
    private let transport: URLSessionTransport
    private var requestCount = 0
    private var sawCookie = false

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
        requestCount += 1
        sawCookie =
            sawCookie
            || request.headers.keys.contains(where: {
                $0.caseInsensitiveCompare("Cookie") == .orderedSame
            })
        return try await transport.send(request)
    }

    func observation() -> MediaObservation {
        MediaObservation(requestCount: requestCount, sawCookie: sawCookie)
    }

    nonisolated func invalidateAndCancel() {
        transport.invalidateAndCancel()
    }
}

private struct MediaObservation: Sendable {
    let requestCount: Int
    let sawCookie: Bool
}
