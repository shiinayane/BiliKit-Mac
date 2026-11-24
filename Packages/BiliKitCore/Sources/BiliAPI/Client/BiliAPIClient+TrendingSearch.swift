import BiliModels
import Foundation

/// 搜索页的 B 站热搜。
extension BiliAPIClient {
    /// 接受的热搜条数范围；超出按 `invalidRequest` 拒绝，不发请求。
    static let trendingSearchLimitRange = 1...50

    /// 始终匿名读取：不带账号 Cookie、不签 WBI，也不带设备 Cookie（`unlinkedAnonymous`），见 SECURITY-MODEL §3。
    public func trendingSearchKeywords(limit: Int) async throws -> [TrendingSearchKeyword] {
        guard Self.trendingSearchLimitRange.contains(limit) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: TrendingSearchPayload = try await get(
            url: try endpoint(
                path: "/x/web-interface/search/square",
                queryItems: [URLQueryItem(name: "limit", value: String(limit))]
            ),
            referer: "https://www.bilibili.com/",
            access: .unlinkedAnonymous
        )
        return payload.model()
    }
}
