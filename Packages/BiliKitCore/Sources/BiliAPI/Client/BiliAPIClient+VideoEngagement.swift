import BiliApplication
import BiliModels
import Foundation

/// 播放页的点赞、投币、三连与关注 UP 主：读当前账户对视频的互动（含是否关注 UP 主），以及四种用户发起的写入。
///
/// 读取只按账户读取（网页），本地无凭据时直接失败。点赞、投币、三连走 App 端（`postAppForm`、App 写授权器绑定窗口账户）：
/// 网页的这三个接口会对部分账号或稿件以 -401／-403 拒绝，同一时刻 App 端实测成功；表单只带实测成功的最少字段。关注仍走
/// 网页（`postForm`、账户写授权器）。见 SECURITY-MODEL §3。
extension BiliAPIClient {
    /// 关注的来源代码：11（空间），网页空间页与多个第三方客户端都用它。
    private static let followSourceCode = "11"

    /// 关注的 Referer：播放页的按钮，用固定的站点首页，不随 UP 主变化（授权器每个 path 只认一个固定 Referer）。
    private static let followWriteReferer = "https://www.bilibili.com/"

    /// 读取当前账户对 `bvid` 的点赞、投币与收藏状态；`aid` 与 `bvid` 都带上，与网页一致。
    public func videoEngagement(bvid: String) async throws -> VideoEngagementState {
        guard BVID.isValid(bvid), let aid = BiliVideoAID.aid(fromBVID: bvid) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: VideoRelationPayload = try await get(
            url: try endpoint(
                path: BiliAccountReadPath.videoRelation,
                queryItems: [
                    URLQueryItem(name: "aid", value: String(aid)),
                    URLQueryItem(name: "bvid", value: bvid)
                ]
            ),
            referer: "https://www.bilibili.com/video/\(bvid)",
            access: .accountRead(missingCredential: .fail)
        )
        return try payload.model()
    }

    /// 点赞（`isLiked`）或取消点赞。
    ///
    /// App 端 `like=0` 是点赞、`1` 是取消（与网页相反）；已是目标状态时同样返回成功。
    public func setVideoLiked(_ isLiked: Bool, bvid: String, accountID: Int64) async throws {
        let aid = try engagementWriteAID(bvid: bvid, accountID: accountID)
        try await postEngagement(
            path: BiliAppWritePath.videoLike,
            fields: [("aid", String(aid)), ("like", isLiked ? "0" : "1")],
            accountID: accountID
        )
    }

    /// 投 1 或 2 枚币，可以同时点赞；返回附带的点赞是否成立。
    public func addVideoCoins(
        _ count: Int,
        alsoLike: Bool,
        bvid: String,
        accountID: Int64
    ) async throws -> Bool {
        let aid = try engagementWriteAID(bvid: bvid, accountID: accountID)
        guard count == 1 || count == 2 else { throw BiliAPIError.invalidRequest }
        let body = try await postEngagement(
            path: BiliAppWritePath.videoCoin,
            fields: [
                ("aid", String(aid)),
                ("multiply", String(count)),
                ("select_like", alsoLike ? "1" : "0")
            ],
            accountID: accountID
        )
        let payload = try decodeEngagementData(VideoCoinPayload.self, from: body)
        return payload?.like ?? false
    }

    /// 三连；服务端报告风控（`is_risk` 或 `gaia_res_type` 非 0）时按风控失败，不当作成功。
    public func tripleVideo(bvid: String, accountID: Int64) async throws -> VideoTripleOutcome {
        let aid = try engagementWriteAID(bvid: bvid, accountID: accountID)
        let body = try await postEngagement(
            path: BiliAppWritePath.videoTriple,
            fields: [("aid", String(aid))],
            accountID: accountID
        )
        guard let payload = try decodeEngagementData(VideoTriplePayload.self, from: body) else {
            throw BiliAPIError.missingData
        }
        return try payload.model()
    }

    /// 关注（`isFollowing`，`act=1`）或取消关注（`act=2`）UP 主 `mid`。
    public func setUploaderFollowing(
        _ isFollowing: Bool,
        mid: Int64,
        accountID: Int64
    ) async throws {
        guard hasAccountWriteAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        guard accountID > 0, mid > 0, mid != accountID else {
            throw BiliAPIError.invalidRequest
        }
        try await postForm(
            url: try endpoint(path: BiliAccountWritePath.relationModify),
            fields: [
                ("fid", String(mid)),
                ("act", isFollowing ? "1" : "2"),
                ("re_src", Self.followSourceCode)
            ],
            referer: Self.followWriteReferer,
            origin: Self.accountWriteOrigin,
            access: .accountWrite(expectedAccountID: accountID)
        )
    }

    private func engagementWriteAID(bvid: String, accountID: Int64) throws -> Int64 {
        guard hasAppWriteAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        guard accountID > 0, BVID.isValid(bvid), let aid = BiliVideoAID.aid(fromBVID: bvid) else {
            throw BiliAPIError.invalidRequest
        }
        return aid
    }

    @discardableResult
    private func postEngagement(
        path: String,
        fields: [(String, String)],
        accountID: Int64
    ) async throws -> Data {
        try await postAppForm(
            url: try appEndpoint(path: path),
            fields: fields,
            access: .appWrite(expectedAccountID: accountID)
        )
    }

    /// 解码写入响应的 `data`；`data` 为 null 或缺失时为 nil，形状不对时按解码失败。
    private func decodeEngagementData<Payload: Decodable & Sendable>(
        _ type: Payload.Type,
        from body: Data
    ) throws -> Payload? {
        do {
            return try decoder.decode(EngagementEnvelope<Payload>.self, from: body).data
        } catch {
            throw BiliAPIError.decodingFailed
        }
    }
}

/// 写入响应里只取 `data` 的 envelope；状态码已由 `postForm` 判定。
private struct EngagementEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let data: Payload?
}
