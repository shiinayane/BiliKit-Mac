import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// Bilibili endpoint/DTO adapter；把远端协议限制在 `BiliAPI`，并返回稳定模型。
///
/// 请求默认匿名，只有私有 `RequestAccess.accountRead` 才经过 authorizer。允许游客增强的读取
/// 也只有在本地明确无凭据时保持匿名，并继续使用同一个 endpoint。
/// 响应在解码前还要满足状态、大小与 Content-Type 边界。actor 隔离可变
/// transport/WBI cache；跨 `await` 可重入，用户意图的取消与写回代次仍由上层 owner 管理。
public actor BiliAPIClient: AuthenticatedSessionInvalidating {
    private enum MissingCredentialBehavior: Sendable, Equatable {
        case fail
        case useAnonymousRequest
    }

    private enum RequestAccess: Sendable {
        case anonymous
        case accountRead(
            missingCredential: MissingCredentialBehavior,
            mapsAuthenticationInvalidation: Bool
        )

        var requiresAuthentication: Bool {
            if case .accountRead = self { return true }
            return false
        }

        var permitsMissingCredentialFallback: Bool {
            guard case .accountRead(let behavior, _) = self else { return false }
            return behavior == .useAnonymousRequest
        }

        var mapsAuthenticationInvalidation: Bool {
            guard case .accountRead(_, let mapsInvalidation) = self else {
                return false
            }
            return mapsInvalidation
        }
    }

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
    private static let maximumCommentPageSize = 2 * 1_024 * 1_024

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
            referer: "https://www.bilibili.com/",
            access: .accountRead(
                missingCredential: .useAnonymousRequest,
                mapsAuthenticationInvalidation: true
            )
        )
        let videos = try payload.list.map { try $0.model() }
        return PopularPage(
            videos: videos,
            pageNumber: page,
            pageSize: pageSize,
            hasMore: !payload.noMore
        )
    }

    /// 显式线路测速专用的匿名近期投稿读取；只读取固定日期窗口中的有界元数据。
    func recentSubmissions(
        regionID: Int,
        pageSize: Int,
        dateFrom: String,
        dateTo: String
    ) async throws -> [RecentRankSubmissionPayload] {
        guard regionID > 0, (1...5).contains(pageSize),
            dateFrom.count == 8, dateFrom.allSatisfy(\.isNumber),
            dateTo.count == 8, dateTo.allSatisfy(\.isNumber),
            dateFrom <= dateTo
        else { throw BiliAPIError.invalidRequest }
        let payload: RecentRankPayload = try await get(
            path: "/x/web-interface/newlist_rank",
            queryItems: [
                URLQueryItem(name: "main_ver", value: "v3"),
                URLQueryItem(name: "search_type", value: "video"),
                URLQueryItem(name: "view_type", value: "hot_rank"),
                URLQueryItem(name: "copy_right", value: "-1"),
                URLQueryItem(name: "new_web_tag", value: "1"),
                URLQueryItem(name: "order", value: "pubdate"),
                URLQueryItem(name: "cate_id", value: String(regionID)),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "pagesize", value: String(pageSize)),
                URLQueryItem(name: "time_from", value: dateFrom),
                URLQueryItem(name: "time_to", value: dateTo),
            ],
            referer: "https://www.bilibili.com/"
        )
        return Array((payload.result ?? []).prefix(pageSize))
    }

    func recentSubmissionDetail(
        for bvid: String
    ) async throws -> RecentSubmissionDetailPayload {
        guard Self.isValidBVID(bvid) else { throw BiliAPIError.invalidRequest }
        return try await get(
            path: "/x/web-interface/view",
            queryItems: [URLQueryItem(name: "bvid", value: bvid)],
            referer: Self.videoReferer(bvid)
        )
    }

    public func recommendations(
        after continuation: RecommendationContinuation? = nil
    ) async throws -> RecommendationPage {
        let freshIndex = continuation?.freshIndex ?? 1
        guard freshIndex > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let sessionEpoch = authenticatedSessionEpoch
        do {
            return try await signedRecommendations(
                freshIndex: freshIndex,
                sessionEpoch: sessionEpoch,
                forceKeyRefresh: false
            )
        } catch BiliAPIError.apiRejected(let code, _) where code == -403 {
            return try await signedRecommendations(
                freshIndex: freshIndex,
                sessionEpoch: sessionEpoch,
                forceKeyRefresh: true
            )
        } catch BiliAPIError.httpStatus(403) {
            return try await signedRecommendations(
                freshIndex: freshIndex,
                sessionEpoch: sessionEpoch,
                forceKeyRefresh: true
            )
        }
    }

    public func searchVideos(
        keyword: String,
        page: Int = 1
    ) async throws -> SearchPage {
        let searchSessionEpoch = authenticatedSessionEpoch
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
            return try await signedSearch(
                parameters: parameters,
                sessionEpoch: searchSessionEpoch,
                forceKeyRefresh: false
            )
        } catch BiliAPIError.apiRejected(let code, _) where code == -403 {
            return try await signedSearch(
                parameters: parameters,
                sessionEpoch: searchSessionEpoch,
                forceKeyRefresh: true
            )
        } catch BiliAPIError.httpStatus(403) {
            return try await signedSearch(
                parameters: parameters,
                sessionEpoch: searchSessionEpoch,
                forceKeyRefresh: true
            )
        }
    }

    public func videoDetail(for bvid: String) async throws -> VideoDetail {
        guard Self.isValidBVID(bvid) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: VideoDetailPayload = try await get(
            path: "/x/web-interface/view",
            queryItems: [URLQueryItem(name: "bvid", value: bvid)],
            referer: Self.videoReferer(bvid),
            access: .accountRead(
                missingCredential: .useAnonymousRequest,
                mapsAuthenticationInvalidation: true
            )
        )
        let detail = try payload.model()
        guard detail.bvid == bvid else {
            throw BiliAPIError.decodingFailed
        }
        return detail
    }

    func commentRootPage(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        offset: String?
    ) async throws -> CommentRemoteRootPage {
        guard subject.type == 1, subject.oid > 0 else {
            throw BiliAPIError.invalidRequest
        }
        do {
            return try await signedCommentRootPage(
                for: subject,
                sort: sort,
                offset: offset,
                forceKeyRefresh: false
            )
        } catch BiliAPIError.apiRejected(let code, _) where code == -403 {
            return try await signedCommentRootPage(
                for: subject,
                sort: sort,
                offset: offset,
                forceKeyRefresh: true
            )
        }
    }

    func commentReplyPage(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) async throws -> CommentRemoteReplyPage {
        guard subject.type == 1, subject.oid > 0,
            rootID.rawValue > 0, page > 0, pageSize == 10
        else { throw BiliAPIError.invalidRequest }
        let payload: CommentReplyListPayload = try await get(
            path: "/x/v2/reply/reply",
            queryItems: [
                URLQueryItem(name: "type", value: String(subject.type)),
                URLQueryItem(name: "oid", value: String(subject.oid)),
                URLQueryItem(name: "root", value: String(rootID.rawValue)),
                URLQueryItem(name: "pn", value: String(page)),
                URLQueryItem(name: "ps", value: String(pageSize)),
            ],
            referer: "https://www.bilibili.com/",
            access: .accountRead(
                missingCredential: .useAnonymousRequest,
                mapsAuthenticationInvalidation: true
            ),
            maximumResponseSize: Self.maximumCommentPageSize
        )
        return try payload.page(subject: subject, rootID: rootID)
    }

    /// 登录增强地读取相关推荐；只有本地明确无凭据时匿名。
    public func relatedVideos(to bvid: String) async throws -> [RelatedVideo] {
        guard Self.isValidBVID(bvid) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: [RelatedVideoPayload] = try await get(
            path: "/x/web-interface/archive/related",
            queryItems: [URLQueryItem(name: "bvid", value: bvid)],
            referer: Self.videoReferer(bvid),
            access: .accountRead(
                missingCredential: .useAnonymousRequest,
                mapsAuthenticationInvalidation: true
            )
        )
        return try payload.map { try $0.model() }
    }

    /// 登录增强地读取公开 UP 主签名；不会请求 WBI 签名。
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
            referer: "https://space.bilibili.com/",
            access: .accountRead(
                missingCredential: .useAnonymousRequest,
                mapsAuthenticationInvalidation: true
            )
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
            referer: Self.videoReferer(bvid),
            access: .accountRead(
                missingCredential: .useAnonymousRequest,
                mapsAuthenticationInvalidation: true
            )
        )
        return try validatedPageModels(payload)
    }

    /// 取得 AVC/AAC DASH 清单；仅 playurl 可按本地凭据状态选择精确授权或匿名请求。
    public func playback(
        for bvid: String,
        cid: Int64,
        quality: Int = 120
    ) async throws -> VideoPlayback {
        try await playback(
            for: bvid,
            cid: cid,
            quality: quality,
            missingCredential: .useAnonymousRequest,
            includesMachineGeneratedAudio: true
        )
    }

    /// 测速样本必须来自当前账户可消费的 playurl；没有凭据时失败而不匿名降级。
    func authenticatedPlaybackForCDNBenchmark(
        for bvid: String,
        cid: Int64,
        quality: Int = 120
    ) async throws -> CDNBenchmarkPlayback {
        guard Self.isValidBVID(bvid), cid > 0, quality > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let playbackSessionEpoch = authenticatedSessionEpoch
        let referer = Self.videoReferer(bvid)
        let resolved: AuthorizedResponse<CDNBenchmarkPlayURLPayload> =
            try await getWithAuthorizationProvenance(
                path: "/x/player/playurl",
                queryItems: [
                    URLQueryItem(name: "bvid", value: bvid),
                    URLQueryItem(name: "cid", value: String(cid)),
                    URLQueryItem(name: "qn", value: String(quality)),
                    URLQueryItem(name: "fnval", value: "976"),
                    URLQueryItem(name: "fnver", value: "0"),
                    URLQueryItem(name: "fourk", value: "1"),
                ],
                referer: referer,
                access: .accountRead(
                    missingCredential: .fail,
                    mapsAuthenticationInvalidation: true
                )
            )
        try requireAuthenticatedSessionEpoch(playbackSessionEpoch)
        let video = try resolved.payload.dash.video
            .filter(\.isAVCVideo)
            .map { try $0.model(kind: .video) }
        guard !video.isEmpty else { throw BiliAPIError.noAVCVideo }
        try requireAuthenticatedSessionEpoch(playbackSessionEpoch)
        return CDNBenchmarkPlayback(
            videoRepresentations: video,
            mediaHeaders: [
                "Referer": referer,
                "User-Agent": userAgent,
            ]
        )
    }

    private func playback(
        for bvid: String,
        cid: Int64,
        quality: Int,
        missingCredential: MissingCredentialBehavior,
        includesMachineGeneratedAudio: Bool
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
        let resolved: AuthorizedResponse<PlayURLPayload> =
            try await getWithAuthorizationProvenance(
                path: "/x/player/playurl",
                queryItems: queryItems,
                referer: referer,
                access: .accountRead(
                    missingCredential: missingCredential,
                    mapsAuthenticationInvalidation: true
                )
            )
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
            if includesMachineGeneratedAudio {
                audioTracks += try await machineGeneratedAudioTracks(
                    catalog: payload.languageCatalog,
                    originalAudio: audio,
                    bvid: bvid,
                    cid: cid,
                    quality: quality,
                    referer: referer,
                    sessionEpoch: playbackSessionEpoch
                )
            }
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
            ],
            resumeMetadata:
                resolved.authorizationProvenance == .authenticated
                ? payload.resumeMetadata : nil
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
                access: .accountRead(
                    missingCredential: .fail,
                    mapsAuthenticationInvalidation: true
                )
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
        do {
            return try await signedDanmakuSegmentData(
                index: index,
                for: identity,
                forceKeyRefresh: false
            )
        } catch BiliAPIError.apiRejected(let code, _) where code == -403 {
            return try await signedDanmakuSegmentData(
                index: index,
                for: identity,
                forceKeyRefresh: true
            )
        } catch BiliAPIError.httpStatus(403) {
            return try await signedDanmakuSegmentData(
                index: index,
                for: identity,
                forceKeyRefresh: true
            )
        }
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
            access: .accountRead(
                missingCredential: .fail,
                mapsAuthenticationInvalidation: false
            )
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
        access: RequestAccess = .anonymous,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> Payload {
        try await getWithAuthorizationProvenance(
            path: path,
            queryItems: queryItems,
            referer: referer,
            access: access,
            maximumResponseSize: maximumResponseSize
        ).payload
    }

    private func getWithAuthorizationProvenance<
        Payload: Decodable & Sendable
    >(
        path: String,
        queryItems: [URLQueryItem],
        referer: String,
        access: RequestAccess = .anonymous,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> AuthorizedResponse<Payload> {
        let url = try endpoint(path: path, queryItems: queryItems)
        return try await getWithAuthorizationProvenance(
            url: url,
            referer: referer,
            access: access,
            maximumResponseSize: maximumResponseSize
        )
    }

    private func get<Payload: Decodable & Sendable>(
        path: String,
        percentEncodedQuery: String,
        referer: String,
        access: RequestAccess = .anonymous,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> Payload {
        let url = try endpoint(
            path: path,
            percentEncodedQuery: percentEncodedQuery
        )
        return try await get(
            url: url,
            referer: referer,
            access: access,
            maximumResponseSize: maximumResponseSize
        )
    }

    private func get<Payload: Decodable & Sendable>(
        url: URL,
        referer: String,
        access: RequestAccess = .anonymous,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> Payload {
        try await getWithAuthorizationProvenance(
            url: url,
            referer: referer,
            access: access,
            maximumResponseSize: maximumResponseSize
        ).payload
    }

    private func getWithAuthorizationProvenance<
        Payload: Decodable & Sendable
    >(
        url: URL,
        referer: String,
        access: RequestAccess = .anonymous,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> AuthorizedResponse<Payload> {
        let authorizedResponse = try await response(
            url: url,
            referer: referer,
            access: access,
            maximumResponseSize: maximumResponseSize
        )
        let response = authorizedResponse.response

        let status: APIStatusEnvelope
        do {
            status = try decoder.decode(APIStatusEnvelope.self, from: response.body)
        } catch {
            throw BiliAPIError.decodingFailed
        }
        if access.mapsAuthenticationInvalidation, status.code == -101 {
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
        access: RequestAccess = .anonymous,
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
        let response = try await response(
            baseRequest: baseRequest,
            access: access,
            maximumResponseSize: maximumResponseSize
        )
        guard Self.looksLikeJSON(response.response) else {
            throw BiliAPIError.nonJSONResponse
        }
        return response
    }

    private func response(
        baseRequest: HTTPRequest,
        access: RequestAccess,
        maximumResponseSize: Int
    ) async throws -> AuthorizedHTTPResponse {
        let requestClient = httpClient
        let requestSessionEpoch =
            access.requiresAuthentication ? authenticatedSessionEpoch : nil
        let request: HTTPRequest
        let authorizationProvenance: AuthorizationProvenance
        if access.requiresAuthentication, let requestAuthorizer {
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
                case .missingCredential where access.permitsMissingCredentialFallback:
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
        } else if access.permitsMissingCredentialFallback {
            request = baseRequest
            authorizationProvenance = .anonymous
        } else if access.requiresAuthentication {
            throw BiliAPIError.authorizationRequired
        } else {
            request = baseRequest
            authorizationProvenance = .anonymous
        }
        try Task.checkCancellation()
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
        return AuthorizedHTTPResponse(
            response: response,
            authorizationProvenance: authorizationProvenance
        )
    }

    private func signedSearch(
        parameters: [String: String],
        sessionEpoch: UInt64,
        forceKeyRefresh: Bool
    ) async throws -> SearchPage {
        let keys = try await wbiKey(forceRefresh: forceKeyRefresh)
        try requireAuthenticatedSessionEpoch(sessionEpoch)
        let query = try wbiSigner.sign(
            parameters: parameters,
            keys: keys,
            timestamp: timestampProvider()
        )
        let payload: SearchPayload = try await get(
            path: "/x/web-interface/wbi/search/type",
            percentEncodedQuery: query,
            referer: "https://www.bilibili.com/",
            access: .accountRead(
                missingCredential: .useAnonymousRequest,
                mapsAuthenticationInvalidation: true
            )
        )
        try requireAuthenticatedSessionEpoch(sessionEpoch)
        return try payload.model()
    }

    private func signedRecommendations(
        freshIndex: Int,
        sessionEpoch: UInt64,
        forceKeyRefresh: Bool
    ) async throws -> RecommendationPage {
        let keys = try await wbiKey(forceRefresh: forceKeyRefresh)
        try requireAuthenticatedSessionEpoch(sessionEpoch)
        let query = try wbiSigner.sign(
            parameters: [
                "fresh_idx": String(freshIndex),
                "fresh_idx_1h": String(freshIndex),
            ],
            keys: keys,
            timestamp: timestampProvider()
        )
        let payload: RecommendationPayload = try await get(
            path: "/x/web-interface/wbi/index/top/feed/rcmd",
            percentEncodedQuery: query,
            referer: "https://www.bilibili.com/",
            access: .accountRead(
                missingCredential: .useAnonymousRequest,
                mapsAuthenticationInvalidation: true
            )
        )
        try requireAuthenticatedSessionEpoch(sessionEpoch)
        let videos = payload.item.compactMap { $0.model() }
        let current = RecommendationContinuation(freshIndex: freshIndex)
        let next =
            freshIndex < Int.max && !videos.isEmpty
            ? RecommendationContinuation(freshIndex: freshIndex + 1)
            : nil
        return RecommendationPage(
            videos: videos,
            continuation: current,
            nextContinuation: next
        )
    }

    private func signedCommentRootPage(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        offset: String?,
        forceKeyRefresh: Bool
    ) async throws -> CommentRemoteRootPage {
        let paginationData = try JSONSerialization.data(
            withJSONObject: ["offset": offset ?? ""],
            options: [.sortedKeys]
        )
        guard let pagination = String(data: paginationData, encoding: .utf8) else {
            throw BiliAPIError.invalidRequest
        }
        let keys = try await wbiKey(forceRefresh: forceKeyRefresh)
        let query = try wbiSigner.sign(
            parameters: [
                "type": String(subject.type),
                "oid": String(subject.oid),
                "mode": sort == .hot ? "3" : "2",
                "pagination_str": pagination,
            ],
            keys: keys,
            timestamp: timestampProvider()
        )
        let payload: CommentMainPayload = try await get(
            path: "/x/v2/reply/wbi/main",
            percentEncodedQuery: query,
            referer: "https://www.bilibili.com/",
            access: .accountRead(
                missingCredential: .useAnonymousRequest,
                mapsAuthenticationInvalidation: true
            ),
            maximumResponseSize: Self.maximumCommentPageSize
        )
        return try payload.page(for: subject)
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
            access: .accountRead(
                missingCredential: .fail,
                mapsAuthenticationInvalidation: false
            ),
            maximumResponseSize: Self.maximumSubtitleCatalogSize
        )
        return try payload.resources()
    }

    private func signedDanmakuSegmentData(
        index: Int,
        for identity: PlaybackItemIdentity,
        forceKeyRefresh: Bool
    ) async throws -> Data {
        let keys = try await wbiKey(forceRefresh: forceKeyRefresh)
        let query = try wbiSigner.sign(
            parameters: [
                "type": "1",
                "oid": String(identity.cid),
                "segment_index": String(index),
            ],
            keys: keys,
            timestamp: timestampProvider()
        )
        let url = try endpoint(
            path: "/x/v2/dm/wbi/web/seg.so",
            percentEncodedQuery: query
        )
        let access: RequestAccess =
            requestAuthorizer == nil
            ? .anonymous
            : .accountRead(
                missingCredential: .useAnonymousRequest,
                mapsAuthenticationInvalidation: false
            )
        let response = try await response(
            baseRequest: HTTPRequest(
                url: url,
                headers: [
                    "Accept": "application/octet-stream",
                    "Referer": Self.videoReferer(identity.bvid),
                    "User-Agent": userAgent,
                ]
            ),
            access: access,
            maximumResponseSize: Self.maximumDanmakuSegmentSize
        ).response
        guard !response.body.isEmpty else {
            throw BiliAPIError.invalidDanmakuData
        }
        guard Self.looksLikeProtobuf(response) else {
            if Self.isKnownNonProtobufBody(response.body),
                let status = try? decoder.decode(
                    APIStatusEnvelope.self,
                    from: response.body
                )
            {
                if status.code == -101 {
                    throw BiliAPIError.authenticationInvalid
                }
                if status.code != 0 {
                    throw BiliAPIError.apiRejected(
                        code: status.code,
                        message: status.message ?? ""
                    )
                }
            }
            throw BiliAPIError.nonProtobufResponse
        }
        return response.body
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

    static func isValidBVID(_ bvid: String) -> Bool {
        bvid.hasPrefix("BV")
            && bvid.count > 2
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
