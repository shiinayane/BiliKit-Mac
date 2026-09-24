import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 视频详情、分 P、相关推荐与 UP 主签名。
extension BiliAPIClient {
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
                URLQueryItem(name: "photo", value: "false")
            ]
    }
}
