import BiliModels

/// 对首页推荐的一条视频说「不感兴趣」：哪个视频，以及从这张卡片给出的原因里选的那一个。
///
/// 撤销带同样的字段，所以 Browse 记下发出的这一份，撤销时原样交回。
public struct RecommendationFeedback: Sendable, Hashable {
    public let target: VideoWriteTarget
    public let reason: RecommendationDislikeReason

    public init(target: VideoWriteTarget, reason: RecommendationDislikeReason) {
        self.target = target
        self.reason = reason
    }
}

/// 「不感兴趣」与撤销的写入 port。
///
/// 实现是 BiliAPI 的 `BiliRecommendationFeedbackRepository`，只经 `RecommendationFeedbackUseCase` 调用；`accountID` 交给
/// 写授权器做账户绑定。失败统一抛出 `AccountWriteError`，取消原样传播；不重试、不排队。
public protocol RecommendationFeedbackRepository: Sendable {
    func dislike(_ feedback: RecommendationFeedback, accountID: Int64) async throws
    func cancelDislike(_ feedback: RecommendationFeedback, accountID: Int64) async throws
}

/// 「不感兴趣」与撤销；校验账户后执行，成功时给出要分发的效果。
public struct RecommendationFeedbackUseCase: Sendable {
    private let repository: any RecommendationFeedbackRepository

    public init(repository: any RecommendationFeedbackRepository) {
        self.repository = repository
    }

    /// 账户 mid 不是正数时不发请求（`invalidRequest`）。
    public func dislike(
        _ feedback: RecommendationFeedback,
        accountID: Int64
    ) async throws -> AccountWriteEffect {
        guard accountID > 0 else { throw AccountWriteError.invalidRequest }
        try await repository.dislike(feedback, accountID: accountID)
        return AccountWriteEffect(accountID: accountID, change: .recommendationDisliked(feedback))
    }

    /// 账户 mid 不是正数时不发请求（`invalidRequest`）。
    public func cancelDislike(
        _ feedback: RecommendationFeedback,
        accountID: Int64
    ) async throws -> AccountWriteEffect {
        guard accountID > 0 else { throw AccountWriteError.invalidRequest }
        try await repository.cancelDislike(feedback, accountID: accountID)
        return AccountWriteEffect(
            accountID: accountID,
            change: .recommendationDislikeCancelled(feedback)
        )
    }
}
