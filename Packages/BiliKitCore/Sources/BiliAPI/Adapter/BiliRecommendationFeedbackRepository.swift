import BiliApplication

/// `RecommendationFeedbackRepository` 的 B 站实现：转调窗口主 API 的「不感兴趣」与撤销，并把远端失败映射为
/// `AccountWriteError`。
///
/// 无状态；底层 client 必须注入了 App 写授权器（`LiveAPIClients.main`）。这个接口没有自己的业务码：凭据失效、风控
/// （含 -403 与 `v_voucher` 挑战）与稿件不存在照 `AccountWriteErrorMapping` 的共同规则，其余业务码按普通拒绝显示错误码。
/// 取消原样传播。
public struct BiliRecommendationFeedbackRepository: RecommendationFeedbackRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func dislike(_ feedback: RecommendationFeedback, accountID: Int64) async throws {
        do {
            try await client.sendRecommendationFeedback(
                feedback,
                cancel: false,
                accountID: accountID
            )
        } catch {
            throw AccountWriteErrorMapping.error(for: error) { _ in nil }
        }
    }

    public func cancelDislike(_ feedback: RecommendationFeedback, accountID: Int64) async throws {
        do {
            try await client.sendRecommendationFeedback(
                feedback,
                cancel: true,
                accountID: accountID
            )
        } catch {
            throw AccountWriteErrorMapping.error(for: error) { _ in nil }
        }
    }
}
