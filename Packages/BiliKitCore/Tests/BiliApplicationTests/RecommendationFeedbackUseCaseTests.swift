import BiliApplication
import Testing

/// 首页推荐的「不感兴趣」与撤销只为正数账户发请求，成功时给出带账户与同一份反馈的效果；推荐流没给追踪 ID 的条目
/// 构造不出反馈。
@Suite(.timeLimit(.minutes(1)))
struct RecommendationFeedbackUseCaseTests {
    @Test
    func successfulWritesReportTheSameFeedback() async throws {
        let repository = RecommendationFeedbackRepositoryStub()
        let useCase = RecommendationFeedbackUseCase(repository: repository)
        let feedback = try Self.feedback()

        let disliked = try await useCase.dislike(feedback, accountID: 42)
        let cancelled = try await useCase.cancelDislike(feedback, accountID: 42)

        #expect(
            disliked == AccountWriteEffect(accountID: 42, change: .recommendationDisliked(feedback))
        )
        #expect(
            cancelled
                == AccountWriteEffect(
                    accountID: 42,
                    change: .recommendationDislikeCancelled(feedback)
                )
        )
        #expect(await repository.calls == ["dislike BV17x411w7KC 42", "cancel BV17x411w7KC 42"])
    }

    @Test(arguments: [Int64(0), -7])
    func nonPositiveAccountSendsNothing(accountID: Int64) async throws {
        let repository = RecommendationFeedbackRepositoryStub()
        let useCase = RecommendationFeedbackUseCase(repository: repository)
        let feedback = try Self.feedback()

        await #expect(throws: AccountWriteError.invalidRequest) {
            try await useCase.dislike(feedback, accountID: accountID)
        }
        await #expect(throws: AccountWriteError.invalidRequest) {
            try await useCase.cancelDislike(feedback, accountID: accountID)
        }
        #expect(await repository.calls.isEmpty)
    }

    @Test
    func feedbackNeedsATrackingIDAndAValidUploader() throws {
        let target = try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))

        #expect(
            RecommendationFeedback(target: target, uploaderID: 1, trackID: "", reason: .content)
                == nil
        )
        #expect(
            RecommendationFeedback(target: target, uploaderID: -1, trackID: "t", reason: .content)
                == nil
        )
        #expect(
            RecommendationFeedback(target: target, uploaderID: 0, trackID: "t", reason: .uploader)
                == nil
        )
        #expect(
            RecommendationFeedback(target: target, uploaderID: 1, trackID: "t", reason: .uploader)
                != nil
        )
    }

    private static func feedback() throws -> RecommendationFeedback {
        let target = try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))
        return try #require(
            RecommendationFeedback(
                target: target,
                uploaderID: 1,
                trackID: "track",
                reason: .content
            )
        )
    }
}

/// 本 target 唯一的 `RecommendationFeedbackRepository` 替身：记录调用，总是成功。
private actor RecommendationFeedbackRepositoryStub: RecommendationFeedbackRepository {
    private(set) var calls: [String] = []

    func dislike(_ feedback: RecommendationFeedback, accountID: Int64) async throws {
        calls.append("dislike \(feedback.target.bvid) \(accountID)")
    }

    func cancelDislike(_ feedback: RecommendationFeedback, accountID: Int64) async throws {
        calls.append("cancel \(feedback.target.bvid) \(accountID)")
    }
}
