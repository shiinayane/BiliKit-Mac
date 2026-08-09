import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// Bilibili endpoint/DTO adapter；把远端协议限制在 `BiliAPI`，并返回稳定模型。
///
/// 匿名请求永不经过 authorizer。只有显式认证 endpoint 与精确 legacy playurl 才临时授权；
/// playurl 也只有在本地明确无凭据时保持匿名。响应在解码前还要满足状态、大小与
/// Content-Type 边界。actor 隔离可变 transport/WBI cache；跨 `await` 可重入，用户意图的
/// 取消与写回代次仍由上层 owner 管理。
public actor BiliAPIClient: AuthenticatedSessionInvalidating {
    private enum AuthorizationProvenance: Sendable {
        case anonymous
        case authenticated
    }

    private struct AuthorizedResponse<Payload: Sendable>: Sendable {
        let payload: Payload
        let authorizationProvenance: AuthorizationProvenance
    }

    private struct AuthorizedHTTPResponse: Sendable {
        let response: HTTPResponse
        let authorizationProvenance: AuthorizationProvenance
    }

    public static let productionBaseURL: URL = {
        guard let url = URL(string: "https://api.bilibili.com") else {
            preconditionFailure("Static API base URL must be valid")
        }
        return url
    }()

    private static let maximumResponseSize = 5 * 1_024 * 1_024
    private static let maximumSubtitleCatalogSize = 1 * 1_024 * 1_024
    private static let maximumDanmakuSegmentSize = 2 * 1_024 * 1_024

    private var httpClient: HTTPClient
    private var transport: any HTTPTransport
    private let transportFactory: (@Sendable () -> any HTTPTransport)?
    private let requestAuthorizer: (any HTTPRequestAuthorizing)?
    private let baseURL: URL
    private let userAgent: String
    private let decoder: JSONDecoder
    private let timestampProvider: @Sendable () -> Int64
    private let wbiSigner = WBISigner()
    private var cachedWBIKey: CachedWBIKey?
    private var authenticatedSessionEpoch: UInt64 = 0

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        requestAuthorizer: (any HTTPRequestAuthorizing)? = nil,
        transportFactory: (@Sendable () -> any HTTPTransport)? = nil,
        baseURL: URL = BiliAPIClient.productionBaseURL,
        userAgent: String =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 BiliKitMac/0.1",
        timestampProvider: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970)
        }
    ) {
        let activeTransport = transportFactory?() ?? transport
        self.transport = activeTransport
        httpClient = HTTPClient(transport: activeTransport)
        self.transportFactory = transportFactory
        self.requestAuthorizer = requestAuthorizer
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.timestampProvider = timestampProvider
        decoder = JSONDecoder()
    }

    public func popular(
        page: Int = 1,
        pageSize: Int = 20
    ) async throws -> PopularPage {
        guard page > 0, (1...50).contains(pageSize) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: PopularPayload = try await get(
            path: "/x/web-interface/popular",
            queryItems: [
                URLQueryItem(name: "pn", value: String(page)),
                URLQueryItem(name: "ps", value: String(pageSize)),
            ],
            referer: "https://www.bilibili.com/"
        )
        let videos = try payload.list.map { try $0.model() }
        return PopularPage(videos: videos, pageNumber: page, pageSize: pageSize)
    }

    public func searchVideos(
        keyword: String,
        page: Int = 1
    ) async throws -> SearchPage {
        let normalizedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKeyword.isEmpty,
            normalizedKeyword.count <= 100,
            page > 0
        else {
            throw BiliAPIError.invalidRequest
        }
        let parameters = [
            "keyword": normalizedKeyword,
            "page": String(page),
            "search_type": "video",
        ]
        do {
            return try await signedSearch(parameters: parameters, forceKeyRefresh: false)
        } catch BiliAPIError.apiRejected(let code, _) where code == -403 {
            return try await signedSearch(parameters: parameters, forceKeyRefresh: true)
        } catch BiliAPIError.httpStatus(403) {
            return try await signedSearch(parameters: parameters, forceKeyRefresh: true)
        }
    }

    public func videoDetail(for bvid: String) async throws -> VideoDetail {
        guard Self.isValidBVID(bvid) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: VideoDetailPayload = try await get(
            path: "/x/web-interface/view",
            queryItems: [URLQueryItem(name: "bvid", value: bvid)],
            referer: Self.videoReferer(bvid)
        )
        let detail = try payload.model()
        guard detail.bvid == bvid else {
            throw BiliAPIError.decodingFailed
        }
        return detail
    }

    /// 匿名读取相关推荐；该路径永不请求认证授权器。
    public func relatedVideos(to bvid: String) async throws -> [RelatedVideo] {
        guard Self.isValidBVID(bvid) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: [RelatedVideoPayload] = try await get(
            path: "/x/web-interface/archive/related",
            queryItems: [URLQueryItem(name: "bvid", value: bvid)],
            referer: Self.videoReferer(bvid)
        )
        return try payload.map { try $0.model() }
    }

    /// 匿名读取公开 UP 主签名；不会请求认证授权器或 WBI 签名。
    public func uploaderSignature(for ownerID: Int64) async throws -> String? {
        guard ownerID > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let path = "/x/web-interface/card"
        let queryItems = [
            URLQueryItem(name: "mid", value: String(ownerID)),
            URLQueryItem(name: "photo", value: "false"),
        ]
        let url = try endpoint(path: path, queryItems: queryItems)
        guard
            Self.isExactUploaderCardEndpoint(
                url,
                ownerID: ownerID
            )
        else {
            throw BiliAPIError.invalidRequest
        }
        let payload: UploaderCardDataPayload = try await get(
            url: url,
            referer: "https://space.bilibili.com/"
        )
        guard payload.card.mid == ownerID else {
            throw BiliAPIError.decodingFailed
        }
        return payload.card.sign
    }

    public func pages(for bvid: String) async throws -> [VideoPage] {
        guard Self.isValidBVID(bvid) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: [PagePayload] = try await get(
            path: "/x/player/pagelist",
            queryItems: [URLQueryItem(name: "bvid", value: bvid)],
            referer: Self.videoReferer(bvid)
        )
        return try payload.map { try $0.model() }
    }

    /// 取得 AVC/AAC DASH 清单；仅 playurl 可按本地凭据状态选择精确授权或匿名请求。
    public func playback(
        for bvid: String,
        cid: Int64,
        quality: Int = 120
    ) async throws -> VideoPlayback {
        guard Self.isValidBVID(bvid), cid > 0, quality > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let playbackSessionEpoch = authenticatedSessionEpoch
        let referer = Self.videoReferer(bvid)
        let queryItems = [
            URLQueryItem(name: "bvid", value: bvid),
            URLQueryItem(name: "cid", value: String(cid)),
            URLQueryItem(name: "qn", value: String(quality)),
            URLQueryItem(name: "fnval", value: "976"),
            URLQueryItem(name: "fnver", value: "0"),
            URLQueryItem(name: "fourk", value: "1"),
        ]
        let resolved: AuthorizedResponse<PlayURLPayload>
        if requestAuthorizer != nil {
            resolved = try await getWithAuthorizationProvenance(
                path: "/x/player/playurl",
                queryItems: queryItems,
                referer: referer,
                requiresAuthentication: true,
                permitsMissingCredentialFallback: true,
                mapsAuthenticationInvalidation: true
            )
        } else {
            resolved = try await getWithAuthorizationProvenance(
                path: "/x/player/playurl",
                queryItems: queryItems,
                referer: referer
            )
        }
        let payload = resolved.payload

        let video = try payload.dash.video
            .filter(\.isAVCVideo)
            .map { try $0.model(kind: .video) }
        let audio = try payload.dash.audio
            .filter(\.isAACAudio)
            .map { try $0.model(kind: .audio) }
        guard !video.isEmpty else { throw BiliAPIError.noAVCVideo }
        guard !audio.isEmpty else { throw BiliAPIError.noAACAudio }

        var audioTracks = [
            PlaybackAudioTrack(
                id: "original",
                displayName: "原声",
                role: .original,
                isDefault: true,
                isAutoselect: true,
                representations: audio
            )
        ]
        if resolved.authorizationProvenance == .authenticated {
            try requireAuthenticatedSessionEpoch(playbackSessionEpoch)
            audioTracks += try await machineGeneratedAudioTracks(
                catalog: payload.languageCatalog,
                originalAudio: audio,
                bvid: bvid,
                cid: cid,
                quality: quality,
                referer: referer,
                sessionEpoch: playbackSessionEpoch
            )
            try requireAuthenticatedSessionEpoch(playbackSessionEpoch)
        }

        return VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: video,
                audioTracks: audioTracks
            ),
            mediaHeaders: [
                "Referer": referer,
                "User-Agent": userAgent,
            ]
        )
    }

    private func machineGeneratedAudioTracks(
        catalog: AudioLanguageCatalogPayload?,
        originalAudio: [MediaRepresentation],
        bvid: String,
        cid: Int64,
        quality: Int,
        referer: String,
        sessionEpoch: UInt64
    ) async throws -> [PlaybackAudioTrack] {
        let items = catalog?.validatedMachineGeneratedItems() ?? []
        guard !items.isEmpty else { return [] }
        var usedPaths = Self.mediaResourcePaths(originalAudio)
        var displayNames: Set<String> = ["原声"]
        var tracks: [PlaybackAudioTrack] = []
        tracks.reserveCapacity(items.count)
        for item in items {
            try Task.checkCancellation()
            try requireAuthenticatedSessionEpoch(sessionEpoch)
            guard let languageTag = item.validatedLanguageTag,
                let displayName = item.validatedDisplayName
            else {
                continue
            }
            let payload: PlayURLPayload = try await get(
                path: "/x/player/playurl",
                queryItems: [
                    URLQueryItem(name: "bvid", value: bvid),
                    URLQueryItem(name: "cid", value: String(cid)),
                    URLQueryItem(name: "qn", value: String(quality)),
                    URLQueryItem(name: "fnval", value: "976"),
                    URLQueryItem(name: "fnver", value: "0"),
                    URLQueryItem(name: "fourk", value: "1"),
                    URLQueryItem(name: "cur_language", value: languageTag),
                ],
                referer: referer,
                requiresAuthentication: true,
                mapsAuthenticationInvalidation: true
            )
            try requireAuthenticatedSessionEpoch(sessionEpoch)
            guard payload.currentLanguage == languageTag,
                payload.currentProductionType == item.productionType
            else {
                continue
            }
            let representations: [MediaRepresentation]
            do {
                representations = try payload.dash.audio
                    .filter(\.isAACAudio)
                    .map { try $0.model(kind: .audio) }
            } catch {
                continue
            }
            let paths = Self.mediaResourcePaths(representations)
            guard !representations.isEmpty, !paths.isEmpty,
                paths.isDisjoint(with: usedPaths),
                displayNames.insert(displayName).inserted
            else {
                continue
            }
            usedPaths.formUnion(paths)
            tracks.append(
                PlaybackAudioTrack(
                    id: "machine-generated:\(languageTag)",
                    displayName: displayName,
                    languageTag: languageTag,
                    role: .machineGenerated,
                    isDefault: false,
                    isAutoselect: true,
                    representations: representations
                )
            )
        }
        return tracks
    }

    private func requireAuthenticatedSessionEpoch(_ expected: UInt64) throws {
        guard authenticatedSessionEpoch == expected else {
            throw CancellationError()
        }
    }

    private static func mediaResourcePaths(
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

    func subtitleResources(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleRemoteTrack] {
        guard Self.isValidBVID(identity.bvid), identity.cid > 0 else {
            throw BiliAPIError.invalidRequest
        }
        guard requestAuthorizer != nil else {
            throw BiliAPIError.authorizationRequired
        }
        do {
            return try await signedSubtitleResources(
                for: identity,
                forceKeyRefresh: false
            )
        } catch BiliAPIError.apiRejected(let code, _) where code == -403 {
            return try await signedSubtitleResources(
                for: identity,
                forceKeyRefresh: true
            )
        } catch BiliAPIError.httpStatus(403) {
            return try await signedSubtitleResources(
                for: identity,
                forceKeyRefresh: true
            )
        }
    }

    func danmakuSegmentData(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> Data {
        guard Self.isValidBVID(identity.bvid),
            identity.cid > 0,
            (1...DanmakuSegmentUseCase.maximumSegmentIndex).contains(index)
        else {
            throw BiliAPIError.invalidRequest
        }
        let url = try endpoint(
            path: "/x/v2/dm/web/seg.so",
            queryItems: [
                URLQueryItem(name: "type", value: "1"),
                URLQueryItem(name: "oid", value: String(identity.cid)),
                URLQueryItem(name: "segment_index", value: String(index)),
            ]
        )
        let request = HTTPRequest(
            url: url,
            headers: [
                "Accept": "application/octet-stream",
                "Referer": Self.videoReferer(identity.bvid),
                "User-Agent": userAgent,
            ]
        )
        let response: HTTPResponse
        do {
            response = try await httpClient.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPClientError {
            switch error {
            case .unacceptableStatusCode(let status):
                throw BiliAPIError.httpStatus(status)
            case .nonHTTPResponse:
                throw BiliAPIError.transportFailure
            }
        } catch {
            throw BiliAPIError.transportFailure
        }
        guard !response.body.isEmpty,
            response.body.count <= Self.maximumDanmakuSegmentSize
        else {
            if response.body.isEmpty {
                throw BiliAPIError.invalidDanmakuData
            }
            throw BiliAPIError.responseTooLarge(response.body.count)
        }
        guard Self.looksLikeProtobuf(response) else {
            throw BiliAPIError.nonProtobufResponse
        }
        return response.body
    }

    public func watchHistory(
        after continuation: WatchHistoryContinuation? = nil,
        pageSize: Int = 20
    ) async throws -> WatchHistoryPage {
        guard (1...50).contains(pageSize) else {
            throw BiliAPIError.invalidRequest
        }
        let cursor: WatchHistoryCursorPayload
        if let continuation {
            cursor = try WatchHistoryCursorPayload(continuation)
        } else {
            cursor = .initial
        }
        let payload: WatchHistoryPayload = try await get(
            path: "/x/web-interface/history/cursor",
            queryItems: [
                URLQueryItem(name: "max", value: String(cursor.maximum)),
                URLQueryItem(name: "view_at", value: String(cursor.viewedAt)),
                URLQueryItem(name: "business", value: cursor.business),
                URLQueryItem(name: "ps", value: String(pageSize)),
            ],
            referer: "https://www.bilibili.com/account/history",
            requiresAuthentication: true
        )
        return try payload.model(pageSize: pageSize)
    }

    /// 认证会话失效时取消旧 transport 请求、换入干净 session，并丢弃关联 WBI key。
    public func invalidateAuthenticatedSession() {
        authenticatedSessionEpoch &+= 1
        if let invalidating = transport as? any HTTPTransportInvalidating {
            invalidating.invalidateAndCancel()
        }
        if let transportFactory {
            let replacement = transportFactory()
            transport = replacement
            httpClient = HTTPClient(transport: replacement)
        }
        cachedWBIKey = nil
    }

    private func get<Payload: Decodable & Sendable>(
        path: String,
        queryItems: [URLQueryItem],
        referer: String,
        requiresAuthentication: Bool = false,
        permitsMissingCredentialFallback: Bool = false,
        mapsAuthenticationInvalidation: Bool = false,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> Payload {
        try await getWithAuthorizationProvenance(
            path: path,
            queryItems: queryItems,
            referer: referer,
            requiresAuthentication: requiresAuthentication,
            permitsMissingCredentialFallback: permitsMissingCredentialFallback,
            mapsAuthenticationInvalidation: mapsAuthenticationInvalidation,
            maximumResponseSize: maximumResponseSize
        ).payload
    }

    private func getWithAuthorizationProvenance<
        Payload: Decodable & Sendable
    >(
        path: String,
        queryItems: [URLQueryItem],
        referer: String,
        requiresAuthentication: Bool = false,
        permitsMissingCredentialFallback: Bool = false,
        mapsAuthenticationInvalidation: Bool = false,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> AuthorizedResponse<Payload> {
        let url = try endpoint(path: path, queryItems: queryItems)
        return try await getWithAuthorizationProvenance(
            url: url,
            referer: referer,
            requiresAuthentication: requiresAuthentication,
            permitsMissingCredentialFallback: permitsMissingCredentialFallback,
            mapsAuthenticationInvalidation: mapsAuthenticationInvalidation,
            maximumResponseSize: maximumResponseSize
        )
    }

    private func get<Payload: Decodable & Sendable>(
        path: String,
        percentEncodedQuery: String,
        referer: String,
        requiresAuthentication: Bool = false,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> Payload {
        let url = try endpoint(
            path: path,
            percentEncodedQuery: percentEncodedQuery
        )
        return try await get(
            url: url,
            referer: referer,
            requiresAuthentication: requiresAuthentication,
            maximumResponseSize: maximumResponseSize
        )
    }

    private func get<Payload: Decodable & Sendable>(
        url: URL,
        referer: String,
        requiresAuthentication: Bool = false,
        permitsMissingCredentialFallback: Bool = false,
        mapsAuthenticationInvalidation: Bool = false,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> Payload {
        try await getWithAuthorizationProvenance(
            url: url,
            referer: referer,
            requiresAuthentication: requiresAuthentication,
            permitsMissingCredentialFallback: permitsMissingCredentialFallback,
            mapsAuthenticationInvalidation: mapsAuthenticationInvalidation,
            maximumResponseSize: maximumResponseSize
        ).payload
    }

    private func getWithAuthorizationProvenance<
        Payload: Decodable & Sendable
    >(
        url: URL,
        referer: String,
        requiresAuthentication: Bool = false,
        permitsMissingCredentialFallback: Bool = false,
        mapsAuthenticationInvalidation: Bool = false,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> AuthorizedResponse<Payload> {
        let authorizedResponse = try await response(
            url: url,
            referer: referer,
            requiresAuthentication: requiresAuthentication,
            permitsMissingCredentialFallback: permitsMissingCredentialFallback,
            maximumResponseSize: maximumResponseSize
        )
        let response = authorizedResponse.response

        let status: APIStatusEnvelope
        do {
            status = try decoder.decode(APIStatusEnvelope.self, from: response.body)
        } catch {
            throw BiliAPIError.decodingFailed
        }
        if mapsAuthenticationInvalidation, status.code == -101 {
            throw BiliAPIError.authenticationInvalid
        }
        guard status.code == 0 else {
            throw BiliAPIError.apiRejected(
                code: status.code,
                message: status.message ?? ""
            )
        }
        let envelope: APIEnvelope<Payload>
        do {
            envelope = try decoder.decode(APIEnvelope<Payload>.self, from: response.body)
        } catch {
            throw BiliAPIError.decodingFailed
        }
        guard let payload = envelope.data else {
            throw BiliAPIError.missingData
        }
        return AuthorizedResponse(
            payload: payload,
            authorizationProvenance:
                authorizedResponse.authorizationProvenance
        )
    }

    private func response(
        url: URL,
        referer: String,
        requiresAuthentication: Bool = false,
        permitsMissingCredentialFallback: Bool = false,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> AuthorizedHTTPResponse {
        let baseRequest = HTTPRequest(
            url: url,
            headers: [
                "Accept": "application/json",
                "Referer": referer,
                "User-Agent": userAgent,
            ]
        )
        let requestClient = httpClient
        let requestSessionEpoch =
            requiresAuthentication ? authenticatedSessionEpoch : nil
        let request: HTTPRequest
        let authorizationProvenance: AuthorizationProvenance
        if requiresAuthentication {
            guard let requestAuthorizer else {
                throw BiliAPIError.authorizationRequired
            }
            do {
                request = try await requestAuthorizer.authorize(baseRequest)
                authorizationProvenance = .authenticated
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as any HTTPRequestAuthorizationFailure {
                guard requestSessionEpoch == authenticatedSessionEpoch else {
                    throw CancellationError()
                }
                switch error.authorizationFailureKind {
                case .missingCredential where permitsMissingCredentialFallback:
                    try Task.checkCancellation()
                    request = baseRequest
                    authorizationProvenance = .anonymous
                case .invalidCredential:
                    throw BiliAPIError.authenticationInvalid
                case .missingCredential:
                    throw BiliAPIError.authorizationRequired
                case .unavailable, .denied:
                    throw BiliAPIError.authorizationUnavailable
                }
            } catch {
                guard requestSessionEpoch == authenticatedSessionEpoch else {
                    throw CancellationError()
                }
                throw BiliAPIError.authorizationUnavailable
            }
        } else {
            request = baseRequest
            authorizationProvenance = .anonymous
        }
        if let requestSessionEpoch,
            requestSessionEpoch != authenticatedSessionEpoch
        {
            throw CancellationError()
        }

        let response: HTTPResponse
        do {
            response = try await requestClient.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPClientError {
            if let requestSessionEpoch,
                requestSessionEpoch != authenticatedSessionEpoch
            {
                throw CancellationError()
            }
            switch error {
            case .unacceptableStatusCode(let status):
                throw BiliAPIError.httpStatus(status)
            case .nonHTTPResponse:
                throw BiliAPIError.transportFailure
            }
        } catch {
            if let requestSessionEpoch,
                requestSessionEpoch != authenticatedSessionEpoch
            {
                throw CancellationError()
            }
            throw BiliAPIError.transportFailure
        }
        if let requestSessionEpoch,
            requestSessionEpoch != authenticatedSessionEpoch
        {
            throw CancellationError()
        }

        guard response.body.count <= maximumResponseSize else {
            throw BiliAPIError.responseTooLarge(response.body.count)
        }
        guard Self.looksLikeJSON(response) else {
            throw BiliAPIError.nonJSONResponse
        }
        return AuthorizedHTTPResponse(
            response: response,
            authorizationProvenance: authorizationProvenance
        )
    }

    private func signedSearch(
        parameters: [String: String],
        forceKeyRefresh: Bool
    ) async throws -> SearchPage {
        let keys = try await wbiKey(forceRefresh: forceKeyRefresh)
        let query = try wbiSigner.sign(
            parameters: parameters,
            keys: keys,
            timestamp: timestampProvider()
        )
        let payload: SearchPayload = try await get(
            path: "/x/web-interface/wbi/search/type",
            percentEncodedQuery: query,
            referer: "https://www.bilibili.com/"
        )
        return try payload.model()
    }

    private func signedSubtitleResources(
        for identity: PlaybackItemIdentity,
        forceKeyRefresh: Bool
    ) async throws -> [SubtitleRemoteTrack] {
        let keys = try await wbiKey(forceRefresh: forceKeyRefresh)
        let query = try wbiSigner.sign(
            parameters: [
                "bvid": identity.bvid,
                "cid": String(identity.cid),
            ],
            keys: keys,
            timestamp: timestampProvider()
        )
        let payload: SubtitleCatalogPayload = try await get(
            path: "/x/player/wbi/v2",
            percentEncodedQuery: query,
            referer: Self.videoReferer(identity.bvid),
            requiresAuthentication: true,
            maximumResponseSize: Self.maximumSubtitleCatalogSize
        )
        return try payload.resources()
    }

    private func wbiKey(forceRefresh: Bool) async throws -> WBIKeyMaterial {
        let currentDay = timestampProvider() / 86_400
        if forceRefresh {
            cachedWBIKey = nil
        } else if let cachedWBIKey, cachedWBIKey.day == currentDay {
            return cachedWBIKey.key
        }

        let url = try endpoint(path: "/x/web-interface/nav", queryItems: [])
        let response = try await response(
            url: url,
            referer: "https://www.bilibili.com/"
        ).response
        let envelope: APIEnvelope<NavigationPayload>
        do {
            envelope = try decoder.decode(
                APIEnvelope<NavigationPayload>.self,
                from: response.body
            )
        } catch {
            throw BiliAPIError.decodingFailed
        }
        guard let image = envelope.data?.wbiImage else {
            throw BiliAPIError.invalidWBIKey
        }
        let key = try WBIKeyMaterial(
            imageURL: image.imageURL,
            subURL: image.subURL
        )
        cachedWBIKey = CachedWBIKey(key: key, day: currentDay)
        return key
    }

    private func endpoint(
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        guard
            var components = URLComponents(
                url: baseURL,
                resolvingAgainstBaseURL: false
            )
        else {
            throw BiliAPIError.invalidRequest
        }
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else {
            throw BiliAPIError.invalidRequest
        }
        return url
    }

    private func endpoint(
        path: String,
        percentEncodedQuery: String
    ) throws -> URL {
        guard
            var components = URLComponents(
                url: baseURL,
                resolvingAgainstBaseURL: false
            )
        else {
            throw BiliAPIError.invalidRequest
        }
        components.path = path
        components.percentEncodedQuery = percentEncodedQuery
        guard let url = components.url else {
            throw BiliAPIError.invalidRequest
        }
        return url
    }

    private static func isValidBVID(_ bvid: String) -> Bool {
        bvid.hasPrefix("BV")
            && bvid.count <= 24
            && bvid.dropFirst(2).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func videoReferer(_ bvid: String) -> String {
        "https://www.bilibili.com/video/\(bvid)/"
    }

    private static func isExactUploaderCardEndpoint(
        _ url: URL,
        ownerID: Int64
    ) -> Bool {
        guard
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        else { return false }
        return components.scheme == "https"
            && components.host == "api.bilibili.com"
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.path == "/x/web-interface/card"
            && components.queryItems == [
                URLQueryItem(name: "mid", value: String(ownerID)),
                URLQueryItem(name: "photo", value: "false"),
            ]
    }

    private static func looksLikeJSON(_ response: HTTPResponse) -> Bool {
        guard
            let contentType = response.headers.first(where: {
                $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
            })?.value.lowercased(),
            contentType.contains("json")
        else {
            return false
        }
        guard
            let firstByte = response.body.first(where: {
                ![9, 10, 13, 32].contains($0)
            })
        else {
            return false
        }
        return firstByte == 0x7B || firstByte == 0x5B
    }

    private static func looksLikeProtobuf(_ response: HTTPResponse) -> Bool {
        guard
            let contentType = response.headers.first(where: {
                $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
            })?.value.lowercased(),
            contentType.contains("application/octet-stream")
        else {
            return false
        }
        return !isKnownNonProtobufBody(response.body)
    }

    private static func isKnownNonProtobufBody(_ body: Data) -> Bool {
        if (try? JSONSerialization.jsonObject(with: body)) != nil {
            return true
        }
        guard let text = String(data: body, encoding: .utf8) else {
            return false
        }
        let normalized =
            text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.hasPrefix("<html")
            || normalized.hasPrefix("<!doctype")
    }
}

private struct CachedWBIKey: Sendable {
    let key: WBIKeyMaterial
    let day: Int64
}

private struct APIStatusEnvelope: Decodable, Sendable {
    let code: Int
    let message: String?
}

private struct APIEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let data: Payload?
}
