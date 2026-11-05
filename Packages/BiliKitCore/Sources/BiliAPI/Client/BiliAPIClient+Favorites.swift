import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 收藏夹读取：自己创建的收藏夹列表与夹内的一页。两者只属于当前账户，所以只按账户读取，本地无凭据时直接失败；
/// 只读，不涉及任何写请求（见 SECURITY-MODEL §3）。
///
/// 都不签 WBI：网页端对这两个接口不签名；签名不是认证，多签反而偏离网页端的请求形状。
extension BiliAPIClient {
    /// 收藏夹业务码：请求的收藏夹不存在（已删除或不属于当前账户）。
    static let favoriteFolderMissingCode = 11_010

    /// 读取 `ownerID` 自己创建的全部收藏夹，一次取全、不分页，按接口顺序返回。
    ///
    /// `ownerID` 由调用方从窗口账户范围给出，这里不读取账户。`data` 为 null 时返回空数组：Cookie 失效时接口不报
    /// -101 而是退化为访客视角，是否可疑由 `FavoritesUseCase` 判断。
    public func favoriteFolders(ownerID: Int64) async throws -> [FavoriteFolder] {
        try await favoriteFolderList(ownerID: ownerID, extraQueryItems: [])?.model() ?? []
    }

    /// 同一份收藏夹列表，附带 `bvid` 对应的视频是否在各夹里，供「收藏到…」面板用。
    ///
    /// 带 `type=2&rid=<aid>` 时每行有 `fav_state`；`data` 为 null 时同样返回空数组。
    public func favoriteFolderMemberships(
        ownerID: Int64,
        bvid: String
    ) async throws -> [FavoriteFolderMembership] {
        guard BVID.isValid(bvid), let aid = BiliVideoAID.aid(fromBVID: bvid) else {
            throw BiliAPIError.invalidRequest
        }
        let payload = try await favoriteFolderList(
            ownerID: ownerID,
            extraQueryItems: [
                URLQueryItem(name: "type", value: "2"),
                URLQueryItem(name: "rid", value: String(aid))
            ]
        )
        return try payload?.memberships() ?? []
    }

    /// 列表读取的唯一请求形状；`data` 为 null 时为 nil。
    private func favoriteFolderList(
        ownerID: Int64,
        extraQueryItems: [URLQueryItem]
    ) async throws -> FavoriteFolderListPayload? {
        guard ownerID > 0 else { throw BiliAPIError.invalidRequest }
        do {
            return try await get(
                url: try endpoint(
                    path: BiliAccountReadPath.favoriteFolders,
                    queryItems: [URLQueryItem(name: "up_mid", value: String(ownerID))]
                        + extraQueryItems
                ),
                referer: "https://space.bilibili.com/\(ownerID)/favlist",
                access: .accountRead(missingCredential: .fail)
            )
        } catch BiliAPIError.missingData {
            return nil
        }
    }

    /// 按请求读取收藏夹内的一页（`pn` 从 1 开始）。
    ///
    /// `type=0` 只搜当前收藏夹，`tid=0` 不按分区筛选；`platform=web` 必须带，否则合集条目会被接口丢掉。关键词按
    /// RFC 3986 unreserved 编码（`queryItems` 会保留 `+`，被服务端当成空格）。`data` 或 `info` 为 null 与业务码
    /// 11010 都说明收藏夹不存在，前两者按 `missingData` 报告、11010 原样作为业务拒绝，由
    /// `BiliFavoritesRepository` 一起映射为内容不存在。
    public func favoriteFolderPage(
        request: FavoriteFolderRequest
    ) async throws -> FavoriteFolderPage {
        guard request.isValid else { throw BiliAPIError.invalidRequest }
        let parameters = [
            ("media_id", String(request.folderID)),
            ("pn", String(request.page)),
            ("ps", String(FavoritesUseCase.pageSize)),
            ("keyword", request.keyword),
            ("order", request.order.apiValue),
            ("type", "0"),
            ("tid", "0"),
            ("platform", "web")
        ]
        guard let query = URLQueryUnreservedEncoding.query(parameters) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: FavoriteFolderPagePayload = try await get(
            url: try endpoint(
                path: BiliAccountReadPath.favoriteFolderContent,
                percentEncodedQuery: query
            ),
            referer: "https://space.bilibili.com/",
            access: .accountRead(missingCredential: .fail)
        )
        return try payload.model(pageNumber: request.page, pageSize: FavoritesUseCase.pageSize)
    }
}

extension FavoriteFolderOrder {
    /// 排序在接口 `order` 参数里的取值。
    fileprivate var apiValue: String {
        switch self {
        case .recentlyFavorited: "mtime"
        case .mostPlayed: "view"
        case .recentlyPublished: "pubtime"
        }
    }
}
