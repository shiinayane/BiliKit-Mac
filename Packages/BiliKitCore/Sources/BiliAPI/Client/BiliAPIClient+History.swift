import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 观看历史 cursor 读取与唯一写请求（观看进度 heartbeat）。
extension BiliAPIClient {
    public func watchHistory(
        after continuation: WatchHistoryContinuation? = nil,
        pageSize: Int = 20
    ) async throws -> WatchHistoryPage {
        guard (1...30).contains(pageSize) else {
            throw BiliAPIError.invalidRequest
        }
        let cursor: WatchHistoryCursorPayload
        if let continuation {
            cursor = try WatchHistoryCursorPayload(continuation)
        } else {
            cursor = .initial
        }
        let payload: WatchHistoryPayload = try await get(
            url: try endpoint(
                path: "/x/web-interface/history/cursor",
                queryItems: [
                    URLQueryItem(name: "max", value: String(cursor.maximum)),
                    URLQueryItem(name: "view_at", value: String(cursor.viewedAt)),
                    URLQueryItem(name: "business", value: cursor.business),
                    URLQueryItem(name: "ps", value: String(pageSize))
                ]
            ),
            referer: "https://www.bilibili.com/account/history",
            access: .accountRead(
                missingCredential: .fail,
                mapsAuthenticationInvalidation: false
            )
        )
        return try payload.model(pageSize: pageSize)
    }

    /// V1 唯一认证写请求；endpoint、WBI、form 与响应在 API adapter 内收口。
    public func reportWatchProgress(_ report: WatchProgressReport) async throws {
        guard hasHistoryWriteAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        guard report.target.aid > 0,
            report.target.identity.cid > 0,
            Self.isValidBVID(report.target.identity.bvid),
            report.positionSeconds >= 0,
            report.maximumPositionSeconds >= report.positionSeconds
        else {
            throw BiliAPIError.invalidRequest
        }
        let playedTime = report.completed ? -1 : report.positionSeconds
        var signedFacts = [
            "w_start_ts": String(report.sessionStartTimestamp),
            "w_aid": String(report.target.aid),
            "w_dt": "2",
            "w_realtime": String(report.elapsedSeconds),
            "w_played_time": String(playedTime),
            "w_real_played_time": String(report.playedSeconds),
            "w_last_play_progress_time": String(report.positionSeconds),
            "web_location": "1315873"
        ]
        if let duration = report.durationSeconds {
            signedFacts["w_video_duration"] = String(duration)
        }
        // WBI nav 保持匿名；只有最终 heartbeat 才交给独立写授权器。
        let keys = try await wbiKey(forceRefresh: false)
        let query = try wbiSigner.sign(
            parameters: signedFacts,
            keys: keys,
            timestamp: timestampProvider()
        )
        let url = try endpoint(
            path: "/x/click-interface/web/heartbeat",
            percentEncodedQuery: query
        )
        let referer = Self.videoReferer(report.target.identity.bvid)
        var bodyFields: [(String, String)] = [
            ("start_ts", String(report.sessionStartTimestamp)),
            ("aid", String(report.target.aid)),
            ("cid", String(report.target.identity.cid)),
            ("type", "3"),
            ("sub_type", "0"),
            ("dt", "2"),
            ("play_type", String(report.event.rawValue)),
            ("realtime", String(report.elapsedSeconds)),
            ("played_time", String(playedTime)),
            ("real_played_time", String(report.playedSeconds)),
            ("refer_url", referer)
        ]
        if let duration = report.durationSeconds {
            bodyFields.append(("video_duration", String(duration)))
        }
        bodyFields.append(contentsOf: [
            ("last_play_progress_time", String(report.positionSeconds)),
            ("max_play_progress_time", String(report.maximumPositionSeconds)),
            ("outer", "0"),
            ("mobi_app", "web"),
            ("device", "web"),
            ("platform", "web"),
            ("session", report.sessionID)
        ])
        let authorizedResponse = try await response(
            baseRequest: HTTPRequest(
                url: url,
                method: .post,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Referer": referer,
                    "User-Agent": userAgent
                ],
                body: try Self.formBody(bodyFields)
            ),
            access: .historyWrite,
            maximumResponseSize: 16 * 1_024
        )
        guard authorizedResponse.response.looksLikeJSON(allowsTopLevelArray: true) else {
            throw BiliAPIError.nonJSONResponse
        }
        let status: APIStatusEnvelope
        do {
            status = try decoder.decode(
                APIStatusEnvelope.self,
                from: authorizedResponse.response.body
            )
        } catch {
            throw BiliAPIError.decodingFailed
        }
        if status.code == -101 || status.code == -111 {
            throw BiliAPIError.authenticationInvalid
        }
        guard status.code == 0 else {
            throw BiliAPIError.apiRejected(
                code: status.code,
                message: status.message ?? ""
            )
        }
    }

    private static func formBody(_ fields: [(String, String)]) throws -> Data {
        var components = URLComponents()
        components.queryItems = fields.map(URLQueryItem.init(name:value:))
        guard let encoded = components.percentEncodedQuery else {
            throw BiliAPIError.invalidRequest
        }
        return Data(encoded.utf8)
    }
}
