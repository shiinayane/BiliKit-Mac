import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 视频详情（含分 P）、相关推荐与 UP 主签名。
extension BiliAPIClient {
    public func videoDetail(for bvid: String) async throws -> VideoDetail {
        guard BVID.isValid(bvid) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: VideoDetailPayload = try await signedVideoDetail(
            bvid: bvid,
            access: .accountRead(missingCredential: .useAnonymousRequest)
        )
        let detail = try payload.model()
        // 响应必须是请求的那个稿件，错配的详情按解码失败处理，不交给调用方。
        guard detail.bvid == bvid else {
            throw BiliAPIError.decodingFailed
        }
        return detail
    }

    /// 视频详情的唯一请求：Web 播放页同款 WBI 签名 endpoint，未签名的 `/view` 对游客稳定返回 HTTP 412。
    ///
    /// 主详情与测速样本共用，各自决定授权方式与解码形状；会话变化的处理见 `signedRequest`。
    func signedVideoDetail<Payload: Decodable & Sendable>(
        bvid: String,
        access: RequestAccess
    ) async throws -> Payload {
        try await signedRequest(
            path: BiliAccountReadPath.videoDetail,
            parameters: { ["bvid": bvid] },
            send: { url in
                try await get(url: url, referer: try Self.videoReferer(bvid), access: access)
            }
        )
    }

    /// 登录增强地读取相关推荐；只有本地明确无凭据时匿名。
    public func relatedVideos(to bvid: String) async throws -> [RelatedVideo] {
        guard BVID.isValid(bvid) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: [RelatedVideoPayload] = try await get(
            url: try endpoint(
                path: BiliAccountReadPath.relatedVideos,
                queryItems: [URLQueryItem(name: "bvid", value: bvid)]
            ),
            referer: try Self.videoReferer(bvid),
            access: .accountRead(missingCredential: .useAnonymousRequest)
        )
        return try payload.map { try $0.model() }
    }

    /// 登录增强地读取公开 UP 主名片（签名与大会员状态）；不会请求 WBI 签名。
    public func uploaderProfile(for ownerID: Int64) async throws -> UploaderProfile {
        guard ownerID > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let path = BiliAccountReadPath.uploaderCard
        let queryItems = [
            URLQueryItem(name: "mid", value: String(ownerID)),
            URLQueryItem(name: "photo", value: "false")
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
            access: .accountRead(missingCredential: .useAnonymousRequest)
        )
        // 名片必须属于请求的 UP 主，错配按解码失败处理。
        guard payload.card.mid == ownerID else {
            throw BiliAPIError.decodingFailed
        }
        return payload.model()
    }

    /// 发出账户读取前核对构造出的地址恰好是名片 endpoint：HTTPS、固定主机、无端口与 userinfo、固定
    /// path，query 只有 `mid` 与 `photo=false`；不符按 `invalidRequest` 不发请求（见
    /// SECURITY-MODEL §3）。
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
            && components.path == BiliAccountReadPath.uploaderCard
            && components.queryItems == [
                URLQueryItem(name: "mid", value: String(ownerID)),
                URLQueryItem(name: "photo", value: "false")
            ]
    }
}
