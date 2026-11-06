import BiliModels
import Foundation

/// UP 主空间投稿：App 端游标接口，经 App 授权器签名（登录时带 access_token，未登录时匿名），见 SECURITY-MODEL §3。
extension BiliAPIClient {
    /// 每批请求的条数：服务端上限就是 20（第一批 20 条，之后每批 19 条），请求更多也只给这么多。
    static let uploaderVideoBatchSize = 20

    public func uploaderVideos(
        ownerID: Int64,
        order: UploaderVideoOrder,
        after cursor: UploaderVideoCursor?
    ) async throws -> UploaderVideoBatch {
        guard ownerID > 0 else {
            throw BiliAPIError.invalidRequest
        }
        var queryItems = [
            URLQueryItem(name: "vmid", value: String(ownerID)),
            URLQueryItem(name: "ps", value: String(Self.uploaderVideoBatchSize)),
            URLQueryItem(name: "order", value: order.apiValue)
        ]
        if let cursor {
            // 游标是上一批最后一条的 `param`；`data.next_cursor` 也能用，这里取条目自带的值，不另解一个字段。
            guard UploaderVideoCursorPayload.isValid(cursor.value) else {
                throw BiliAPIError.invalidRequest
            }
            queryItems.append(URLQueryItem(name: "aid", value: cursor.value))
        }
        let payload: UploaderVideoArchivePayload = try await get(
            url: try appEndpoint(path: BiliAppReadPath.uploaderVideos, queryItems: queryItems),
            referer: nil,
            access: .appRead
        )
        return payload.model()
    }
}

extension UploaderVideoOrder {
    fileprivate var apiValue: String {
        switch self {
        case .newest: "pubdate"
        case .mostPlayed: "click"
        }
    }
}
