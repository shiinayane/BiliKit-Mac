import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

public protocol BiliAPIService: Sendable {
    func popular(page: Int, pageSize: Int) async throws -> PopularPage
    func searchVideos(keyword: String, page: Int) async throws -> SearchPage
    func videoDetail(for bvid: String) async throws -> VideoDetail
    func pages(for bvid: String) async throws -> [VideoPage]
    func playback(for bvid: String, cid: Int64, quality: Int) async throws -> VideoPlayback
}

public protocol BiliWatchHistoryService: Sendable {
    func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage
}

public actor BiliAPIClient: BiliAPIService, BiliWatchHistoryService,
    AuthenticatedSessionInvalidating
{
    public static let productionBaseURL = URL(
        string: "https://api.bilibili.com"
    )!

    private static let maximumResponseSize = 5 * 1_024 * 1_024

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

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        requestAuthorizer: (any HTTPRequestAuthorizing)? = nil,
        transportFactory: (@Sendable () -> any HTTPTransport)? = nil,
        baseURL: URL = BiliAPIClient.productionBaseURL,
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 BiliKitMac/0.1",
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
        } catch let BiliAPIError.apiRejected(code, _) where code == -403 {
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

    public func playback(
        for bvid: String,
        cid: Int64,
        quality: Int = 32
    ) async throws -> VideoPlayback {
        guard Self.isValidBVID(bvid), cid > 0, quality > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let referer = Self.videoReferer(bvid)
        let payload: PlayURLPayload = try await get(
            path: "/x/player/playurl",
            queryItems: [
                URLQueryItem(name: "bvid", value: bvid),
                URLQueryItem(name: "cid", value: String(cid)),
                URLQueryItem(name: "qn", value: String(quality)),
                URLQueryItem(name: "fnval", value: "16"),
                URLQueryItem(name: "fnver", value: "0"),
                URLQueryItem(name: "fourk", value: "0"),
            ],
            referer: referer
        )

        let video = try payload.dash.video
            .filter(\.isAVCVideo)
            .map { try $0.model(kind: .video) }
        let audio = try payload.dash.audio
            .filter(\.isAACAudio)
            .map { try $0.model(kind: .audio) }
        guard !video.isEmpty else { throw BiliAPIError.noAVCVideo }
        guard !audio.isEmpty else { throw BiliAPIError.noAACAudio }

        return VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: video,
                audioRepresentations: audio
            ),
            mediaHeaders: [
                "Referer": referer,
                "User-Agent": userAgent,
            ]
        )
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

    public func invalidateAuthenticatedSession() {
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
        requiresAuthentication: Bool = false
    ) async throws -> Payload {
        let url = try endpoint(path: path, queryItems: queryItems)
        return try await get(
            url: url,
            referer: referer,
            requiresAuthentication: requiresAuthentication
        )
    }

    private func get<Payload: Decodable & Sendable>(
        path: String,
        percentEncodedQuery: String,
        referer: String
    ) async throws -> Payload {
        let url = try endpoint(
            path: path,
            percentEncodedQuery: percentEncodedQuery
        )
        return try await get(url: url, referer: referer)
    }

    private func get<Payload: Decodable & Sendable>(
        url: URL,
        referer: String,
        requiresAuthentication: Bool = false
    ) async throws -> Payload {
        let response = try await response(
            url: url,
            referer: referer,
            requiresAuthentication: requiresAuthentication
        )

        let status: APIStatusEnvelope
        do {
            status = try decoder.decode(APIStatusEnvelope.self, from: response.body)
        } catch {
            throw BiliAPIError.decodingFailed
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
        return payload
    }

    private func response(
        url: URL,
        referer: String,
        requiresAuthentication: Bool = false
    ) async throws -> HTTPResponse {
        let baseRequest = HTTPRequest(
            url: url,
            headers: [
                "Accept": "application/json",
                "Referer": referer,
                "User-Agent": userAgent,
            ]
        )
        let request: HTTPRequest
        if requiresAuthentication {
            guard let requestAuthorizer else {
                throw BiliAPIError.authorizationRequired
            }
            do {
                request = try await requestAuthorizer.authorize(baseRequest)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw BiliAPIError.authorizationRequired
            }
        } else {
            request = baseRequest
        }

        let response: HTTPResponse
        do {
            response = try await httpClient.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPClientError {
            switch error {
            case let .unacceptableStatusCode(status):
                throw BiliAPIError.httpStatus(status)
            case .nonHTTPResponse:
                throw BiliAPIError.transportFailure
            }
        } catch {
            throw BiliAPIError.transportFailure
        }

        guard response.body.count <= Self.maximumResponseSize else {
            throw BiliAPIError.responseTooLarge(response.body.count)
        }
        guard Self.looksLikeJSON(response) else {
            throw BiliAPIError.nonJSONResponse
        }
        return response
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
        )
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
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
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
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
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

    private static func looksLikeJSON(_ response: HTTPResponse) -> Bool {
        if let contentType = response.headers.first(where: {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value.lowercased(),
           !contentType.contains("json") {
            return false
        }
        guard let firstByte = response.body.first(where: {
            ![9, 10, 13, 32].contains($0)
        }) else {
            return false
        }
        return firstByte == 0x7B || firstByte == 0x5B
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
