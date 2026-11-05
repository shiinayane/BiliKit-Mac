import BiliApplication
import BiliModels
import Foundation

/// 首页推荐的「不感兴趣」与撤销：App 端接口，经 App 写管线 `getForWrite`、App 写授权器绑定窗口账户并签名。
///
/// 首页推荐来自 App 端，反馈也必须走 App 端：服务端按 access_token 认出是哪位用户的推荐流。`mobi_app`、`device`、
/// `build` 与首页推荐请求相同，同一位客户端身份；撤销与反馈字段完全相同。
extension BiliAPIClient {
    /// 对首页推荐的一条说「不感兴趣」（`cancel` 为 false），或撤销那次反馈。
    public func sendRecommendationFeedback(
        _ feedback: RecommendationFeedback,
        cancel: Bool,
        accountID: Int64
    ) async throws {
        guard hasAppWriteAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        guard accountID > 0, let aid = BiliVideoAID.aid(fromBVID: feedback.target.bvid) else {
            throw BiliAPIError.invalidRequest
        }
        try await getForWrite(
            url: try appEndpoint(
                path: cancel
                    ? BiliAppWritePath.recommendationDislikeCancel
                    : BiliAppWritePath.recommendationDislike,
                queryItems: [
                    URLQueryItem(name: "goto", value: "av"),
                    URLQueryItem(name: "id", value: String(aid)),
                    URLQueryItem(name: "reason_id", value: String(feedback.reason.id)),
                    URLQueryItem(name: "mobi_app", value: "iphone"),
                    URLQueryItem(name: "device", value: "pad"),
                    URLQueryItem(name: "build", value: "1")
                ]
            ),
            access: .appWrite(expectedAccountID: accountID)
        )
    }
}
