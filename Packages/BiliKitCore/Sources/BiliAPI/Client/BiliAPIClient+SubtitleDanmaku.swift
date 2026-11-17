import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 字幕目录与弹幕 protobuf 分段；字幕正文由 `BiliSubtitleRepository` 另行读取。
extension BiliAPIClient {
    /// 弹幕分段正文上限，与评论页相同，见 SECURITY-MODEL §4；超出不交给 protobuf 解码。
    private static let maximumDanmakuSegmentSize = 2 * 1_024 * 1_024
    /// 互动弹幕响应上限：一个视频通常只有几条互动弹幕、几 KB；超出按响应异常失败关闭，不交给 protobuf 解码。
    private static let maximumDanmakuViewSize = 512 * 1_024
    /// 被 HTTP 412 拒绝的弹幕分段再请求一次之前的等待时长。
    ///
    /// 弹幕分段会被间歇风控（游客更常见），稍后通常恢复。与 -403／v_voucher 的换 key 重试同属
    /// `signedRequest` 的一次重试，不叠加。
    static let danmakuRestrictedRetryDelay: Duration = .seconds(2)

    /// 字幕目录只按账户读取：未注入授权器或本地无凭据时失败为“需要登录”，不匿名降级（见
    /// SECURITY-MODEL §3）。
    func subtitleResources(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleRemoteTrack] {
        guard hasAccountAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        let payload: SubtitleCatalogPayload = try await playerInfo(
            for: identity,
            missingCredential: .fail
        )
        return try payload.resources()
    }

    /// 弹幕分段：有授权器时按账户读取、本地无凭据时匿名请求同一 endpoint。
    ///
    /// 被 HTTP 412 拒绝时等 `danmakuRestrictedRetryDelay` 后以同一授权方式再请求一次，
    /// 不降级为匿名；弹幕会话不再叠加重试（见 SECURITY-MODEL §3）。
    func danmakuSegmentData(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> Data {
        guard BVID.isValid(identity.bvid),
            identity.cid > 0,
            (1...DanmakuSegmentUseCase.maximumSegmentIndex).contains(index)
        else {
            throw BiliAPIError.invalidRequest
        }
        return try await signedRequest(
            path: BiliAccountReadPath.danmakuSegment,
            intermittentRestrictionRetryDelay: Self.danmakuRestrictedRetryDelay,
            parameters: {
                [
                    "type": "1",
                    "oid": String(identity.cid),
                    "segment_index": String(index)
                ]
            },
            send: { url in
                try await danmakuProtobuf(
                    url: url,
                    referer: try Self.videoReferer(identity.bvid),
                    maximumResponseSize: Self.maximumDanmakuSegmentSize
                )
            }
        )
    }

    /// 互动弹幕：有授权器时按账户读取、本地无凭据时匿名请求同一 endpoint；不签 WBI，失败不重试。
    ///
    /// 只带 `type` 与 `oid`（cid），不带稿件 aid：实测匿名请求不需要它。正文校验与分段相同（见 SECURITY-MODEL §4）。
    func danmakuViewData(for identity: PlaybackItemIdentity) async throws -> Data {
        guard BVID.isValid(identity.bvid), identity.cid > 0 else {
            throw BiliAPIError.invalidRequest
        }
        return try await danmakuProtobuf(
            url: try endpoint(
                path: BiliAccountReadPath.danmakuView,
                queryItems: [
                    URLQueryItem(name: "type", value: "1"),
                    URLQueryItem(name: "oid", value: String(identity.cid))
                ]
            ),
            referer: try Self.videoReferer(identity.bvid),
            maximumResponseSize: Self.maximumDanmakuViewSize
        )
    }

    /// 一次弹幕 protobuf 请求（分段与互动弹幕共用）：protobuf 正文不走 JSON envelope 管线，JSON／HTML 错误体在这里识别。
    ///
    /// 正文须非空、`Content-Type` 为 octet-stream 且不像 JSON 或 HTML，才原样交给 protobuf 解码；
    /// JSON 错误体只读状态码（-101 与 JSON 管线同一判定），其余一律 `nonProtobufResponse`，
    /// 不互相降级解析。见 SECURITY-MODEL §4。
    private func danmakuProtobuf(
        url: URL,
        referer: String,
        maximumResponseSize: Int
    ) async throws -> Data {
        let access: RequestAccess =
            hasAccountAuthorizer
            ? .accountRead(missingCredential: .useAnonymousRequest)
            : .anonymous
        let authorizedResponse = try await response(
            baseRequest: HTTPRequest(
                url: url,
                headers: [
                    "Accept": "application/octet-stream",
                    "Referer": referer,
                    "User-Agent": userAgent
                ]
            ),
            access: access,
            maximumResponseSize: maximumResponseSize
        )
        let response = authorizedResponse.response
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
                if let error = authorizedResponse.authorizationProvenance.notLoggedInError(
                    statusCode: status.code
                ) {
                    throw error
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

    private static func looksLikeProtobuf(_ response: HTTPResponse) -> Bool {
        guard
            let contentType = response.headerValue("Content-Type")?.lowercased(),
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
