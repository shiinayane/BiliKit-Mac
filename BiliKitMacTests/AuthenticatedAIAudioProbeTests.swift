@preconcurrency import AVFoundation
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import XCTest

@testable import BiliAPI
@testable import BiliAuth
@testable import BiliPlayback

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
        guard catalog.support else {
            throw ProbeFailure.unsupportedCatalog
        }
        recordStage("catalog-ready")

        let originalAudio = originalPlayback.manifest.audioTracks
            .filter { $0.role == .original }
            .flatMap(\.representations)
        let productionAITracks = originalPlayback.manifest.audioTracks.filter {
            $0.role == .machineGenerated
        }
        let catalogLanguages = Set(catalog.items.map(\.languageCode))
        let productionLanguages = Set(
            productionAITracks.compactMap(\.languageTag)
        )
        guard productionAITracks.count == catalog.items.count,
            productionLanguages == catalogLanguages,
            let selectedTrack = productionAITracks.first,
            !selectedTrack.representations.isEmpty
        else {
            throw ProbeFailure.missingProductionAITrack
        }
        let aiAudio = selectedTrack.representations
        let apiObservation = await apiTransport.observation()
        guard apiObservation.basePlayURLRequestCount == 1,
            apiObservation.aiPlayURLRequestCount == catalog.items.count,
            apiObservation.uniqueAILanguageCount == catalog.items.count,
            !apiObservation.sawInvalidPlayURLShape
        else {
            throw ProbeFailure.playURLRequestBoundExceeded
        }
        recordStage("ai-response-ready")

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
        let rangeClient = HTTPRangeClient(transport: mediaTransport)
        let loadedIndex = try await RepresentationIndexLoader(
            rangeClient: rangeClient
        ).load(
            for: aiAudio[0],
            headers: originalPlayback.mediaHeaders
        )
        let mediaObservation = await mediaTransport.observation()
        guard !loadedIndex.index.references.isEmpty,
            loadedIndex.completeMediaLength != nil,
            mediaObservation.requestCount > 0,
            !mediaObservation.sawCookie
        else {
            throw ProbeFailure.mediaIndexNotReady
        }

        var expectedIFrameRangesByPath: [String: Set<String>] = [:]
        for video in originalPlayback.manifest.videoRepresentations {
            let loadedVideoIndex = try await RepresentationIndexLoader(
                rangeClient: rangeClient
            ).load(for: video, headers: originalPlayback.mediaHeaders)
            expectedIFrameRangesByPath["video/\(video.id)-iframe.m3u8"] = Set(
                loadedVideoIndex.index.references.map { reference in
                    let range = reference.byteRange
                    let length = UInt64(range.endInclusive - range.start) + 1
                    return "#EXT-X-BYTERANGE:\(length)@\(range.start)"
                }
            )
        }
        guard expectedIFrameRangesByPath.values.contains(where: { !$0.isEmpty }) else {
            throw ProbeFailure.missingIFrameFragmentRanges
        }

        let serverRegistry = ProbeLoopbackServerRegistry()
        let bridge = DASHToHLSBridge(
            rangeClient: rangeClient,
            serverFactory: { rangeClient in
                serverRegistry.create(rangeClient: rangeClient)
            }
        )
        let engine = AVPlayerEngine(bridge: bridge)
        engine.player.isMuted = true
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
        let systemAudioNames = audibleGroup.options.map(\.displayName)
        guard
            systemAudioNames.count
                == originalPlayback.manifest.audioTracks.count,
            systemAudioNames.allSatisfy({ name in
                let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return !normalized.isEmpty
                    && !Self.isAllowedLanguage(normalized)
            })
        else {
            throw ProbeFailure.systemMediaSelectionNamesNotFriendly
        }
        item.select(alternateOption, in: audibleGroup)
        guard
            item.currentMediaSelection.selectedMediaOption(
                in: audibleGroup
            ) == alternateOption
        else {
            throw ProbeFailure.systemMediaSelectionNotReady
        }

        let server = try XCTUnwrap(serverRegistry.latestServer)
        let masterURL = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
        let masterPlaylist = try await Self.loopbackPlaylist(at: masterURL)
        let iFramePaths = originalPlayback.manifest.videoRepresentations
            .map { "video/\($0.id)-iframe.m3u8" }
            .filter { masterPlaylist.contains($0) }
        guard !iFramePaths.isEmpty else {
            throw ProbeFailure.missingRealIFrameVariant
        }
        let iFrameRequestBaseline = try Dictionary(
            uniqueKeysWithValues: iFramePaths.map { path in
                (path, try server.requestCount(method: "GET", at: path))
            }
        )
        item.preferredForwardBufferDuration = 1
        engine.player.playImmediately(atRate: 4)
        try await Self.waitUntil {
            try iFramePaths.contains { path in
                try server.requestCount(method: "GET", at: path)
                    > iFrameRequestBaseline[path, default: 0]
            }
        }
        let requestedIFramePaths = try iFramePaths.filter { path in
            try server.requestCount(method: "GET", at: path)
                > iFrameRequestBaseline[path, default: 0]
        }
        guard !requestedIFramePaths.isEmpty else {
            throw ProbeFailure.missingRealIFrameVariant
        }
        for path in requestedIFramePaths {
            let playlistURL = masterURL.deletingLastPathComponent()
                .appendingPathComponent(path)
            let playlist = try await Self.loopbackPlaylist(at: playlistURL)
            let declaredRanges = Set(
                playlist.split(separator: "\n")
                    .map(String.init)
                    .filter { $0.hasPrefix("#EXT-X-BYTERANGE:") }
            )
            guard !declaredRanges.isEmpty,
                declaredRanges == expectedIFrameRangesByPath[path]
            else {
                throw ProbeFailure.invalidIFrameFragmentRanges
            }
        }
        engine.pause()
        let finalMediaObservation = await mediaTransport.observation()
        guard !finalMediaObservation.sawCredentialHeader,
            item.status == .readyToPlay
        else {
            throw ProbeFailure.realIFrameTrickPlayFailed
        }

        let publicTransport = ProbePublicTransport()
        defer { publicTransport.invalidateAndCancel() }
        let publicClient = BiliAPIClient(transport: publicTransport)
        let related = try await publicClient.relatedVideos(to: bvid)
        let replacementVideo = try XCTUnwrap(
            related.first(where: { $0.bvid != bvid })
        )
        let replacementPages = try await publicClient.pages(
            for: replacementVideo.bvid
        )
        let replacementCID = try XCTUnwrap(replacementPages.first?.cid)
        let replacementPlayback = try await publicClient.playback(
            for: replacementVideo.bvid,
            cid: replacementCID
        )
        let firstItem = item
        try await engine.load(
            replacementPlayback,
            identity: PlaybackItemIdentity(
                bvid: replacementVideo.bvid,
                cid: replacementCID
            )
        )
        let replacementItem = try XCTUnwrap(engine.player.currentItem)
        guard replacementItem !== firstItem,
            !server.diagnosticsSnapshot().isRunning
        else {
            throw ProbeFailure.realReplacementFailed
        }
        let replacementServer = try XCTUnwrap(serverRegistry.latestServer)
        try await engine.load(
            originalPlayback,
            identity: PlaybackItemIdentity(bvid: bvid, cid: cid)
        )
        guard let reopenedItem = engine.player.currentItem,
            reopenedItem !== firstItem,
            reopenedItem !== replacementItem,
            !replacementServer.diagnosticsSnapshot().isRunning
        else {
            throw ProbeFailure.realReplacementFailed
        }

        engine.stop()
        guard
            serverRegistry.servers.allSatisfy({
                $0.diagnosticsSnapshot()
                    == LoopbackPlaybackServerDiagnostics(
                        isRunning: false,
                        registeredRouteCount: 0,
                        activeConnectionCount: 0,
                        activeTaskCount: 0
                    )
            })
        else {
            throw ProbeFailure.loopbackCleanupFailed
        }

        let productionTypes = Array(Set(catalog.items.map(\.productionType)))
            .sorted()
        let summary = [
            "authenticated-ai-audio",
            "catalog-count=\(catalog.items.count)",
            "production-types=\(productionTypes)",
            "selected-current-match=true",
            "playurl-base-requests=\(apiObservation.basePlayURLRequestCount)",
            "playurl-ai-requests=\(apiObservation.aiPlayURLRequestCount)",
            "playurl-ai-request-bound=true",
            "original-aac=\(originalAudio.count)",
            "ai-aac=\(aiAudio.count)",
            "production-ai-tracks=\(productionAITracks.count)",
            "system-audible-options=\(audibleGroup.options.count)",
            "system-selection-ready=true",
            "system-friendly-names=true",
            "sources-differ=true",
            "media-index-ready=true",
            "media-cookie=false",
            "iframe-variants=\(iFramePaths.count)",
            "iframe-playlist-on-demand=true",
            "iframe-playlist-full-fragments=true",
            "iframe-media-credentials=false",
            "replacement-aba=true",
            "loopback-clean=true",
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
            (1...8).contains(catalog.items.count),
            catalog.items.allSatisfy({
                isAllowedLanguage($0.languageCode)
                    && $0.productionType == 2
                    && $0.title.count <= 128
                    && !$0.title.isEmpty
                    && $0.title.unicodeScalars.allSatisfy {
                        !CharacterSet.controlCharacters.contains($0)
                    }
            }),
            Set(catalog.items.map(\.languageCode)).count
                == catalog.items.count
        else {
            throw ProbeFailure.invalidCatalog
        }
        return catalog
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

    private static func loopbackPlaylist(at url: URL) async throws -> String {
        guard url.scheme == "http", url.host == "127.0.0.1" else {
            throw ProbeFailure.invalidLoopbackMaster
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse,
            response.statusCode == 200,
            data.count <= 1_024 * 1_024,
            let playlist = String(data: data, encoding: .utf8)
        else {
            throw ProbeFailure.invalidLoopbackMaster
        }
        return playlist
    }

    private static func waitUntil(
        _ condition: @escaping @Sendable () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while try await !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard try await condition() else {
            throw ProbeFailure.timedOut
        }
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
        case missingAuthenticatedSession
        case missingCatalogBody
        case responseTooLarge
        case invalidCatalog
        case unsupportedCatalog
        case missingProductionAITrack
        case playURLRequestBoundExceeded
        case audioSourcesDidNotChange
        case mediaIndexNotReady
        case systemMediaSelectionNotReady
        case systemMediaSelectionNamesNotFriendly
        case missingIFrameFragmentRanges
        case missingRealIFrameVariant
        case invalidIFrameFragmentRanges
        case invalidLoopbackMaster
        case realIFrameTrickPlayFailed
        case realReplacementFailed
        case loopbackCleanupFailed
        case timedOut
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

private actor ProbeAPITransport: HTTPTransport {
    private let transport: URLSessionTransport
    private var initialPlayURLBody: Data?
    private var basePlayURLRequestCount = 0
    private var aiPlayURLRequestCount = 0
    private var aiLanguages = Set<String>()
    private var sawInvalidPlayURLShape = false

    init() {
        transport = Self.ephemeralTransport()
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let isPlayURL = request.url.path == "/x/player/playurl"
        let languageValues =
            URLComponents(
                url: request.url,
                resolvingAgainstBaseURL: false
            )?.queryItems?.filter { $0.name == "cur_language" }
            .compactMap(\.value) ?? []
        if isPlayURL {
            switch languageValues.count {
            case 0:
                basePlayURLRequestCount += 1
            case 1 where !languageValues[0].isEmpty:
                aiPlayURLRequestCount += 1
                if !aiLanguages.insert(languageValues[0]).inserted {
                    sawInvalidPlayURLShape = true
                }
            default:
                sawInvalidPlayURLShape = true
            }
        }
        let response = try await transport.send(request)
        if isPlayURL, languageValues.isEmpty,
            initialPlayURLBody == nil
        {
            initialPlayURLBody = response.body
        }
        return response
    }

    func firstPlayURLBody() -> Data? {
        initialPlayURLBody
    }

    func observation() -> APIRequestObservation {
        APIRequestObservation(
            basePlayURLRequestCount: basePlayURLRequestCount,
            aiPlayURLRequestCount: aiPlayURLRequestCount,
            uniqueAILanguageCount: aiLanguages.count,
            sawInvalidPlayURLShape: sawInvalidPlayURLShape
        )
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

private struct APIRequestObservation: Sendable {
    let basePlayURLRequestCount: Int
    let aiPlayURLRequestCount: Int
    let uniqueAILanguageCount: Int
    let sawInvalidPlayURLShape: Bool
}

private actor ProbePublicTransport: HTTPTransport {
    private let transport: URLSessionTransport

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
        try await transport.send(request)
    }

    nonisolated func invalidateAndCancel() {
        transport.invalidateAndCancel()
    }
}

private actor ProbeMediaTransport: HTTPTransport {
    private let transport: URLSessionTransport
    private var requestCount = 0
    private var sawCookie = false
    private var sawAuthorization = false

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
        sawAuthorization =
            sawAuthorization
            || request.headers.keys.contains(where: {
                $0.caseInsensitiveCompare("Authorization") == .orderedSame
            })
        return try await transport.send(request)
    }

    func observation() -> MediaObservation {
        MediaObservation(
            requestCount: requestCount,
            sawCookie: sawCookie,
            sawAuthorization: sawAuthorization
        )
    }

    nonisolated func invalidateAndCancel() {
        transport.invalidateAndCancel()
    }
}

private struct MediaObservation: Sendable {
    let requestCount: Int
    let sawCookie: Bool
    let sawAuthorization: Bool

    var sawCredentialHeader: Bool {
        sawCookie || sawAuthorization
    }
}

private final class ProbeLoopbackServerRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LoopbackPlaybackServer] = []

    var servers: [LoopbackPlaybackServer] {
        lock.withLock { storage }
    }

    var latestServer: LoopbackPlaybackServer? {
        lock.withLock { storage.last }
    }

    func create(rangeClient: HTTPRangeClient) -> LoopbackPlaybackServer {
        let server = LoopbackPlaybackServer(rangeClient: rangeClient)
        lock.withLock {
            storage.append(server)
        }
        return server
    }
}
