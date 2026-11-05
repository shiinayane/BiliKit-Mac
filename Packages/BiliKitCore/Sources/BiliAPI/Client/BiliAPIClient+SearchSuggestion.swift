import BiliApplication
import BiliNetworking
import Foundation

/// 搜索框联想。
extension BiliAPIClient {
    /// 接口在没有任何联想时以这个状态码回复，而不是返回空列表。
    static let noSearchSuggestionsCode = 3

    /// 始终匿名读取：不带账号 Cookie、不签 WBI，也不附加搜索专用的 buvid3。
    public func searchSuggestions(for term: String) async throws -> [String] {
        guard !term.isEmpty, SearchText.isWithinLimit(term),
            let query = URLQueryUnreservedEncoding.query([("term", term)])
        else {
            throw BiliAPIError.invalidRequest
        }
        do {
            let payload: SearchSuggestionPayload = try await get(
                url: try endpoint(
                    path: "/x/web-interface/suggest",
                    percentEncodedQuery: query
                ),
                referer: "https://www.bilibili.com/"
            )
            return payload.model()
        } catch BiliAPIError.apiRejected(let code, _) where code == Self.noSearchSuggestionsCode {
            return []
        }
    }
}
