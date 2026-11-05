import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 首页推荐、热门与搜索，以及线路测速用的匿名近期投稿发现。
extension BiliAPIClient {
    /// 近期投稿列表一页最多读取的条数；只供线路测速的样本发现，保持元数据读取有界。
    static let maximumRecentSubmissionPageSize = 5

    public func popular(
        page: Int,
        pageSize: Int
    ) async throws -> PopularPage {
        guard page > 0, (1...FeedUseCase.maximumPopularPageSize).contains(pageSize) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: PopularPayload = try await get(
            url: try endpoint(
                path: BiliAccountReadPath.popular,
                queryItems: [
                    URLQueryItem(name: "pn", value: String(page)),
                    URLQueryItem(name: "ps", value: String(pageSize))
                ]
            ),
            referer: "https://www.bilibili.com/",
            access: .accountRead(missingCredential: .useAnonymousRequest)
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
        guard regionID > 0, (1...Self.maximumRecentSubmissionPageSize).contains(pageSize),
            dateFrom.count == 8, dateFrom.allSatisfy(\.isNumber),
            dateTo.count == 8, dateTo.allSatisfy(\.isNumber),
            dateFrom <= dateTo
        else { throw BiliAPIError.invalidRequest }
        let payload: RecentRankPayload = try await get(
            url: try endpoint(
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
                    URLQueryItem(name: "time_to", value: dateTo)
                ]
            ),
            referer: "https://www.bilibili.com/"
        )
        return Array((payload.result ?? []).prefix(pageSize))
    }

    /// 测速样本详情：与主详情共用签名请求，只按账户读取，样本必须是当前账户可消费的内容。
    func recentSubmissionDetail(
        for bvid: String
    ) async throws -> RecentSubmissionDetailPayload {
        guard BVID.isValid(bvid) else { throw BiliAPIError.invalidRequest }
        return try await signedVideoDetail(
            bvid: bvid,
            access: .accountRead(missingCredential: .fail)
        )
    }

    /// App 端请求的客户端身份（iPad 客户端的最低组合）：推荐与它的「不感兴趣」必须用同一身份，服务端才认得是哪条推荐流；
    /// App 授权器的 schema 也按这组值精确放行，改这里要同时改 BiliAuth 那边，见 SECURITY-MODEL §3。
    static let appClientIdentity = [
        URLQueryItem(name: "mobi_app", value: "iphone"),
        URLQueryItem(name: "device", value: "pad"),
        URLQueryItem(name: "build", value: "1")
    ]

    /// App 端首页推荐的一批：经 App 授权器签名，登录时带 access_token、未登录时匿名。
    ///
    /// 第一批的 `idx` 取当前秒数，之后取上一批最后一张卡片的 `idx`；服务端不去重，重复条目由 `PagedVideoList` 按 BVID
    /// 去掉。请求参数照 iPad 客户端的最低组合，不带设备请求头，见 SECURITY-MODEL §3。
    public func recommendations(
        after continuation: RecommendationContinuation? = nil
    ) async throws -> RecommendationPage {
        let requestIndex = continuation?.index ?? timestampProvider()
        guard requestIndex > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let payload: AppFeedPayload = try await get(
            url: try appEndpoint(
                path: BiliAppReadPath.recommendations,
                queryItems: Self.appClientIdentity + [
                    URLQueryItem(name: "idx", value: String(requestIndex))
                ]
            ),
            referer: nil,
            access: .appRead
        )
        let receivedAt = Date(timeIntervalSince1970: TimeInterval(timestampProvider()))
        let videos = payload.items.compactMap { $0.model(receivedAt: receivedAt) }
        let next = payload.items.last?.index.flatMap { index in
            !videos.isEmpty && index > requestIndex ? RecommendationContinuation(index: index) : nil
        }
        return RecommendationPage(
            videos: videos,
            continuation: continuation,
            nextContinuation: next
        )
    }

    public func searchVideos(
        request: VideoSearchRequest
    ) async throws -> SearchPage {
        let criteria = request.criteria
        guard criteria.isValid, request.page > 0 else {
            throw BiliAPIError.invalidRequest
        }
        var parameters = [
            "keyword": criteria.query,
            "page": String(request.page),
            "page_size": String(criteria.pageSize),
            "search_type": "video",
            "order": criteria.order.apiValue,
            "duration": criteria.duration.apiValue
        ]
        if let range = criteria.publicationRange {
            parameters["pubtime_begin_s"] = String(range.beginTimestamp)
            parameters["pubtime_end_s"] = String(range.endTimestamp)
        }
        let payload: SearchPayload = try await signedRequest(
            path: BiliAccountReadPath.videoSearch,
            parameters: { parameters },
            send: { url in
                // 该接口要求 Cookie 含 buvid3；匿名与账户读取两条路径都在授权后附加。
                try await getWithAuthorizationProvenance(
                    url: url,
                    referer: "https://www.bilibili.com/",
                    access: .accountRead(missingCredential: .useAnonymousRequest),
                    additionalCookie: Self.buvid3Cookie
                ).payload
            }
        )
        return try payload.model()
    }
}
